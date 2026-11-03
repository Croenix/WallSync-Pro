import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import 'config/api.dart';
import 'services/api_service.dart';
import 'services/diagnostics_service.dart';
import 'services/notification_service.dart';
import 'services/overlay_lifecycle_service.dart';
import 'services/process_diagnostics.dart';
import 'services/process_mode.dart';
import 'services/settings_service.dart';
import 'services/wallpaper_engine.dart';
import 'services/system_optimizer_service.dart';
import 'services/shortbird_client.dart';
import 'services/windows_taskbar_service.dart';
import 'models/taskbar_settings.dart';
import 'widgets/desktop_widget.dart';
import 'widgets/dashboard_view.dart';
import 'widgets/splash_screen.dart';
import 'widgets/wallpaper_app.dart';

// ignore: unused_element
RandomAccessFile? _overlayLockFileAccess;
// ignore: unused_element
RandomAccessFile? _wallpaperLockFileAccess;
ProcessMode? _processMode;
ProcessDiagnosticLog? _processDiagnosticLog;

Future<Never> _failOverlayStartup(
  String message, [
  Object? error,
  StackTrace? stackTrace,
]) async {
  await _processDiagnosticLog?.record(
    'startup_failure',
    'processMode=${_processMode?.value ?? 'invalid'} message="$message" '
        'error="${error ?? 'none'}"',
  );
  logError('OverlayStartup', message, error, stackTrace);
  await flushPendingLogs();
  exit(1);
}

Future<void> _restoreStartupWallpaper(WidgetSettings settings) async {
  final savedPath = (settings.activeWallpaperPath ?? '').trim();
  final wallpaperType = settings.activeWallpaperType;
  if (wallpaperType != 'static' && wallpaperType != 'video') {
    logInfo(
      'OverlayStartup',
      'Saved wallpaper type "$wallpaperType" does not require startup restore.',
    );
    return;
  }
  if (savedPath.isEmpty) {
    logInfo(
      'OverlayStartup',
      'No saved wallpaper path was available for startup restore.',
    );
    return;
  }

  final wallpaperFile = File(savedPath);
  if (!await wallpaperFile.exists()) {
    logWarning(
      'OverlayStartup',
      'Saved wallpaper path is missing at startup; skipping restore: $savedPath',
    );
    return;
  }

  const maxAttempts = 5;
  final retryDelays = [
    const Duration(seconds: 1),
    const Duration(seconds: 2),
    const Duration(seconds: 3),
    const Duration(seconds: 5),
  ];

  if (wallpaperType == 'video') {
    logInfo(
      'OverlayStartup',
      'Restoring local video wallpaper through the MPV engine: $savedPath',
    );
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final restored = await WallpaperEngine().startAnimatedWallpaper(
          savedPath,
          settings: settings,
        );
        if (restored) {
          logInfo(
            'OverlayStartup',
            'MPV confirmed the saved video wallpaper is attached, visible, and '
                'has decoded its first frame (attempt $attempt/$maxAttempts).',
          );
          return;
        }
      } catch (e) {
        logWarning(
          'OverlayStartup',
          'Attempt $attempt/$maxAttempts to restore video wallpaper encountered error: $e',
        );
      }
      if (attempt < maxAttempts) {
        final delay = retryDelays[attempt - 1];
        logInfo(
          'OverlayStartup',
          'Retrying video wallpaper restoration in ${delay.inSeconds}s (attempt ${attempt + 1}/$maxAttempts)...',
        );
        await Future<void>.delayed(delay);
      }
    }
    throw StateError(
      'MPV did not confirm visible output and a decoded first frame for '
      'the saved video wallpaper after $maxAttempts attempts: $savedPath',
    );
  }

  logInfo('OverlayStartup', 'Restoring saved static wallpaper: $savedPath');
  final wallpaperEngine = WallpaperEngine();
  for (int attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      final restored = await wallpaperEngine.setStaticWallpaper(
        savedPath,
        settings.wallpaperFit,
      );
      if (restored) {
        logInfo(
          'OverlayStartup',
          'Restored the saved static wallpaper during startup (attempt $attempt/$maxAttempts): $savedPath',
        );
        return;
      }
    } catch (e) {
      logWarning(
        'OverlayStartup',
        'Attempt $attempt/$maxAttempts to restore static wallpaper encountered error: $e',
      );
    }
    if (attempt < maxAttempts) {
      final delay = retryDelays[attempt - 1];
      await Future<void>.delayed(delay);
    }
  }
  logError(
    'Main',
    'Failed to restore the saved static wallpaper during startup after $maxAttempts attempts: $savedPath',
  );
  throw StateError(
    'Windows did not confirm application of the saved static wallpaper: $savedPath',
  );
}

void _emitOverlayBootstrapEvent(
  String eventName, {
  required int pid,
  required String instanceId,
  required int? operationId,
  required int configRevision,
  required Stopwatch stopwatch,
  String? overlayType,
  String? reason,
}) {
  final mode = _processMode;
  final fields = <String>[
    'event=$eventName',
    'pid=$pid',
    'processMode=${mode?.value ?? 'invalid'}',
    'configRevision=$configRevision',
    'elapsedMs=${stopwatch.elapsedMilliseconds}',
  ];
  if (instanceId.isNotEmpty) fields.add('instanceId=$instanceId');
  if (operationId != null) fields.add('operationId=$operationId');
  if (overlayType != null && overlayType.isNotEmpty) {
    fields.add('overlayType=$overlayType');
  }
  if (reason != null && reason.isNotEmpty) {
    fields.add('reason=${reason.replaceAll(RegExp(r'\s+'), ' ')}');
  }
  final tag = switch (mode) {
    ProcessMode.main => 'MainBootstrap',
    ProcessMode.wallpaper => 'WallpaperBootstrap',
    ProcessMode.classic => 'OverlayBootstrap',
    ProcessMode.taskbarDock => 'OverlayBootstrap',
    null => 'ProcessBootstrap',
  };
  logInfo(tag, fields.join(' | '));
}

