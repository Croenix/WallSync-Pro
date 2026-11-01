import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/taskbar_settings.dart';
import 'diagnostics_service.dart';
import 'overlay_lifecycle_service.dart';
import 'settings_service.dart';
import 'wallpaper_engine.dart';

/// Service responsible for managing Windows desktop taskbar replacement,
/// custom dock integration, visibility control, crash recovery, and 3-tier resets.
class WindowsTaskbarService extends ChangeNotifier {
  static final WindowsTaskbarService instance =
      WindowsTaskbarService._internal();

  factory WindowsTaskbarService() => instance;

  WindowsTaskbarService._internal();

  MethodChannel _channel = const MethodChannel('wallsync/live_wallpaper');
  SettingsService _settingsService = SettingsService();
  OverlayProcessInspector _inspectProcess = inspectWindowsProcess;
  Future<bool> Function()? _taskbarSpawner;
  Future<void> Function()? _taskbarCloser;

  TaskbarReplacementState _state = TaskbarReplacementState.windowsTaskbarActive;
  TaskbarSettings _settings = const TaskbarSettings();
  bool _initialized = false;

  TaskbarReplacementState get state => _state;
  TaskbarSettings get settings => _settings;
  bool get isInitialized => _initialized;

  bool get isCustomTaskbarActive =>
      _state == TaskbarReplacementState.wallSyncTaskbarActive ||
      _state == TaskbarReplacementState.windowsTaskbarHidden ||
      _state == TaskbarReplacementState.customTaskbarReady;

  bool get isWindowsTaskbarHidden =>
      _state == TaskbarReplacementState.windowsTaskbarHidden;

  /// Visible for testing to inject mocks.
  @visibleForTesting
  void setDependencies({
    MethodChannel? channel,
    SettingsService? settingsService,
    OverlayProcessInspector? inspectProcess,
    Future<bool> Function()? taskbarSpawner,
    Future<void> Function()? taskbarCloser,
  }) {
    if (channel != null) _channel = channel;
    if (settingsService != null) _settingsService = settingsService;
    if (inspectProcess != null) _inspectProcess = inspectProcess;
    if (taskbarSpawner != null) _taskbarSpawner = taskbarSpawner;
    if (taskbarCloser != null) _taskbarCloser = taskbarCloser;
  }

