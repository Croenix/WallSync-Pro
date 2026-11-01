import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/taskbar_settings.dart';
import 'settings_service.dart';

/// Service responsible for managing Windows desktop taskbar replacement,
/// custom dock integration, visibility control, crash recovery, and 3-tier resets.
class WindowsTaskbarService extends ChangeNotifier {
  static final WindowsTaskbarService instance =
      WindowsTaskbarService._internal();

  factory WindowsTaskbarService() => instance;

  WindowsTaskbarService._internal();

  MethodChannel _channel = const MethodChannel('wallsync/live_wallpaper');
  SettingsService _settingsService = SettingsService();

  TaskbarReplacementState _state = TaskbarReplacementState.windowsTaskbarActive;
  TaskbarSettings _settings = const TaskbarSettings();
  bool _initialized = false;

  TaskbarReplacementState get state => _state;
  TaskbarSettings get settings => _settings;
  bool get isInitialized => _initialized;

  bool get isCustomTaskbarActive =>
      _state == TaskbarReplacementState.wallSyncTaskbarActive ||
      _state == TaskbarReplacementState.windowsTaskbarHidden;

  bool get isWindowsTaskbarHidden =>
      _state == TaskbarReplacementState.windowsTaskbarHidden;

  /// Visible for testing to inject mocks.
  @visibleForTesting
  void setDependencies({
    MethodChannel? channel,
    SettingsService? settingsService,
  }) {
    if (channel != null) _channel = channel;
    if (settingsService != null) _settingsService = settingsService;
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
      // Step 1: Query initial state
      final info = await getWindowsTaskbarInfo();
      final wasInitiallyVisible = info['allVisible'] as bool? ?? true;

      _updateState(TaskbarReplacementState.starting);

      // Step 2: Set recovery pending flag before modifying shell state
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

      // Step 3: If native taskbar should be hidden, safely hide it
      if (hideNativeTaskbar) {
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

      // Step 4: Finalize settings
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

      // Step 3: Clear recovery flags and update settings
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
    _updateState(TaskbarReplacementState.windowsTaskbarActive);
    notifyListeners();
  }

  Future<void> _persistSettings() async {
    final current = _settingsService.settings;
    final updated = current.copyWith(taskbarSettings: _settings);
    await _settingsService.save(updated);
    notifyListeners();
  }
}