Future<void> _restoreStartupOverlay(WidgetSettings settings) async {
  if (settings.exitOverlay) {
    logInfo(
      'OverlayStartup',
      'Saved settings explicitly disabled the overlay; startup recovery will not relaunch it.',
    );
    return;
  }

  logInfo(
    'OverlayStartup',
    'Restoring enabled desktop widgets using installed executable '
        '"${Platform.resolvedExecutable}".',
  );

  final executable = Platform.resolvedExecutable;
  final workingDirectory = File(executable).parent.path;
  final activeIds = settings.activeWidgetIds.isNotEmpty
      ? settings.activeWidgetIds
      : [settings.widgetTemplate];

  for (final id in activeIds) {
    final instService = SettingsService(instanceId: id);
    final pidFile = await instService.pidFile;
    bool isRunning = false;
    if (await pidFile.exists()) {
      try {
        final record = OverlayProcessRecord.tryParse(
          await pidFile.readAsString(),
        );
        if (record != null) {
          final inspection = await inspectWindowsProcess(record.pid);
          if (inspection != null &&
              inspection.isRunning &&
              inspection.matches(record)) {
            isRunning = true;
          }
        }
      } catch (_) {}
    }
    if (!isRunning) {
      try {
        final process = await Process.start(
          executable,
          ['--overlay', '--startup-trigger=windows-logon', '--instance-id=$id'],
          mode: ProcessStartMode.detached,
          workingDirectory: workingDirectory,
        );
        logInfo(
          'OverlayStartup',
          'Started background overlay restore for "$id" with pid=${process.pid} during '
              'Windows logon recovery.',
        );
      } catch (error) {
        logWarning('OverlayStartup', 'Could not restore overlay "$id": $error');
      }
    }
  }
}