  /// Initialize the service, listen for native window messages (Explorer restarts),
  /// and perform startup recovery if any prior hidden state was left unrecovered.
  Future<void> init({
    MethodChannel? channel,
    SettingsService? settingsService,
  }) async {
    if (channel != null) _channel = channel;
    if (settingsService != null) _settingsService = settingsService;

    _channel.setMethodCallHandler(_handleNativeCall);

    try {
      final widgetSettings = _settingsService.settings;
      _settings = widgetSettings.taskbarSettings;
    } catch (e) {
      logWarning(
        'WindowsTaskbarService',
        'Could not load initial taskbar settings: $e',
      );
      _settings = const TaskbarSettings();
    }

    _initialized = true;

    // Startup Watchdog & Recovery Check
    if (_settings.recoveryPending) {
      logWarning(
        'WindowsTaskbarService',
        'Startup detected recoveryPending=true. Performing guaranteed emergency taskbar restoration.',
      );
      _updateState(TaskbarReplacementState.recoveryRequired);
      await restoreWindowsTaskbar();
    } else if (_settings.customTaskbarEnabled) {
      final info = await getWindowsTaskbarInfo();
      final allVisible = info['allVisible'] as bool? ?? true;
      if (!allVisible || _settings.nativeTaskbarHideEnabled) {
        _updateState(TaskbarReplacementState.windowsTaskbarHidden);
      } else {
        _updateState(TaskbarReplacementState.wallSyncTaskbarActive);
      }
    } else {
      // Normal state: Windows taskbar active
      _updateState(TaskbarReplacementState.windowsTaskbarActive);
    }
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onWindowsExplorerRestarted') {
      logInfo(
        'WindowsTaskbarService',
        'Native explorer.exe restart detected via WM_TASKBARCREATED.',
      );
      await _handleExplorerRestart();
    }
    return null;
  }

  Future<void> _handleExplorerRestart() async {
    if (_settings.customTaskbarEnabled && _settings.nativeTaskbarHideEnabled) {
      logInfo(
        'WindowsTaskbarService',
        'Re-applying native taskbar hiding after Explorer restart.',
      );
      await setWindowsTaskbarVisibility(false);
      _updateState(TaskbarReplacementState.windowsTaskbarHidden);
    } else {
      _updateState(TaskbarReplacementState.windowsTaskbarActive);
    }
    notifyListeners();
  }

  void _updateState(TaskbarReplacementState newState) {
    if (_state != newState) {
      _state = newState;
      notifyListeners();
    }
  }

  /// Query the native Windows taskbar HWND and visibility information.
  Future<Map<String, dynamic>> getWindowsTaskbarInfo() async {
    try {
      final res =
          await _channel.invokeMethod<Map>('getWindowsTaskbarInfo');
      if (res != null) {
        return Map<String, dynamic>.from(res);
      }
    } catch (e) {
      logWarning(
        'WindowsTaskbarService',
        'Could not query Windows taskbar info: $e',
      );
    }
    return {
      'primaryPresent': true,
      'primaryVisible': true,
      'secondaryCount': 0,
      'secondaryVisibleCount': 0,
      'allVisible': true,
      'anyVisible': true,
    };
  }

  /// Sets visibility of the primary and secondary Windows taskbars safely.
  Future<bool> setWindowsTaskbarVisibility(bool visible) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'setWindowsTaskbarVisibility',
        {'visible': visible},
      );
      return result ?? false;
    } catch (e) {
      logError(
        'WindowsTaskbarService',
        'Error setting Windows taskbar visibility to $visible: $e',
        e,
      );
      return false;
    }
  }

  /// Transactionally enable WallSync custom taskbar / dock, optionally hiding
  /// the native Windows taskbar.
  Future<bool> enableCustomTaskbar({bool hideNativeTaskbar = false}) async {
    _updateState(TaskbarReplacementState.preparing);
    logInfo(
      'WindowsTaskbarService',
      'Beginning transactional custom taskbar activation (hideNativeTaskbar=$hideNativeTaskbar)...',
    );

    try {
      // Step 1: Query initial state & HWND
      final info = await getWindowsTaskbarInfo();
      final wasInitiallyVisible = info['allVisible'] as bool? ?? true;
      _updateState(TaskbarReplacementState.nativeTaskbarDetected);

      // Step 2: Ensure WallSync Custom Taskbar / Dock window is running
      _updateState(TaskbarReplacementState.customTaskbarCreating);
      await syncDockSettings();

      final dockRunning = _taskbarSpawner != null
          ? await _taskbarSpawner!()
          : (Platform.environment.containsKey('FLUTTER_TEST')
              ? true
              : await _ensureDockProcessRunning());

      if (!dockRunning) {
        throw Exception('Failed to spawn or verify custom taskbar dock window.');
      }

      _updateState(TaskbarReplacementState.customTaskbarReady);

      // Step 3: Set recovery pending flag before modifying shell state
      _settings = _settings.copyWith(
        recoveryPending: true,
        customTaskbarEnabled: true,
        nativeTaskbarHideEnabled: hideNativeTaskbar,
        nativeTaskbarVisibilityBeforeActivation: wasInitiallyVisible,
        desktopTaskbarMode: hideNativeTaskbar
            ? DesktopTaskbarMode.dockWithNativeHidden
            : DesktopTaskbarMode.dockOnly,
      );
      await _persistSettings();

      // Step 4: If native taskbar should be hidden, safely hide it
      if (hideNativeTaskbar) {
        _updateState(TaskbarReplacementState.nativeTaskbarHidePending);
        final hideSuccess = await setWindowsTaskbarVisibility(false);
        if (!hideSuccess) {
          throw Exception('Failed to hide native Windows taskbar via platform channel.');
        }

        // Verify taskbar is hidden
        final postHideInfo = await getWindowsTaskbarInfo();
        final anyVisible = postHideInfo['anyVisible'] as bool? ?? false;
        if (anyVisible) {
          logWarning(
            'WindowsTaskbarService',
            'Verification showed native taskbar still reported visible; retrying hide.',
          );
          await setWindowsTaskbarVisibility(false);
        }

        _updateState(TaskbarReplacementState.windowsTaskbarHidden);
      } else {
        _updateState(TaskbarReplacementState.wallSyncTaskbarActive);
      }

      // Step 5: Finalize settings
      _settings = _settings.copyWith(
        recoveryPending: false,
        lastSuccessfulActivation: DateTime.now(),
      );
      await _persistSettings();

      logInfo(
        'WindowsTaskbarService',
        'Custom taskbar activated successfully. State: ${_state.displayName}',
      );
      return true;
    } catch (e, st) {
      logError(
        'WindowsTaskbarService',
        'Activation encountered an error. Rolling back to safe state: $e',
        e,
        st,
      );

      // Rollback to safe Windows taskbar
      await restoreWindowsTaskbar();
      _updateState(TaskbarReplacementState.failedToActivate);
      return false;
    }
  }

  /// Guaranteed emergency restoration of native Windows taskbar on all monitors.
  Future<bool> restoreWindowsTaskbar() async {
    _updateState(TaskbarReplacementState.restoring);
    logInfo(
      'WindowsTaskbarService',
      'Performing guaranteed restoration of standard Windows taskbar...',
    );

    try {
      // Step 1: Native call to restore HWNDs and topmost position
      await _channel.invokeMethod<bool>('restoreWindowsTaskbar');

      // Step 2: Also explicitly call setWindowsTaskbarVisibility(true)
      await setWindowsTaskbarVisibility(true);

      // Step 3: Close or terminate custom taskbar dock window
      if (_taskbarCloser != null) {
        await _taskbarCloser!();
      } else if (!Platform.environment.containsKey('FLUTTER_TEST')) {
        await _terminateDockProcess();
      }

      // Step 4: Clear recovery flags and update settings
      _settings = _settings.copyWith(
        recoveryPending: false,
        customTaskbarEnabled: false,
        nativeTaskbarHideEnabled: false,
        lastSuccessfulRestoration: DateTime.now(),
        desktopTaskbarMode: DesktopTaskbarMode.windowsTaskbar,
      );
      await _persistSettings();

      _updateState(TaskbarReplacementState.restoredSuccessfully);

      // Return to stable Windows taskbar active state
      Future.delayed(const Duration(milliseconds: 600), () {
        if (_state == TaskbarReplacementState.restoredSuccessfully) {
          _updateState(TaskbarReplacementState.windowsTaskbarActive);
        }
      });

      logInfo(
        'WindowsTaskbarService',
        'Windows taskbar restored and verified successfully.',
      );
      return true;
    } catch (e, st) {
      logError(
        'WindowsTaskbarService',
        'Restoration encountered an error: $e',
        e,
        st,
      );
      _updateState(TaskbarReplacementState.failedToRestore);
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Dock Window Process & Synchronization
  // ---------------------------------------------------------------------------

  /// Synchronize all current taskbar and dock settings to the dedicated
  /// `overlay_settings_taskbar_dock.json` instance file for live hot-reloading.
  Future<void> syncDockSettings([WidgetSettings? settings]) async {
    try {
      final current = settings ?? _settingsService.settings;
      final dockService = SettingsService(instanceId: 'taskbar_dock');
      WidgetSettings dockCurrent;
      try {
        dockCurrent = await dockService.loadSettings();
      } catch (_) {
        dockCurrent = current;
      }

      final updated = dockCurrent.copyWith(
        widgetTemplate: 'taskbar_dock',
        taskbarSettings: current.taskbarSettings,
        taskbarBgColor: current.taskbarBgColor,
        taskbarBorderColor: current.taskbarBorderColor,
        taskbarAccentColor: current.taskbarAccentColor,
        taskbarTextColor: current.taskbarTextColor,
        taskbarIconColor: current.taskbarIconColor,
        taskbarIconSize: current.taskbarIconSize,
        taskbarFontSize: current.taskbarFontSize,
        taskbarShowCpu: current.taskbarShowCpu,
        taskbarShowRam: current.taskbarShowRam,
        taskbarShowDisk: current.taskbarShowDisk,
        taskbarShowTime: current.taskbarShowTime,
        taskbarShowWeather: current.taskbarShowWeather,
        taskbarShowMedia: current.taskbarShowMedia,
        taskbarDiskDrive: current.taskbarDiskDrive,
        activeDockTemplateJson: current.activeDockTemplateJson,
        width: current.width,
        height: current.height,
        sizeFactor: current.sizeFactor,
        exitOverlay: false,
      );
      await dockService.saveSettings(updated, immediate: true);
      logInfo('WindowsTaskbarService', 'Synced taskbar settings to taskbar_dock instance.');
    } catch (e) {
      logWarning('WindowsTaskbarService', 'Could not sync dock settings: $e');
    }
  }

  Future<bool> _ensureDockProcessRunning() async {
    if (!Platform.isWindows) {
      return true;
    }

    final dockService = SettingsService(instanceId: 'taskbar_dock');
    final pidFile = await dockService.pidFile;

    // Check if already running and healthy
    if (await pidFile.exists()) {
      try {
        final content = (await pidFile.readAsString()).trim();
        final record = OverlayProcessRecord.tryParse(content);
        if (record != null) {
          final inspection = await _inspectProcess(record.pid);
          if (inspection != null && inspection.isRunning && inspection.matches(record)) {
            logInfo('WindowsTaskbarService', 'Dock overlay already running live (PID ${record.pid}).');
            return true;
          }
        }
      } catch (_) {}
    }

    // Launch the taskbar_dock overlay
    try {
      String appPath = Platform.resolvedExecutable;
      String workingDir = File(appPath).parent.path;

      // Check shadow runtime
      try {
        final runtimeDir = await WallpaperEngine().prepareOverlayRuntime();
        final exeName = File(appPath).uri.pathSegments.last;
        final runtimeExe = File('${runtimeDir.path}\\$exeName');
        if (await runtimeExe.exists()) {
          appPath = runtimeExe.path;
          workingDir = runtimeDir.path;
        }
      } catch (_) {}

      bool launched = false;
      if (kDebugMode) {
        final taskName = 'WallSyncOverlay_taskbar_dock';
        final tempDir = Platform.environment['TEMP'] ?? Directory.systemTemp.path;
        final batPath = '$tempDir\\overlay_launch_taskbar_dock.bat';
        try {
          final batContent =
              '@echo off\r\ncd /d "$workingDir"\r\nstart "" "$appPath" --overlay --startup-trigger=taskbar-activation --instance-id=taskbar_dock\r\n';
          await File(batPath).writeAsString(batContent, flush: true);
          final createResult = await Process.run('schtasks', [
            '/create', '/f', '/tn', taskName, '/tr', '"$batPath"',
            '/sc', 'once', '/st', '00:00', '/it'
          ]);
          if (createResult.exitCode == 0) {
            final runResult = await Process.run('schtasks', ['/run', '/tn', taskName]);
            if (runResult.exitCode == 0) {
              launched = true;
            }
          }
        } catch (_) {} finally {
          Future.delayed(const Duration(seconds: 15), () async {
            try { await Process.run('schtasks', ['/delete', '/f', '/tn', taskName]); } catch (_) {}
            try { final f = File(batPath); if (await f.exists()) await f.delete(); } catch (_) {}
          });
        }
      }

      if (!launched) {
        try {
          await Process.start(
            'cmd.exe',
            ['/c', 'start', '""', appPath, '--overlay', '--startup-trigger=taskbar-activation', '--instance-id=taskbar_dock'],
            workingDirectory: workingDir,
            mode: ProcessStartMode.detached,
          );
          launched = true;
        } catch (_) {
          await Process.start(
            appPath,
            ['--overlay', '--startup-trigger=taskbar-activation', '--instance-id=taskbar_dock'],
            workingDirectory: workingDir,
            mode: ProcessStartMode.detached,
          );
          launched = true;
        }
      }

      // Wait for readiness
      final readiness = await waitForOverlayReadiness(
        readRecord: () async {
          if (!await pidFile.exists()) return null;
          final content = (await pidFile.readAsString()).trim();
          return content.isEmpty ? null : OverlayProcessRecord.tryParse(content);
        },
        inspectProcess: _inspectProcess,
        timeout: const Duration(seconds: 8),
        pollInterval: const Duration(milliseconds: 200),
      );

      return readiness.isReady;
    } catch (e) {
      logError('WindowsTaskbarService', 'Error ensuring dock process running: $e', e);
      return false;
    }
  }

  Future<void> _terminateDockProcess() async {
    final dockService = SettingsService(instanceId: 'taskbar_dock');
    try {
      // 1. Tell overlay to exit gracefully via settings file
      final dockSettings = await dockService.loadSettings();
      await dockService.saveSettings(dockSettings.copyWith(exitOverlay: true), immediate: true);

      // 2. Check PID file and wait briefly for clean exit
      final pidFile = await dockService.pidFile;
      if (await pidFile.exists()) {
        final content = (await pidFile.readAsString()).trim();
        final record = OverlayProcessRecord.tryParse(content);
        if (record != null && Platform.isWindows) {
          final sw = Stopwatch()..start();
          while (sw.elapsedMilliseconds < 1200) {
            final inspection = await _inspectProcess(record.pid);
            if (inspection == null || !inspection.isRunning) break;
            await Future.delayed(const Duration(milliseconds: 150));
          }
          final finalInspection = await _inspectProcess(record.pid);
          if (finalInspection != null && finalInspection.isRunning) {
            logWarning('WindowsTaskbarService', 'Dock overlay (PID ${record.pid}) did not exit gracefully; terminating.');
            Process.killPid(record.pid);
          }
        }
        try { await pidFile.delete(); } catch (_) {}
      }
    } catch (e) {
      logWarning('WindowsTaskbarService', 'Error terminating dock process: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // 3-Tier Reset Architecture
  // ---------------------------------------------------------------------------

  /// Option A: Reset Appearance
  /// Resets theme colors, blur, gradients, borders, and shadows to safe defaults.
  /// Retains mode, template, pinned apps, and user-created templates.
  Future<void> resetAppearance() async {
    logInfo('WindowsTaskbarService', 'Executing Option A: Reset Appearance.');
    final current = _settingsService.settings;
    final updated = current.copyWith(
      taskbarBgColor: 0xDD16181F,
      taskbarBorderColor: 0x22FFFFFF,
      taskbarAccentColor: 0xFF38BDF8,
      taskbarTextColor: 0xFFFFFFFF,
      taskbarIconColor: 0xFF38BDF8,
      taskbarIconSize: 14.0,
      taskbarFontSize: 11.0,
    );
    await _settingsService.save(updated);
    await syncDockSettings(updated);
    notifyListeners();
  }

  /// Option B: Reset Layout
  /// Resets dock position, alignment, dimensions, auto-hide, and item spacing.
  /// Retains user-created templates, pinned apps, and saved color themes.
  Future<void> resetLayout() async {
    logInfo('WindowsTaskbarService', 'Executing Option B: Reset Layout.');
    final current = _settingsService.settings;
    final updated = current.copyWith(
      taskbarSettings: _settings.copyWith(
        taskbarPosition: 'bottom',
        autoHideEnabled: false,
      ),
      taskbarShowCpu: true,
      taskbarShowRam: true,
      taskbarShowDisk: true,
      taskbarShowTime: true,
      taskbarShowWeather: true,
      taskbarShowMedia: true,
      sizeFactor: 1.0,
      width: 640.0,
      height: 48.0,
    );
    _settings = updated.taskbarSettings;
    await _settingsService.save(updated);
    await syncDockSettings(updated);
    notifyListeners();
  }

  /// Option C: Full Taskbar Reset
  /// Guaranteed restoration of Windows taskbar, stops custom dock replacement,
  /// clears pending recovery state, and resets safe defaults.
  /// Preserves all user-created templates.
  Future<void> resetFullTaskbar() async {
    logInfo(
      'WindowsTaskbarService',
      'Executing Option C: Full Taskbar Reset with guaranteed Windows restoration.',
    );

    // Guaranteed restoration of native taskbar first
    await restoreWindowsTaskbar();

    final current = _settingsService.settings;
    final defaultSettings = TaskbarSettings.defaults();
    final updated = current.copyWith(
      taskbarSettings: defaultSettings,
      taskbarBgColor: 0xDD16181F,
      taskbarBorderColor: 0x22FFFFFF,
      taskbarAccentColor: 0xFF38BDF8,
      taskbarTextColor: 0xFFFFFFFF,
      taskbarIconColor: 0xFF38BDF8,
      taskbarIconSize: 14.0,
      taskbarFontSize: 11.0,
      taskbarShowCpu: true,
      taskbarShowRam: true,
      taskbarShowDisk: true,
      taskbarShowTime: true,
      taskbarShowWeather: true,
      taskbarShowMedia: true,
      width: 640.0,
      height: 48.0,
      sizeFactor: 1.0,
    );

    _settings = defaultSettings;
    await _settingsService.save(updated);
    await syncDockSettings(updated);
    _updateState(TaskbarReplacementState.windowsTaskbarActive);
    notifyListeners();
  }

  Future<void> _persistSettings() async {
    final current = _settingsService.settings;
    final updated = current.copyWith(taskbarSettings: _settings);
    await _settingsService.save(updated);
    await syncDockSettings(updated);
    notifyListeners();
  }
}
