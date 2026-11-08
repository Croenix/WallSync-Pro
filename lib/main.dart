import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import 'config/api.dart';
import 'models/taskbar_settings.dart';
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
import 'services/custom_font_service.dart';
import 'services/custom_asset_service.dart';
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
    fields.add('templateId=$overlayType');
  }
  if (reason != null && reason.isNotEmpty) {
    fields.add('reason=${reason.replaceAll(RegExp(r'\s+'), ' ')}');
  }
  final tag = switch (mode) {
    ProcessMode.main => 'MainBootstrap',
    ProcessMode.wallpaper => 'WallpaperBootstrap',
    ProcessMode.classic => 'OverlayBootstrap',
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

  var executable = Platform.resolvedExecutable;
  var workingDirectory = File(executable).parent.path;
  final activeIds = settings.activeWidgetIds;
  if (activeIds.isEmpty) {
    logInfo(
      'OverlayStartup',
      'No enabled desktop widgets are configured for startup restoration.',
    );
    return;
  }
  final restorableIds = activeIds
      .where((id) => !id.startsWith('taskbar_'))
      .toList(growable: false);
  if (restorableIds.isEmpty &&
      activeIds.any((id) => id.startsWith('taskbar_'))) {
    logInfo(
      'OverlayStartup',
      'Saved taskbar dock widgets are no longer supported; skipping widget restoration.',
    );
    return;
  }

  try {
    final runtimeDirectory = await WallpaperEngine().prepareOverlayRuntime();
    final executableName = File(executable).uri.pathSegments.last;
    final runtimeExecutable = File('${runtimeDirectory.path}\\$executableName');
    if (await runtimeExecutable.exists()) {
      executable = runtimeExecutable.path;
      workingDirectory = runtimeDirectory.path;
    }
  } catch (error) {
    logWarning(
      'OverlayStartup',
      'Could not prepare an isolated widget runtime; using the application '
          'executable. Error: $error',
    );
  }

  for (final id in restorableIds) {
    final instService = SettingsService(instanceId: id);
    final pidFile = await instService.pidFile;
    bool isRunning = false;
    String? pidContents;
    try {
      pidContents = await readOverlayPidFileContents(pidFile);
    } on FileSystemException catch (error, stackTrace) {
      logError(
        'OverlayStartup',
        'Startup restoration deferred for "$id" because its PID record '
            'could not be read safely.',
        error,
        stackTrace,
      );
      continue;
    }
    if (pidContents != null) {
      final record = OverlayProcessRecord.tryParse(pidContents);
      if (record != null) {
        final inspection = await inspectWindowsProcess(record.pid);
        if (inspection != null &&
            inspection.isRunning &&
            inspection.matches(record)) {
          if (record.instanceId != null && record.instanceId != id ||
              record.templateId != null && record.templateId != id) {
            logError(
              'OverlayStartup',
              'Startup restoration skipped "$id" because its PID record '
                  'belongs to instance=${record.instanceId} '
                  'template=${record.templateId}.',
            );
            continue;
          }
          isRunning = true;
        }
      } else {
        logWarning(
          'OverlayStartup',
          'Startup restoration found malformed PID state for "$id"; '
              'the record was left untouched.',
        );
        continue;
      }
    }
    if (!isRunning) {
      try {
        final process = await Process.start(
          executable,
          [
            '--overlay',
            '--startup-trigger=windows-logon',
            '--instance-id=$id',
            '--template-id=$id',
            '--operation-id=${DateTime.now().millisecondsSinceEpoch}',
            '--config-revision=1',
          ],
          environment: const {'FLUTTER_ENGINE_SWITCHES': '0'},
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
    templateId: processArguments.templateId,
    operationId: processArguments.operationId,
    configurationRevision: processArguments.configurationRevision,
  );
  await processDiagnostics.record(
    'arguments_received',
    'arguments=${args.map((argument) => '"$argument"').join(' ')}',
  );
  await processDiagnostics.record(
    'process_mode_validation',
    'result=valid mode=${processArguments.mode.value}',
  );
  if (processArguments.mode.isOverlay) {
    await processDiagnostics.record(
      'overlay_mode_confirmed',
      'result=success templateId=${processArguments.templateId ?? 'not-specified'}',
    );
  }

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
    overlayType: isOverlayMode ? processArguments.templateId : null,
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
  await processDiagnostics.record(
    'flutter_binding_initialized',
    'result=success',
  );
  _emitOverlayBootstrapEvent(
    'flutter_engine_initialized',
    pid: pid,
    instanceId: processArguments.instanceId ?? '',
    operationId: processArguments.operationId,
    configRevision: processArguments.configurationRevision,
    stopwatch: startupStopwatch,
    overlayType: isOverlayMode ? processArguments.templateId : null,
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
    final message = details.exceptionAsString();
    final isRenderFlexOverflow = message.contains('A RenderFlex overflowed');
    final diagnosticContext = isRenderFlexOverflow
        ? details.informationCollector
              ?.call()
              .map((diagnostic) => diagnostic.toString())
              .join('\n')
        : null;
    logError(
      'FlutterError',
      diagnosticContext == null || diagnosticContext.isEmpty
          ? message
          : '$message\n$diagnosticContext',
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
      'Startup trigger re+ceived; source=$startupTrigger, pid=$pid.',
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
    overlayType: isOverlayMode ? processArguments.templateId : null,
  );

  final overlayInstanceId = processArguments.instanceId ?? '';
  var overlayType = isOverlayMode ? (processArguments.templateId ?? '') : '';
  final overlayOperationId = processArguments.operationId;
  final overlayConfigRevision = processArguments.configurationRevision;

  _emitOverlayBootstrapEvent(
    'arguments_parsed',
    pid: pid,
    instanceId: overlayInstanceId,
    operationId: overlayOperationId,
    configRevision: overlayConfigRevision,
    stopwatch: startupArgsStopwatch,
    overlayType: overlayType,
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
  if (isOverlayMode) {
    if (!settingsService.settingsLoadSucceeded) {
      await _failOverlayStartup(
        'Could not load the authoritative overlay configuration from '
        '"${settingsFile.path}".',
      );
    }
    final resolvedTemplateId = settings.widgetTemplate;
    final supportedTemplateIds = WidgetSettings.templateDefaults.keys
        .where((id) => !id.startsWith('taskbar_'))
        .toSet();
    if (!supportedTemplateIds.contains(resolvedTemplateId)) {
      await _failOverlayStartup(
        'Overlay configuration resolved unsupported template '
        '"$resolvedTemplateId" for instance "$overlayInstanceId".',
      );
    }
    if (processArguments.templateId != null &&
        processArguments.templateId != resolvedTemplateId) {
      await _failOverlayStartup(
        'Requested template "${processArguments.templateId}" does not match '
        'the authoritative instance configuration "$resolvedTemplateId" '
        'for instance "$overlayInstanceId".',
      );
    }
    overlayType = resolvedTemplateId;
    processDiagnostics.setContext(
      processMode: processArguments.mode.value,
      instanceId: overlayInstanceId,
      templateId: resolvedTemplateId,
      operationId: overlayOperationId,
      configurationRevision: overlayConfigRevision,
    );
    await processDiagnostics.record(
      'template_resolution',
      'requestedTemplateId=${processArguments.templateId ?? 'not-specified'} '
          'resolvedTemplateId=$resolvedTemplateId '
          'renderedWidgetClass=DesktopWidget '
          'renderedLayout=${DesktopWidget.layoutForTemplate(resolvedTemplateId).name} '
          'configurationRevision=$overlayConfigRevision',
    );
    logInfo(
      'OverlayStartup',
      'Resolved widget template: requested=${processArguments.templateId ?? 'not-specified'}, '
          'resolved=$resolvedTemplateId, instanceId=$overlayInstanceId, '
          'processMode=${processArguments.mode.value}, '
          'renderedWidgetClass=DesktopWidget/'
          '${DesktopWidget.layoutForTemplate(resolvedTemplateId).name}, '
          'configurationRevision=$overlayConfigRevision.',
    );
  }
  logPerf(
    'OverlayStartup',
    'Settings file load completed in ${settingsLoadMs}ms '
        '(startup total ${startupStopwatch.elapsedMilliseconds}ms, '
        'overlay=$isOverlayMode, wallpaper=$isWallpaperMode).',
  );
  if (isOverlayMode) {
    await processDiagnostics.record(
      'overlay_services_initialized',
      'result=success settingsLoadedMs=$settingsLoadMs',
    );
  }
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
    unawaited(CustomFontService.instance.init());
    unawaited(CustomAssetService.instance.init());
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
    overlayType: overlayType,
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
      overlayType: overlayType,
    );
    _emitOverlayBootstrapEvent(
      'overlay_type_selected',
      pid: pid,
      instanceId: overlayInstanceId,
      operationId: overlayOperationId,
      configRevision: overlayConfigRevision,
      stopwatch: startupStopwatch,
      overlayType: overlayType,
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
    var cleanSettings = settings.exitOverlay
        ? await settingsService.updateSettings(
            (current) => current.copyWith(exitOverlay: false),
          )
        : settings;
    final normalizedSettings = cleanSettings.normalizedWindowSize();
    if (normalizedSettings.width != cleanSettings.width ||
        normalizedSettings.height != cleanSettings.height) {
      logWarning(
        'OverlayStartup',
        'Recovered invalid saved widget size for "$overlayType": '
            '${cleanSettings.width}x${cleanSettings.height} -> '
            '${normalizedSettings.width}x${normalizedSettings.height}.',
      );
      await settingsService.saveSettings(normalizedSettings);
      cleanSettings = normalizedSettings;
    }

    int? overlayHwnd;
    final nativeWindowCreatedMs = DateTime.now().millisecondsSinceEpoch;
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
      _emitOverlayBootstrapEvent(
        'hwnd_created',
        pid: pid,
        instanceId: overlayInstanceId,
        operationId: overlayOperationId,
        configRevision: overlayConfigRevision,
        stopwatch: startupStopwatch,
        overlayType: overlayType,
        reason: 'hwnd=$overlayHwnd',
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
      templateId: overlayType,
      processMode: processArguments.mode.value,
      diagnosticLogPath: processDiagnostics.path,
      hwnd: overlayHwnd,
      operationId: overlayOperationId,
      configurationRevision: overlayConfigRevision,
      startupTimestamp: overlayEntryPointMs,
      entryPointMs: overlayEntryPointMs,
      settingsLoadedMs: settingsLoadMs,
      windowInitMs: nativeWindowCreatedMs,
    );
    final overlayPidFile = await settingsService.pidFile;
    await processDiagnostics.record(
      'pid_file_write',
      'result=success path="${overlayPidFile.path}" hwnd=$overlayHwnd',
    );
    await processDiagnostics.record(
      'ipc_connected',
      'transport=atomic-process-record instanceId=$overlayInstanceId '
          'pid=$pid hwnd=$overlayHwnd',
    );
    await processDiagnostics.record(
      'readiness_channel_started',
      'transport=atomic-process-record path="${overlayPidFile.path}"',
    );
    final processRegistrationStopwatch = Stopwatch()..start();
    await OverlayLifecycleService.updateCurrentProcessState(
      settingsService,
      state: OverlayLifecycleState.engineInitialized,
      stage: DockReadinessStage.processRunning,
      hwnd: overlayHwnd,
      instanceId: overlayInstanceId,
      templateId: overlayType,
      processMode: processArguments.mode.value,
      operationId: overlayOperationId,
      configurationRevision: overlayConfigRevision,
      windowInitMs: nativeWindowCreatedMs,
    );
    await processDiagnostics.record(
      'engine_initialized',
      'pid=$pid hwnd=$overlayHwnd instanceId=$overlayInstanceId '
          'templateId=$overlayType operationId=${overlayOperationId ?? 'none'} '
          'elapsedMs=${startupStopwatch.elapsedMilliseconds}',
    );
    await OverlayLifecycleService.updateCurrentProcessState(
      settingsService,
      state: OverlayLifecycleState.hwndCreated,
      stage: DockReadinessStage.processRunning,
      hwnd: overlayHwnd,
      instanceId: overlayInstanceId,
      templateId: overlayType,
      processMode: processArguments.mode.value,
      operationId: overlayOperationId,
      configurationRevision: overlayConfigRevision,
    );
    await processDiagnostics.record(
      'hwnd_created',
      'pid=$pid hwnd=$overlayHwnd instanceId=$overlayInstanceId '
          'templateId=$overlayType operationId=${overlayOperationId ?? 'none'} '
          'elapsedMs=${startupStopwatch.elapsedMilliseconds}',
    );
    logInfo(
      'OverlayStartup',
      'Process identity verified and registered; pid=$pid, instanceId=$overlayInstanceId, type=$overlayType, opId=$overlayOperationId, configRev=$overlayConfigRevision, state=processStarted, stage=processRunning, hwnd=$overlayHwnd.',
    );

    // Configure the transparent, frameless, always-on-top overlay window
    final WindowOptions windowOptions = WindowOptions(
      size: Size(cleanSettings.width, cleanSettings.height),
      minimumSize: const Size(180, 60),
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
    bool overlayPresentationVerified = false;
    Future<void>? overlayConfigurationInProgress;
    final nativeWindowReady = Completer<void>();

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

        if (requestedPosition != null) {
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
        await OverlayLifecycleService.updateCurrentProcessState(
          settingsService,
          state: OverlayLifecycleState.windowConfigured,
          stage: DockReadinessStage.windowInteractive,
          hwnd: overlayHwnd,
          instanceId: overlayInstanceId,
          templateId: overlayType,
          processMode: processArguments.mode.value,
          operationId: overlayOperationId,
          configurationRevision: overlayConfigRevision,
        );
        await processDiagnostics.record(
          'window_configured',
          'pid=$pid hwnd=$overlayHwnd instanceId=$overlayInstanceId '
              'templateId=$overlayType operationId=${overlayOperationId ?? 'none'} '
              'bounds=${requestedPosition ?? 'center'},'
              '${cleanSettings.width}x${cleanSettings.height} '
              'alwaysOnTop=${cleanSettings.alwaysOnTop} '
              'elapsedMs=${startupStopwatch.elapsedMilliseconds}',
        );
        if (Platform.isWindows && !cleanSettings.alwaysOnTop) {
          await processDiagnostics.record(
            'widget_desktop_surface',
            'result=requested attach=true alwaysOnTop=false',
          );
          final attached = await const MethodChannel('wallsync/live_wallpaper')
              .invokeMethod<bool>('setWidgetDesktopSurface', {
                'attachToDesktop': true,
              });
          await processDiagnostics.record(
            'widget_desktop_surface',
            'result=${attached == true ? 'success' : 'failed'} attach=true',
          );
          if (attached != true) {
            throw StateError(
              'Windows could not attach the widget to its desktop surface.',
            );
          }
        }

        if (Platform.isWindows) {
          final showRequested = await const MethodChannel(
            'wallsync/live_wallpaper',
          ).invokeMethod<bool>('showWidgetWindow');
          if (showRequested != true) {
            throw StateError(
              'The native runner could not show the widget without activation.',
            );
          }
        } else {
          await timeWindowOperation('show', windowManager.show);
        }
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
              'Overlay window is not visible yet; hwnd=$overlayHwnd '
                  'instanceId=$overlayInstanceId templateId=$overlayType '
                  'operationId=${overlayOperationId ?? 'none'} retry=$attempt, '
                  'delay=${delay.inMilliseconds}ms.',
            );
          },
        );
        if (!visible) {
          await processDiagnostics.record(
            'window_visibility_failure',
            'pid=$pid hwnd=$overlayHwnd instanceId=$overlayInstanceId '
                'templateId=$overlayType operationId=${overlayOperationId ?? 'none'} '
                'elapsedMs=${startupStopwatch.elapsedMilliseconds}',
          );
          throw StateError(
            'Overlay window did not become visible after bounded retries.',
          );
        }
        await OverlayLifecycleService.updateCurrentProcessState(
          settingsService,
          state: OverlayLifecycleState.windowShown,
          stage: DockReadinessStage.windowVisible,
          hwnd: overlayHwnd,
          instanceId: overlayInstanceId,
          templateId: overlayType,
          processMode: processArguments.mode.value,
          operationId: overlayOperationId,
          configurationRevision: overlayConfigRevision,
        );
        await processDiagnostics.record(
          'window_shown',
          'result=success pid=$pid hwnd=$overlayHwnd '
              'instanceId=$overlayInstanceId templateId=$overlayType '
              'operationId=${overlayOperationId ?? 'none'} '
              'elapsedMs=${startupStopwatch.elapsedMilliseconds}',
        );

        WidgetsBinding.instance.scheduleFrame();
        await WidgetsBinding.instance.endOfFrame;
        final presentationStopwatch = Stopwatch()..start();
        Map<String, dynamic>? windowInfo;
        var presentationVerified = false;
        for (var attempt = 1; attempt <= 3; attempt++) {
          final rawWindowInfo =
              await const MethodChannel(
                'wallsync/live_wallpaper',
              ).invokeMethod<Map>('verifyWidgetPresentation', {
                'alwaysOnTop': cleanSettings.alwaysOnTop,
              });
          if (rawWindowInfo == null) {
            throw StateError(
              'The native runner returned no presentation diagnostics.',
            );
          }
          windowInfo = Map<String, dynamic>.from(rawWindowInfo);
          final expectedParenting =
              cleanSettings.alwaysOnTop ||
              windowInfo['desktopAttached'] == true;
          final expectedZOrder =
              windowInfo['isTopmost'] == cleanSettings.alwaysOnTop;
          presentationVerified =
              windowInfo['presentationVerified'] == true &&
              expectedParenting &&
              expectedZOrder;
          final classification = presentationVerified
              ? 'presentation_success'
              : !expectedZOrder || !expectedParenting
              ? 'z_order_failure'
              : windowInfo['classification'] ?? 'presentation_failure';
          await processDiagnostics.record(
            classification,
            'attempt=$attempt pid=$pid hwnd=$overlayHwnd '
            'instanceId=$overlayInstanceId templateId=$overlayType '
            'operationId=${overlayOperationId ?? 'none'} '
            'elapsedMs=${presentationStopwatch.elapsedMilliseconds} '
            'expectedAlwaysOnTop=${cleanSettings.alwaysOnTop} '
            'actual=${windowInfo.toString()}',
          );
          if (presentationVerified) break;
          if (classification != 'presentation_failure') break;
          if (attempt < 3) {
            await Future<void>.delayed(Duration(milliseconds: 40 * attempt));
          }
        }
        if (!presentationVerified || windowInfo == null) {
          throw StateError(
            'The desktop widget did not pass native presentation verification: '
            '${windowInfo ?? 'no window data'}.',
          );
        }

        final actualWindowSize = await windowManager.getSize();
        if (actualWindowSize.width <= 0 || actualWindowSize.height <= 0) {
          await processDiagnostics.record(
            'window_bounds_failure',
            'pid=$pid hwnd=$overlayHwnd windowSize=$actualWindowSize '
                'elapsedMs=${presentationStopwatch.elapsedMilliseconds}',
          );
          throw StateError(
            'Visible overlay window has unusable size '
            '${actualWindowSize.width}x${actualWindowSize.height}.',
          );
        }
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
            windowInfo['onMonitor'] != true ||
            windowInfo['isIconic'] == true ||
            windowInfo['isCloaked'] == true) {
          await processDiagnostics.record(
            'window_visibility_failure',
            'pid=$pid hwnd=$nativeHwnd ownerPid=$ownerPid '
                'instanceId=$overlayInstanceId templateId=$overlayType '
                'operationId=${overlayOperationId ?? 'none'} nativeInfo=$windowInfo',
          );
          throw StateError(
            'The visible native HWND failed ownership or bounds verification: '
            'recordedHwnd=$overlayHwnd nativeInfo=$windowInfo',
          );
        }
        await processDiagnostics.record(
          'native_window_created',
          'result=success hwnd=$nativeHwnd ownerPid=$ownerPid '
              'instanceId=$overlayInstanceId templateId=$overlayType '
              'operationId=${overlayOperationId ?? 'none'}',
        );
        await processDiagnostics.record(
          'native_window_initialization',
          'result=verified hwnd=$nativeHwnd ownerPid=$ownerPid '
              'visible=true bounds=${boundsWidth}x$boundsHeight',
        );
        await processDiagnostics.record(
          'window_bounds_verified',
          'hwnd=$nativeHwnd ownerPid=$ownerPid bounds=${windowInfo['left']},'
              '${windowInfo['top']},${windowInfo['right']},'
              '${windowInfo['bottom']} onMonitor=true',
        );
        await processDiagnostics.record(
          'window_shown',
          'result=verified hwnd=$nativeHwnd visible=true '
              'bounds=${windowInfo['left']},${windowInfo['top']},'
              '${windowInfo['right']},${windowInfo['bottom']} '
              'onMonitor=${windowInfo['onMonitor']} '
              'isIconic=${windowInfo['isIconic']} '
              'isCloaked=${windowInfo['isCloaked']}',
        );
        await OverlayLifecycleService.updateCurrentProcessState(
          settingsService,
          state: OverlayLifecycleState.presentationVerified,
          stage: DockReadinessStage.windowInteractive,
          hwnd: overlayHwnd,
          instanceId: overlayInstanceId,
          templateId: overlayType,
          processMode: processArguments.mode.value,
          operationId: overlayOperationId,
          configurationRevision: overlayConfigRevision,
        );
        overlayPresentationVerified = true;

        logInfo(
          'OverlayStartup',
          'Overlay window is visible and usable '
              '(${actualWindowSize.width}x${actualWindowSize.height}).',
        );
        await processDiagnostics.record(
          'hwnd_registered',
          'result=success hwnd=${overlayHwnd ?? 0} ownerPid=$pid',
        );
        _emitOverlayBootstrapEvent(
          'hwnd_registered',
          pid: pid,
          instanceId: overlayInstanceId,
          operationId: overlayOperationId,
          configRevision: overlayConfigRevision,
          stopwatch: startupStopwatch,
          overlayType: overlayType,
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
          !firstFlutterFrameRendered ||
          !overlayPresentationVerified) {
        return;
      }
      final pending = readinessRegistration;
      if (pending != null) return pending;
      late final Future<void> registration;
      final readyPublishedMs = DateTime.now().millisecondsSinceEpoch;
      registration =
          () async {
            await OverlayLifecycleService.markCurrentProcessReady(
              settingsService,
              readyPublishedMs: readyPublishedMs,
              hwnd: overlayHwnd,
              instanceId: overlayInstanceId,
              templateId: overlayType,
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
      await processDiagnostics.record(
        'ready',
        'result=success instanceId=$overlayInstanceId '
            'hwnd=${overlayHwnd ?? 0}',
      );
      _emitOverlayBootstrapEvent(
        'readiness_acknowledged',
        pid: pid,
        instanceId: overlayInstanceId,
        operationId: overlayOperationId,
        configRevision: overlayConfigRevision,
        stopwatch: startupStopwatch,
        overlayType: overlayType,
        reason: 'readyPublishedMs=$readyPublishedMs, hwnd=${overlayHwnd ?? 0}',
      );
      logInfo(
        'OverlayStartup',
        'Overlay native presentation checks passed and widget ready; startup '
            'completed after window configuration and first Flutter frame '
            '(${startupStopwatch.elapsedMilliseconds}ms '
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
        overlayType: overlayType,
      );
      await processDiagnostics.record('window_ready_to_show', 'result=success');
      if (!nativeWindowReady.isCompleted) {
        nativeWindowReady.complete();
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
          final failureClass = firstFlutterFrameRendered
              ? 'window_visibility_failure'
              : 'flutter_frame_failure';
          await processDiagnostics.record(
            failureClass,
            'pid=$pid hwnd=${overlayHwnd ?? 0} '
            'instanceId=$overlayInstanceId templateId=$overlayType '
            'operationId=${overlayOperationId ?? 'none'} '
            'elapsedMs=${startupStopwatch.elapsedMilliseconds} '
            'reason=readiness_deadline_exceeded',
          );
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
      await processDiagnostics.record(
        'flutter_first_frame_rendered',
        'result=success hwnd=${overlayHwnd ?? 0} '
            'pid=$pid instanceId=$overlayInstanceId templateId=$overlayType '
            'operationId=${overlayOperationId ?? 'none'} '
            'frameTimestampMs=$firstFrameMs '
            'elapsedMs=${startupStopwatch.elapsedMilliseconds}',
      );
      await OverlayLifecycleService.updateCurrentProcessState(
        settingsService,
        state: OverlayLifecycleState.firstFrameRendered,
        stage: DockReadinessStage.windowInteractive,
        hwnd: overlayHwnd,
        instanceId: overlayInstanceId,
        templateId: overlayType,
        processMode: processArguments.mode.value,
        operationId: overlayOperationId,
        configurationRevision: overlayConfigRevision,
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
        await nativeWindowReady.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException(
            'Native widget window was not ready after the first Flutter frame.',
          ),
        );
        logInfo(
          'OverlayStartup',
          'Flutter first frame and native window are ready; configuring and '
              'showing widget hwnd=$overlayHwnd.',
        );
        await showAndPositionOverlay();
        await markOverlayReady();
      } catch (error, stackTrace) {
        final failureClass = error is TimeoutException
            ? 'window_visibility_failure'
            : 'presentation_failure';
        await processDiagnostics.record(
          failureClass,
          'pid=$pid hwnd=$overlayHwnd instanceId=$overlayInstanceId '
          'templateId=$overlayType operationId=${overlayOperationId ?? 'none'} '
          'elapsedMs=${startupStopwatch.elapsedMilliseconds} error="$error"',
        );
        await OverlayLifecycleService.markCurrentProcessFailed(
          settingsService,
          reason: 'Widget initial presentation failed: $error',
          hwnd: overlayHwnd,
          instanceId: overlayInstanceId,
        );
        await _failOverlayStartup(
          'Widget failed to reach verified initial presentation: $error',
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
        unawaited(CustomFontService.instance.checkForUpdatesOnStartup());
        unawaited(CustomAssetService.instance.checkForUpdatesOnStartup());
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
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.noScaling,
        ),
        child: child!,
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