void main(List<String> args) async {
  final processDiagnostics = await ProcessDiagnosticLog.initialize(args);
  _processDiagnosticLog = processDiagnostics;
  await processDiagnostics.record(
    'parsed_arguments',
    'arguments=${args.map((argument) => '"$argument"').join(' ')}',
  );

  late final ParsedProcessArguments processArguments;
  try {
    processArguments = parseProcessArguments(args);
  } on FormatException catch (error) {
    await processDiagnostics.record(
      'process_mode_validation',
      'result=invalid error="$error"',
    );
    await processDiagnostics.flush();
    stderr.writeln('WallSync process argument validation failed: $error');
    exit(2);
  }
  _processMode = processArguments.mode;
  processDiagnostics.setContext(
    processMode: processArguments.mode.value,
    instanceId: processArguments.instanceId,
    operationId: processArguments.operationId,
    configurationRevision: processArguments.configurationRevision,
  );
  await processDiagnostics.record(
    'process_mode_validation',
    'result=valid mode=${processArguments.mode.value}',
  );

  if (Platform.isWindows) {
    try {
      Directory.current = File(Platform.resolvedExecutable).parent.path;
    } on FileSystemException catch (error) {
      await processDiagnostics.record(
        'working_directory',
        'result=failed error="$error"',
      );
    }
  }
  await processDiagnostics.record(
    'runtime_path',
    'executable="${Platform.resolvedExecutable}" '
        'workingDirectory="${Directory.current.path}"',
  );
  final startupStopwatch = Stopwatch()..start();
  final isOverlayMode = processArguments.mode.isOverlay;
  final isWallpaperMode = processArguments.mode == ProcessMode.wallpaper;
  final isStartupRegistration = processArguments.startupRegistration;
  final startupTrigger = processArguments.startupTrigger;
  final startupArgsStopwatch = Stopwatch()..start();
  _emitOverlayBootstrapEvent(
    'arguments_received',
    pid: pid,
    instanceId: processArguments.instanceId ?? '',
    operationId: processArguments.operationId,
    configRevision: processArguments.configurationRevision,
    stopwatch: startupArgsStopwatch,
    overlayType: isOverlayMode ? processArguments.mode.value : null,
  );
  final wallpaperVideoPath = processArguments.videoPath;
  final initialTab = processArguments.initialTab;
  final isStartupBackground = startupTrigger == 'windows-logon';
  if (isStartupBackground || isStartupRegistration) {
    logInfo(
      'OverlayStartup',
      'Startup launch accepted; trigger=${isStartupRegistration ? 'installer-registration' : startupTrigger}, '
          'executable="${Platform.resolvedExecutable}", '
          'workingDirectory="${Directory.current.path}".',
    );
  }
  if (isWallpaperMode) {
    logInfo(
      'Main',
      'Wallpaper video argument: ${wallpaperVideoPath ?? '<missing>'}',
    );
  }

  // ── Step 2: Initialize Flutter bindings and error handlers ──
  WidgetsFlutterBinding.ensureInitialized();
  await processDiagnostics.record(
    'flutter_engine_initialized',
    'result=success',
  );
  _emitOverlayBootstrapEvent(
    'flutter_engine_initialized',
    pid: pid,
    instanceId: processArguments.instanceId ?? '',
    operationId: processArguments.operationId,
    configRevision: processArguments.configurationRevision,
    stopwatch: startupStopwatch,
    overlayType: isOverlayMode ? processArguments.mode.value : null,
  );
  if (kDebugMode && !isWallpaperMode) {
    assert(() {
      debugProfileBuildsEnabled = true;
      return true;
    }());
  }
  if (isOverlayMode) {
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        4 * 1024 * 1024; // 4 MB max for ultra-lightweight overlay
    PaintingBinding.instance.imageCache.maximumSize = 8;
  } else {
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        24 *
        1024 *
        1024; // 24 MB bounded cache for low-end device RAM efficiency
    PaintingBinding.instance.imageCache.maximumSize = 30;
  }

  // Profile dashboard and overlay frames in debug mode; avoid periodic sampling
  // in the lightweight overlay and keep live-wallpaper mode uninstrumented.
  if (kDebugMode && !isWallpaperMode) {
    DiagnosticsService.instance.init(enablePeriodicSampling: !isOverlayMode);
  }

  // Capture unhandled Flutter framework errors
  FlutterError.onError = (FlutterErrorDetails details) {
    logError(
      'FlutterError',
      details.exceptionAsString(),
      details.exception,
      details.stack,
    );
  };

  // Capture unhandled Dart async/isolate errors
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    logError(
      'PlatformDispatcher',
      'Unhandled background/async error',
      error,
      stack,
    );
    return true;
  };

  if (kDebugMode) {
    logInfo(
      'Main',
      'Application started. args=$args | isOverlayMode=$isOverlayMode | isWallpaperMode=$isWallpaperMode | pid=$pid',
    );
    logPerf(
      'Main',
      'Initial Startup Memory: ${DiagnosticsService.instance.getMemorySnapshot()}',
    );
  }
  if (isOverlayMode) {
    logInfo(
      'OverlayStartup',
      'Startup trigger received; source=$startupTrigger, pid=$pid.',
    );
    logPerf(
      'OverlayStartup',
      'Overlay process entered Dart main after '
          '${startupStopwatch.elapsedMilliseconds}ms.',
    );
  }

  // ── Step 3: Initialize window manager — wrapped to catch native failures ──
  final windowManagerStopwatch = Stopwatch()..start();
  try {
    logInfo('Main', 'Initializing window manager...');
    await DiagnosticsService.instance.trackAsyncOperation(
      tag: 'Main',
      name: 'windowManager.ensureInitialized',
      operation: () => windowManager.ensureInitialized(),
      warningThreshold: const Duration(seconds: 2),
    );
    logInfo('Main', 'Window manager initialized successfully.');
    await processDiagnostics.record(
      'window_manager_initialization',
      'result=success elapsedMs=${windowManagerStopwatch.elapsedMilliseconds}',
    );
    if (isOverlayMode) {
      logPerf(
        'OverlayStartup',
        'Window manager initialization completed in '
            '${windowManagerStopwatch.elapsedMilliseconds}ms.',
      );
    }
  } catch (e, st) {
    await processDiagnostics.record(
      'window_manager_initialization',
      'result=failed error="$e"',
    );
    logError(
      'Main',
      'windowManager.ensureInitialized() FAILED — this is fatal',
      e,
      st,
    );
    // Cannot continue without window manager
    exit(1);
  }
  await processDiagnostics.record(
    'runtime_initialized',
    'result=success elapsedMs=${startupStopwatch.elapsedMilliseconds}',
  );
  _emitOverlayBootstrapEvent(
    'runtime_initialized',
    pid: pid,
    instanceId: processArguments.instanceId ?? '',
    operationId: processArguments.operationId,
    configRevision: processArguments.configurationRevision,
    stopwatch: startupStopwatch,
    overlayType: isOverlayMode ? processArguments.mode.value : null,
  );

  final overlayInstanceId = processArguments.instanceId ?? '';
  final overlayType = isOverlayMode ? processArguments.mode.value : '';
  final normalizedOverlayType = overlayType;
  final overlayOperationId = processArguments.operationId;
  final overlayConfigRevision = processArguments.configurationRevision;

  _emitOverlayBootstrapEvent(
    'arguments_parsed',
    pid: pid,
    instanceId: overlayInstanceId,
    operationId: overlayOperationId,
    configRevision: overlayConfigRevision,
    stopwatch: startupArgsStopwatch,
    overlayType: normalizedOverlayType,
  );

  // ── Step 4: Load settings ──
  final settingsService = SettingsService(
    instanceId: overlayInstanceId.isNotEmpty ? overlayInstanceId : null,
  );
  final settingsLoadStopwatch = Stopwatch()..start();
  final settingsFile = await settingsService.settingsFile;
  await processDiagnostics.record(
    'configuration_loading',
    'result=started path="${settingsFile.path}"',
  );
  final settings = await settingsService.loadSettings();
  final settingsLoadMs = settingsLoadStopwatch.elapsedMilliseconds;
  await processDiagnostics.record(
    'configuration_loading',
    'result=${settingsService.settingsLoadSucceeded ? 'success' : 'failed'} '
        'path="${settingsFile.path}" elapsedMs=$settingsLoadMs',
  );
  logPerf(
    'OverlayStartup',
    'Settings file load completed in ${settingsLoadMs}ms '
        '(startup total ${startupStopwatch.elapsedMilliseconds}ms, '
        'overlay=$isOverlayMode, wallpaper=$isWallpaperMode).',
  );
  if (!isOverlayMode && !isWallpaperMode) {
    final registrationStopwatch = Stopwatch()..start();
    var startupRegistrationFailed = false;
    if (settingsService.settingsLoadSucceeded) {
      try {
        await settingsService.syncStartupRegistration(settings.startOnBoot);
        logPerf(
          'OverlayStartup',
          'Startup registration phase completed in '
              '${registrationStopwatch.elapsedMilliseconds}ms.',
        );
      } catch (error, stackTrace) {
        startupRegistrationFailed = true;
        logError(
          'Main',
          'Windows startup registration synchronization failed; the dashboard '
              'will continue, and the saved preference will be retried next launch.',
          error,
          stackTrace,
        );
      }
    } else {
      logWarning(
        'Main',
        'Startup registration was not changed because saved settings could '
            'not be loaded safely.',
      );
    }
    if (isStartupRegistration) {
      if (!settingsService.settingsLoadSucceeded) {
        logError(
          'OverlayStartup',
          'Installer registration aborted because saved settings could not '
              'be loaded safely.',
        );
        await flushPendingLogs();
        exit(1);
      }
      if (startupRegistrationFailed) {
        await flushPendingLogs();
        exit(1);
      }
      logInfo(
        'OverlayStartup',
        'Installer startup registration synchronization completed.',
      );
      await flushPendingLogs();
      exit(0);
    }
    // Keep optional server discovery from delaying dashboard startup offline.
    if (!isStartupBackground) {
      unawaited(
        ApiConfig.init().then((_) {
          ApiService.instance.startHeartbeat(settings: settings);
        }),
      );
    }
    unawaited(WindowsTaskbarService.instance.init());
  }
  logInfo(
    'Main',
    'Settings loaded. backgroundType=${settings.backgroundType}, size=${settings.width}x${settings.height}',
  );
  _emitOverlayBootstrapEvent(
    'configuration_loaded',
    pid: pid,
    instanceId: overlayInstanceId,
    operationId: overlayOperationId,
    configRevision: overlayConfigRevision,
    stopwatch: startupStopwatch,
    overlayType: normalizedOverlayType,
  );

  // ── Step 5: Branch into Overlay, Wallpaper, or Dashboard mode ──
  if (isOverlayMode) {
    _emitOverlayBootstrapEvent(
      'overlay_mode_selected',
      pid: pid,
      instanceId: overlayInstanceId,
      operationId: overlayOperationId,
      configRevision: overlayConfigRevision,
      stopwatch: startupStopwatch,
      overlayType: normalizedOverlayType,
    );
    _emitOverlayBootstrapEvent(
      'overlay_type_selected',
      pid: pid,
      instanceId: overlayInstanceId,
      operationId: overlayOperationId,
      configRevision: overlayConfigRevision,
      stopwatch: startupStopwatch,
      overlayType: normalizedOverlayType,
    );
    logInfo(
      'OverlayStartup',
      'Runtime preparation stage started for installed executable '
          '"${Platform.resolvedExecutable}".',
    );
    final runtimePreparationStopwatch = Stopwatch()..start();
    final executable = File(Platform.resolvedExecutable);
    final runtimeDirectory = executable.parent;
    final requiredRuntimeFiles = <File>[
      executable,
      File('${runtimeDirectory.path}\\flutter_windows.dll'),
      File('${runtimeDirectory.path}\\data\\icudtl.dat'),
    ];
    for (final runtimeFile in requiredRuntimeFiles) {
      if (!await runtimeFile.exists()) {
        await _failOverlayStartup(
          'Required overlay runtime file is missing: ${runtimeFile.path}.',
        );
      }
    }
    logInfo(
      'OverlayStartup',
      'Runtime prepared and validated from the installed application '
          'directory in ${runtimePreparationStopwatch.elapsedMilliseconds}ms; '
          'shadow copy is reserved for dashboard-launched overlays.',
    );
    logInfo(
      'OverlayStartup',
      'Entering overlay process startup; source=$startupTrigger, pid=$pid.',
    );

    // Single-instance lock to prevent multiple overlay instances from running
    try {
      // The exclusive lock is authoritative. Never terminate a process by a
      // stale PID or shared window title before acquiring it.
      final lockFile = await settingsService.lockFile;
      RandomAccessFile? raf;
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < 5000) {
        try {
          raf = await lockFile.open(mode: FileMode.append);
          await raf
              .lock(FileLock.exclusive)
              .timeout(const Duration(milliseconds: 500));
          break;
        } catch (_) {
          if (raf != null) {
            try {
              await raf.close();
            } catch (_) {}
            raf = null;
          }
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
      if (raf == null) {
        throw Exception('Could not acquire overlay lock within 5s timeout');
      }
      // Keep the lock for the overlay lifetime.
      _overlayLockFileAccess = raf;
      logInfo('Main', 'Successfully acquired overlay single-instance lock.');
    } catch (e) {
      logError(
        'Main',
        'Failed to acquire overlay single-instance lock: $e. Exiting...',
      );
      try {
        final pidFile = await settingsService.pidFile;
        final existing = await waitForOverlayReadiness(
          readRecord: () async {
            if (!await pidFile.exists()) return null;
            final text = (await pidFile.readAsString()).trim();
            return text.isEmpty ? null : OverlayProcessRecord.tryParse(text);
          },
          inspectProcess: inspectWindowsProcess,
          timeout: const Duration(seconds: 2),
        );
        if (existing.isReady) {
          logInfo(
            'OverlayStartup',
            'Duplicate overlay launch converged on healthy PID '
                '${existing.record?.pid}; this process will exit normally.',
          );
          await flushPendingLogs();
          exit(0);
        }
      } catch (identityError, identityStack) {
        logError(
          'OverlayStartup',
          'Could not verify an existing overlay after lock contention.',
          identityError,
          identityStack,
        );
      }
      await _failOverlayStartup(
        'Could not acquire the overlay single-instance lock and no healthy '
        'owner could be verified.',
        e,
      );
    }

    final overlayEntryPointMs = DateTime.now().millisecondsSinceEpoch;
    final cleanSettings = settings.exitOverlay
        ? await settingsService.updateSettings(
            (current) => current.copyWith(exitOverlay: false),
          )
        : settings;

    int? overlayHwnd;
    try {
      final rawWindowInfo = await const MethodChannel(
        'wallsync/live_wallpaper',
      ).invokeMethod<Map>('getNativeWindowInfo');
      if (rawWindowInfo == null) {
        throw StateError('The native runner returned no HWND diagnostics.');
      }
      final windowInfo = Map<String, dynamic>.from(rawWindowInfo);
      overlayHwnd = windowInfo['hwnd'] as int?;
      final ownerPid = windowInfo['ownerPid'] as int?;
      if (windowInfo['isValid'] != true ||
          overlayHwnd == null ||
          overlayHwnd == 0 ||
          ownerPid != pid) {
        throw StateError(
          'HWND ownership validation failed: hwnd=$overlayHwnd '
          'ownerPid=$ownerPid expectedPid=$pid nativeInfo=$windowInfo',
        );
      }
      await processDiagnostics.record(
        'hwnd_ownership_verification',
        'result=verified hwnd=$overlayHwnd ownerPid=$ownerPid '
            'threadId=${windowInfo['threadId']}',
      );
    } catch (error, stackTrace) {
      await processDiagnostics.record(
        'hwnd_ownership_verification',
        'result=failed error="$error"',
      );
      await _failOverlayStartup(
        'The overlay native HWND could not be verified as owned by PID $pid.',
        error,
        stackTrace,
      );
    }

    await OverlayLifecycleService.writeCurrentProcessRecord(
      settingsService,
      ready: false,
      state: OverlayLifecycleState.processStarted,
      stage: DockReadinessStage.processRunning,
      instanceId: overlayInstanceId,
      processMode: processArguments.mode.value,
      diagnosticLogPath: processDiagnostics.path,
      hwnd: overlayHwnd,
      operationId: overlayOperationId,
      configurationRevision: overlayConfigRevision,
      startupTimestamp: overlayEntryPointMs,
      entryPointMs: overlayEntryPointMs,
      settingsLoadedMs: settingsLoadMs,
    );
    final overlayPidFile = await settingsService.pidFile;
    await processDiagnostics.record(
      'pid_file_write',
      'result=success path="${overlayPidFile.path}" hwnd=$overlayHwnd',
    );
    await processDiagnostics.record(
      'readiness_channel_started',
      'transport=atomic-process-record path="${overlayPidFile.path}"',
    );
    final processRegistrationStopwatch = Stopwatch()..start();
    logInfo(
      'OverlayStartup',
      'Process identity verified and registered; pid=$pid, instanceId=$overlayInstanceId, type=$overlayType, opId=$overlayOperationId, configRev=$overlayConfigRevision, state=processStarted, stage=processRunning, hwnd=$overlayHwnd.',
    );

    // Configure the transparent, frameless, always-on-top overlay window
    final isTaskbar =
        overlayType == 'taskbar_dock' ||
        cleanSettings.widgetTemplate.startsWith('taskbar_') ||
        overlayInstanceId.startsWith('taskbar');
    final WindowOptions windowOptions = WindowOptions(
      size: Size(cleanSettings.width, cleanSettings.height),
      minimumSize: isTaskbar ? const Size(120, 36) : const Size(180, 60),
      maximumSize: const Size(1920, 1080),
      center: cleanSettings.posX == null,
      backgroundColor: Colors.transparent,
      skipTaskbar: true, // Hidden from taskbar — behaves like a desktop widget
      titleBarStyle: TitleBarStyle.hidden, // Hides native title bar
      alwaysOnTop: cleanSettings.alwaysOnTop,
    );

    logInfo(
      'Main',
      'Configuring overlay window options: size=${cleanSettings.width}x${cleanSettings.height}, alwaysOnTop=${cleanSettings.alwaysOnTop}, posX=${cleanSettings.posX}, posY=${cleanSettings.posY}',
    );

    bool overlayConfigurationComplete = false;
    Future<void>? overlayConfigurationInProgress;

    Future<void> configureAndShowOverlay() async {
      final overlayWindowStopwatch = Stopwatch()..start();
      try {
        Future<void> timeWindowOperation(
          String name,
          Future<void> Function() operation,
        ) async {
          final operationStopwatch = Stopwatch()..start();
          await DiagnosticsService.instance.trackAsyncOperation<void>(
            tag: 'Main',
            name: 'overlay.window.$name',
            operation: operation,
            warningThreshold: const Duration(milliseconds: 250),
          );
          logPerf(
            'Main',
            'Overlay native window operation "$name" completed in '
                '${operationStopwatch.elapsedMilliseconds}ms.',
          );
        }

        Offset? requestedPosition;
        if (cleanSettings.posX != null && cleanSettings.posY != null) {
          requestedPosition = Offset(cleanSettings.posX!, cleanSettings.posY!);
          try {
            final results = await Future.wait([
              ScreenRetriever.instance.getAllDisplays(),
              ScreenRetriever.instance.getPrimaryDisplay(),
            ]).timeout(const Duration(milliseconds: 200));
            final displays = results[0] as List<Display>;
            final primaryDisplay = results[1] as Display;
            final displayBounds = displays
                .map((display) {
                  final origin =
                      display.visiblePosition ??
                      (display.id == primaryDisplay.id ? Offset.zero : null);
                  if (origin == null) return null;
                  final size = display.visibleSize ?? display.size;
                  return Rect.fromLTWH(
                    origin.dx,
                    origin.dy,
                    size.width,
                    size.height,
                  );
                })
                .whereType<Rect>()
                .toList();
            if (displayBounds.isNotEmpty) {
              final adjustedPosition = clampOverlayPositionToDisplays(
                requested: requestedPosition,
                windowSize: Size(cleanSettings.width, cleanSettings.height),
                displayBounds: displayBounds,
              );
              if (adjustedPosition != requestedPosition) {
                logWarning(
                  'OverlayStartup',
                  'Saved overlay position is outside the connected displays; '
                      'restoring it to $adjustedPosition across ${displayBounds.length} displays.',
                );
                requestedPosition = adjustedPosition;
              } else {
                logInfo(
                  'OverlayStartup',
                  'Saved overlay position is valid across '
                      '${displayBounds.length} connected displays.',
                );
              }
            }
          } catch (error) {
            logWarning(
              'OverlayStartup',
              'Display bounds query bypassed or timed out; using saved position: $error',
            );
          }
        }

        if (isTaskbar) {
          try {
            final primaryDisplay = await ScreenRetriever.instance
                .getPrimaryDisplay()
                .timeout(const Duration(milliseconds: 300));
            final screenSize = primaryDisplay.size;
            final isTaskbarReplacement =
                cleanSettings.widgetTemplate == 'taskbar_dock' &&
                cleanSettings.taskbarSettings.nativeTaskbarHideEnabled;
            final posType = cleanSettings.taskbarSettings.taskbarPosition;
            if (isTaskbarReplacement) {
              await timeWindowOperation(
                'setReplacementTaskbarSize',
                () => windowManager.setSize(
                  Size(screenSize.width, cleanSettings.height),
                ),
              );
            }
            Offset taskbarPos;
            if (isTaskbarReplacement && posType == 'bottom') {
              taskbarPos = Offset(0, screenSize.height - cleanSettings.height);
            } else if (posType == 'top') {
              taskbarPos = Offset(
                (screenSize.width - cleanSettings.width) / 2,
                8,
              );
            } else if (posType == 'left') {
              taskbarPos = Offset(
                8,
                (screenSize.height - cleanSettings.height) / 2,
              );
            } else if (posType == 'right') {
              taskbarPos = Offset(
                screenSize.width - cleanSettings.width - 8,
                (screenSize.height - cleanSettings.height) / 2,
              );
            } else {
              // 'bottom' default
              taskbarPos = Offset(
                (screenSize.width - cleanSettings.width) / 2,
                screenSize.height - cleanSettings.height - 10,
              );
            }
            await timeWindowOperation(
              'setPosition',
              () => windowManager.setPosition(taskbarPos),
            );
            logInfo(
              'OverlayStartup',
              'Taskbar dock positioned at $posType: $taskbarPos',
            );
          } catch (_) {
            await timeWindowOperation('center', windowManager.center);
          }
        } else if (requestedPosition != null) {
          final position = requestedPosition;
          await timeWindowOperation(
            'setPosition',
            () => windowManager.setPosition(position),
          );
          logInfo(
            'Main',
            'Window position set to (${position.dx}, ${position.dy})',
          );
        } else {
          await timeWindowOperation('center', windowManager.center);
          logInfo(
            'OverlayStartup',
            'Window positioned at the primary display center.',
          );
        }

        await timeWindowOperation(
          'setTitle',
          () => windowManager.setTitle(
            'WallSync Overlay ${overlayInstanceId.isNotEmpty ? overlayInstanceId : "Default"}',
          ),
        );
        await timeWindowOperation(
          'setAsFrameless',
          windowManager.setAsFrameless,
        );
        await timeWindowOperation(
          'setHasShadow',
          () => windowManager.setHasShadow(false),
        );
        await timeWindowOperation('show', windowManager.show);
        await timeWindowOperation('focus', windowManager.focus);

        final visible = await waitForOverlayWindowVisibility(
          isVisible: windowManager.isVisible,
          retryDelays: const [
            Duration(milliseconds: 25),
            Duration(milliseconds: 50),
            Duration(milliseconds: 100),
            Duration(milliseconds: 200),
            Duration(milliseconds: 400),
            Duration(milliseconds: 800),
          ],
          onRetry: (attempt, delay) {
            logWarning(
              'OverlayStartup',
              'Overlay window is not visible yet; retry=$attempt, '
                  'delay=${delay.inMilliseconds}ms.',
            );
          },
        );
        if (!visible) {
          throw StateError(
            'Overlay window did not become visible after bounded retries.',
          );
        }

        final actualWindowSize = await windowManager.getSize();
        if (actualWindowSize.width <= 0 || actualWindowSize.height <= 0) {
          throw StateError(
            'Visible overlay window has unusable size '
            '${actualWindowSize.width}x${actualWindowSize.height}.',
          );
        }
        final rawWindowInfo = await const MethodChannel(
          'wallsync/live_wallpaper',
        ).invokeMethod<Map>('getNativeWindowInfo');
        if (rawWindowInfo == null) {
          throw StateError('The native runner returned no visible HWND data.');
        }
        final windowInfo = Map<String, dynamic>.from(rawWindowInfo);
        final nativeHwnd = windowInfo['hwnd'] as int?;
        final ownerPid = windowInfo['ownerPid'] as int?;
        final boundsWidth =
            (windowInfo['right'] as int? ?? 0) -
            (windowInfo['left'] as int? ?? 0);
        final boundsHeight =
            (windowInfo['bottom'] as int? ?? 0) -
            (windowInfo['top'] as int? ?? 0);
        if (windowInfo['isValid'] != true ||
            windowInfo['isVisible'] != true ||
            nativeHwnd != overlayHwnd ||
            ownerPid != pid ||
            boundsWidth <= 0 ||
            boundsHeight <= 0 ||
            windowInfo['onMonitor'] != true) {
          throw StateError(
            'The visible native HWND failed ownership or bounds verification: '
            'recordedHwnd=$overlayHwnd nativeInfo=$windowInfo',
          );
        }
        await processDiagnostics.record(
          'native_window_initialization',
          'result=verified hwnd=$nativeHwnd ownerPid=$ownerPid '
              'visible=true bounds=${boundsWidth}x$boundsHeight',
        );

        logInfo(
          'OverlayStartup',
          'Overlay window is visible and usable '
              '(${actualWindowSize.width}x${actualWindowSize.height}).',
        );
        _emitOverlayBootstrapEvent(
          'window_creation_started',
          pid: pid,
          instanceId: overlayInstanceId,
          operationId: overlayOperationId,
          configRevision: overlayConfigRevision,
          stopwatch: startupStopwatch,
          overlayType: normalizedOverlayType,
        );

        final windowInitMs = DateTime.now().millisecondsSinceEpoch;
        _emitOverlayBootstrapEvent(
          'hwnd_created',
          pid: pid,
          instanceId: overlayInstanceId,
          operationId: overlayOperationId,
          configRevision: overlayConfigRevision,
          stopwatch: startupStopwatch,
          overlayType: normalizedOverlayType,
          reason: overlayHwnd == null
              ? 'native-hwnd-not-yet-known'
              : 'hwnd=$overlayHwnd',
        );
        await OverlayLifecycleService.updateCurrentProcessState(
          settingsService,
          state: OverlayLifecycleState.windowInitialized,
          stage: DockReadinessStage.windowVisible,
          hwnd: overlayHwnd,
          instanceId: overlayInstanceId,
          processMode: processArguments.mode.value,
          diagnosticLogPath: processDiagnostics.path,
          operationId: overlayOperationId,
          configurationRevision: overlayConfigRevision,
          windowInitMs: windowInitMs,
        );
        _emitOverlayBootstrapEvent(
          'hwnd_registered',
          pid: pid,
          instanceId: overlayInstanceId,
          operationId: overlayOperationId,
          configRevision: overlayConfigRevision,
          stopwatch: startupStopwatch,
          overlayType: normalizedOverlayType,
          reason: overlayHwnd == null
              ? 'hwnd-not-registered'
              : 'hwnd=$overlayHwnd',
        );

        overlayConfigurationComplete = true;
        logInfo('Main', 'Overlay window shown successfully.');
        logPerf(
          'Main',
          'Overlay native window configuration completed in '
              '${overlayWindowStopwatch.elapsedMilliseconds}ms.',
        );
      } catch (e, st) {
        logError('Main', 'Error during overlay window show/position', e, st);
        await OverlayLifecycleService.markCurrentProcessFailed(
          settingsService,
          reason: 'Window configuration failed: $e',
        );
        await _failOverlayStartup(
          'Overlay window initialization failed: $e',
          e,
        );
      }
    }

    Future<void> showAndPositionOverlay() {
      if (overlayConfigurationComplete) return Future<void>.value();
      final current = overlayConfigurationInProgress;
      if (current != null) return current;
      late final Future<void> operation;
      operation = configureAndShowOverlay().whenComplete(() {
        if (identical(overlayConfigurationInProgress, operation)) {
          overlayConfigurationInProgress = null;
        }
      });
      overlayConfigurationInProgress = operation;
      return operation;
    }

    Future<void>? readinessRegistration;
    bool readinessRegistered = false;
    bool firstFlutterFrameRendered = false;
    bool firstFrameTimingLogged = false;

    Future<void> markOverlayReady() async {
      if (readinessRegistered ||
          !overlayConfigurationComplete ||
          !firstFlutterFrameRendered) {
        return;
      }
      final pending = readinessRegistration;
      if (pending != null) return pending;
      late final Future<void> registration;
      final readyPublishedMs = DateTime.now().millisecondsSinceEpoch;
      registration =
          () async {
            if (processArguments.mode == ProcessMode.taskbarDock) {
              final ipcAcknowledged = await const MethodChannel(
                'wallsync/live_wallpaper',
              ).invokeMethod<bool>('acknowledgeDockReadiness');
              if (ipcAcknowledged != true) {
                throw StateError(
                  'The child could not signal its named readiness event.',
                );
              }
              await processDiagnostics.record(
                'readiness_acknowledgement',
                'transport=named-readiness-event result=signaled',
              );
            }
            await OverlayLifecycleService.markCurrentProcessReady(
              settingsService,
              readyPublishedMs: readyPublishedMs,
              hwnd: overlayHwnd,
              instanceId: overlayInstanceId,
              processMode: processArguments.mode.value,
              diagnosticLogPath: processDiagnostics.path,
              operationId: overlayOperationId,
              configurationRevision: overlayConfigRevision,
            );
          }().whenComplete(() {
            if (identical(readinessRegistration, registration)) {
              readinessRegistration = null;
            }
          });
      readinessRegistration = registration;
      await registration;
      readinessRegistered = true;
      await processDiagnostics.record(
        'child_readiness_acknowledgement',
        'result=ready hwnd=${overlayHwnd ?? 0} '
            'operationId=${overlayOperationId ?? 'none'} '
            'configRevision=$overlayConfigRevision',
      );
      _emitOverlayBootstrapEvent(
        'readiness_acknowledged',
        pid: pid,
        instanceId: overlayInstanceId,
        operationId: overlayOperationId,
        configRevision: overlayConfigRevision,
        stopwatch: startupStopwatch,
        overlayType: normalizedOverlayType,
        reason: 'readyPublishedMs=$readyPublishedMs, hwnd=${overlayHwnd ?? 0}',
      );
      logInfo(
        'OverlayStartup',
        'Overlay visible and ready; startup completed after native window configuration '
            'and first Flutter frame (${startupStopwatch.elapsedMilliseconds}ms '
            'from process startup; since PID registration '
            '${processRegistrationStopwatch.elapsedMilliseconds}ms, '
            'readyPublishedMs=$readyPublishedMs).',
      );
    }

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      _emitOverlayBootstrapEvent(
        'window_ready_to_show',
        pid: pid,
        instanceId: overlayInstanceId,
        operationId: overlayOperationId,
        configRevision: overlayConfigRevision,
        stopwatch: startupStopwatch,
        overlayType: normalizedOverlayType,
      );
      await processDiagnostics.record('window_ready_to_show', 'result=success');
      logInfo(
        'OverlayStartup',
        'Overlay window created and ready; applying position and visibility.',
      );
      await showAndPositionOverlay();
      try {
        await markOverlayReady();
      } catch (error, stackTrace) {
        await processDiagnostics.record(
          'child_readiness_acknowledgement',
          'result=failed error="$error"',
        );
        logError(
          'Main',
          'Could not acknowledge overlay readiness after window setup.',
          error,
          stackTrace,
        );
        await OverlayLifecycleService.markCurrentProcessFailed(
          settingsService,
          reason: 'Readiness acknowledgement failed: $error',
        );
        await _failOverlayStartup(
          'Overlay readiness acknowledgement failed: $error',
          error,
          stackTrace,
        );
      }
    });

    logInfo(
      'Main',
      'Starting OverlayApp widget tree (instanceId=$overlayInstanceId)...',
    );
    runApp(
      OverlayApp(
        settings: cleanSettings,
        instanceId: overlayInstanceId.isNotEmpty ? overlayInstanceId : null,
      ),
    );

    Timer(const Duration(seconds: 28), () {
      if (!readinessRegistered) {
        unawaited(() async {
          await OverlayLifecycleService.markCurrentProcessFailed(
            settingsService,
            reason: 'Readiness not confirmed within 28s startup deadline',
          );
          await _failOverlayStartup(
            'Overlay failed to reach visible-and-ready state within 28 seconds; '
            'exiting so the bounded Task Scheduler recovery policy can retry.',
          );
        }());
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      firstFlutterFrameRendered = true;
      final firstFrameMs = DateTime.now().millisecondsSinceEpoch;
      await OverlayLifecycleService.updateCurrentProcessState(
        settingsService,
        state: OverlayLifecycleState.firstFrameRendered,
        stage: DockReadinessStage.windowInteractive,
        hwnd: overlayHwnd,
        instanceId: overlayInstanceId,
        firstFrameMs: firstFrameMs,
      );

      if (!firstFrameTimingLogged) {
        firstFrameTimingLogged = true;
        logPerf(
          'OverlayStartup',
          'First Flutter frame rendered '
              '${startupStopwatch.elapsedMilliseconds}ms after process start '
              'and ${processRegistrationStopwatch.elapsedMilliseconds}ms '
              'after PID registration (firstFrameMs=$firstFrameMs).',
        );
      }
      try {
        await showAndPositionOverlay();
        await markOverlayReady();
      } catch (error, stackTrace) {
        logError(
          'Main',
          'Could not complete overlay startup readiness handshake.',
          error,
          stackTrace,
        );
      }
      logPerf(
        'Main',
        'Overlay first Flutter post-frame callback completed after '
            '${startupStopwatch.elapsedMilliseconds}ms of process startup.',
      );
      // Enable EcoQoS and trim working set for the overlay process
      unawaited(SystemOptimizerService.instance.setLowPowerMode(true));
      unawaited(SystemOptimizerService.instance.optimizeMemory());
      SystemOptimizerService.instance.startBackgroundMemoryOptimizer(
        interval: const Duration(minutes: 5),
      );
    });
  } else if (isWallpaperMode) {
    logInfo('Main', 'Entering Live Wallpaper mode');

    // Single-instance lock to prevent multiple wallpaper instances from running
    try {
      final wallpaperEngine = WallpaperEngine();
      final lockFile = await wallpaperEngine.wallpaperLockFile;
      final raf = await lockFile.open(mode: FileMode.append);
      await raf
          .lock(FileLock.exclusive)
          .timeout(const Duration(milliseconds: 600));
      _wallpaperLockFileAccess = raf;
      logInfo('Main', 'Successfully acquired wallpaper single-instance lock.');

      final pidFile = await wallpaperEngine.wallpaperPidFile;
      await pidFile.writeAsString(pid.toString(), flush: true);
      logInfo('Main', 'Wrote PID $pid to wallpaper.pid');
    } catch (e, st) {
      logError(
        'Main',
        'Failed to acquire wallpaper lock or write wallpaper PID',
        e,
        st,
      );
      exit(1);
    }

    // Configure the borderless wallpaper window
    final WindowOptions windowOptions = WindowOptions(
      size: const Size(1920, 1080),
      backgroundColor: Colors.black,
      skipTaskbar: true, // Hidden from taskbar
      titleBarStyle: TitleBarStyle.hidden, // Frameless
      alwaysOnTop: false, // Under icons
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      try {
        await windowManager.setAsFrameless();
        await windowManager.show();
        await windowManager.setSkipTaskbar(true);
        logInfo(
          'Main',
          'Wallpaper window shown successfully, reparenting to desktop...',
        );

        final wallpaperEngine = WallpaperEngine();
        final success = await wallpaperEngine.reparentToDesktop();
        if (success) {
          logInfo(
            'Main',
            'Wallpaper window successfully reparented to desktop.',
          );
        } else {
          logError(
            'Main',
            'Failed to reparent wallpaper window. Exiting to avoid leaving a floating wallpaper window.',
          );
          exit(1);
        }
      } catch (e, st) {
        logError(
          'Main',
          'Error during wallpaper window initialization/reparenting',
          e,
          st,
        );
        exit(1);
      }
    });

    logInfo('Main', 'Starting WallpaperApp...');
    runApp(
      WallpaperApp(
        settings: settings.copyWith(
          activeWallpaperType: 'video',
          activeWallpaperPath: wallpaperVideoPath ?? '',
        ),
      ),
    );
  } else {
    if (isStartupBackground && !settingsService.settingsLoadSucceeded) {
      logError(
        'OverlayStartup',
        'Startup restoration was skipped because saved settings could not '
            'be loaded safely.',
      );
      await flushPendingLogs();
      exit(0);
    }
    logInfo('Main', 'Entering Customizer Dashboard mode');
    final isMinimized =
        args.contains('--minimized') ||
        args.contains('--silent') ||
        args.contains('--tray') ||
        isStartupBackground;

    // Configure the standard dashboard window
    const WindowOptions windowOptions = WindowOptions(
      size: Size(1100, 720),
      minimumSize: Size(960, 600),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal,
      alwaysOnTop: false,
    );

    windowManager.waitUntilReadyToShow(windowOptions, () async {
      try {
        await windowManager.setPreventClose(true);
        await windowManager.setMinimumSize(const Size(960, 600));
        if (!isMinimized) {
          await windowManager.show();
          await windowManager.focus();
          await windowManager.maximize();
        }
      } catch (e, st) {
        logError('Main', 'Failed to show the dashboard window', e, st);
      }
    });

    runApp(
      DashboardApp(
        settings: settings,
        startMinimized: isMinimized,
        isStartupBackground: isStartupBackground,
        initialTab: initialTab,
      ),
    );
    if (isStartupBackground) {
      unawaited(
        _runStartupRecoveryStage(
          'wallpaper',
          () => _restoreStartupWallpaper(settings),
        ),
      );
      unawaited(
        _runStartupRecoveryStage(
          'widgets',
          () => _restoreStartupOverlay(settings),
        ),
      );
      unawaited(
        _runStartupRecoveryStage(
          'taskbar',
          () => WindowsTaskbarService.instance.init(),
        ),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isStartupBackground) {
        unawaited(NotificationService.instance.init());
        unawaited(ShortbirdClient().init());
      }
      SystemOptimizerService.instance.startBackgroundMemoryOptimizer(
        interval: const Duration(minutes: 5),
      );
    });
  }
}

Future<void> _runStartupRecoveryStage(
  String stage,
  Future<void> Function() restore,
) async {
  logInfo('OverlayStartup', 'Startup $stage restoration started.');
  try {
    await restore();
    logInfo('OverlayStartup', 'Startup $stage restoration completed.');
  } catch (error, stackTrace) {
    logError(
      'Main',
      'Startup $stage restoration failed; the other recovery stage will '
          'continue independently.',
      error,
      stackTrace,
    );
  }
}

// ----------------------------------------------------
// Overlay Application Widget (Transparent Desk Widget)
// ----------------------------------------------------
class OverlayApp extends StatelessWidget {
  final WidgetSettings settings;
  final String? instanceId;
  const OverlayApp({super.key, required this.settings, this.instanceId});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WallSyncOverlay',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.transparent,
        canvasColor: Colors.transparent,
      ),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: DesktopWidget(initialSettings: settings, instanceId: instanceId),
      ),
    );
  }
}

// ----------------------------------------------------
// Dashboard Application Widget (Configuration Panel)
// ----------------------------------------------------
class DashboardApp extends StatefulWidget {
  final WidgetSettings settings;
  final bool startMinimized;
  final bool isStartupBackground;
  final String? initialTab;
  const DashboardApp({
    super.key,
    required this.settings,
    this.startMinimized = false,
    this.isStartupBackground = false,
    this.initialTab,
  });

  @override
  State<DashboardApp> createState() => _DashboardAppState();
}

class _DashboardAppState extends State<DashboardApp> {
  late bool _showSplash;

  @override
  void initState() {
    super.initState();
    _showSplash = !widget.startMinimized;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WallSync Pro',
      debugShowCheckedModeBanner: false,
      scrollBehavior: MyCustomScrollBehavior(),
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF07080C),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFF818CF8),
          tertiary: Color(0xFFEC4899),
          surface: Color(0xFF0F111A),
          error: Color(0xFFEF4444),
          onPrimary: Color(0xFF0F172A),
          onSurface: Colors.white,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF131622),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFF10131E),
          elevation: 24,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
          ),
        ),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: const Color(0xF0181B26),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          textStyle: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
          waitDuration: const Duration(milliseconds: 350),
        ),
        scrollbarTheme: ScrollbarThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.hovered)) {
              return const Color(0xFF38BDF8).withValues(alpha: 0.5);
            }
            return Colors.white.withValues(alpha: 0.15);
          }),
          radius: const Radius.circular(8),
          thickness: WidgetStateProperty.all(6.0),
        ),
      ),
      home: Scaffold(
        body: _showSplash
            ? AnimatedSplashScreen(
                onComplete: () {
                  setState(() {
                    _showSplash = false;
                  });
                },
              )
            : DashboardView(
                initialSettings: widget.settings,
                isStartupBackground: widget.isStartupBackground,
                initialTab: widget.initialTab,
              ),
      ),
    );
  }
}

class MyCustomScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  };
}
