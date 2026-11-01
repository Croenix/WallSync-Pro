import 'dart:convert';

/// Operating modes for the desktop taskbar / dock system.
enum DesktopTaskbarMode {
  /// Standard Windows taskbar active, WallSync dock not acting as taskbar.
  windowsTaskbar,

  /// WallSync custom dock active alongside the standard Windows taskbar.
  dockOnly,

  /// WallSync dock active and native Windows taskbar hidden.
  dockWithNativeHidden,

  /// Full taskbar replacement mode.
  customTaskbar,

  /// Custom dock and taskbar replacement disabled.
  disabled,
}

/// Explicit lifecycle and verification states for taskbar replacement.
enum TaskbarReplacementState {
  /// Custom dock and taskbar replacement disabled.
  disabled,

  /// Standard Windows taskbar is active and verified visible.
  windowsTaskbarActive,

  /// Preparing resources, templates, and baseline settings.
  preparing,

  /// Verified native Windows taskbar HWND and initial bounds.
  nativeTaskbarDetected,

  /// Spawning or initializing custom dock / taskbar window process.
  customTaskbarCreating,

  /// Custom taskbar / dock window verified running, visible, and interactive.
  customTaskbarReady,

  /// Launching/positioning the custom taskbar or dock.
  starting,

  /// WallSync custom taskbar or dock is verified active and interactive.
  wallSyncTaskbarActive,

  /// Native Windows taskbar hide operation pending.
  nativeTaskbarHidePending,

  /// Native Windows taskbar has been safely hidden and desktop work area updated.
  windowsTaskbarHidden,

  /// Restoration of native Windows taskbar is currently underway.
  restoring,

  /// Native Windows taskbar was successfully verified restored.
  restoredSuccessfully,

  /// Activation encountered an error and rolled back safely.
  failedToActivate,

  /// Automatic or manual restoration failed (watchdog intervention needed).
  failedToRestore,

  /// System detected an unrecovered state requiring user or automatic recovery.
  recoveryRequired,
}

extension TaskbarReplacementStateX on TaskbarReplacementState {
  String get displayName {
    switch (this) {
      case TaskbarReplacementState.disabled:
        return 'Custom Taskbar Disabled';
      case TaskbarReplacementState.windowsTaskbarActive:
        return 'Windows Taskbar Active';
      case TaskbarReplacementState.preparing:
        return 'WallSync Taskbar Preparing';
      case TaskbarReplacementState.nativeTaskbarDetected:
        return 'Native Taskbar Detected';
      case TaskbarReplacementState.customTaskbarCreating:
        return 'Custom Taskbar Creating';
      case TaskbarReplacementState.customTaskbarReady:
        return 'Custom Taskbar Ready';
      case TaskbarReplacementState.starting:
        return 'WallSync Taskbar Starting';
      case TaskbarReplacementState.wallSyncTaskbarActive:
        return 'WallSync Taskbar Active';
      case TaskbarReplacementState.nativeTaskbarHidePending:
        return 'Native Hide Pending';
      case TaskbarReplacementState.windowsTaskbarHidden:
        return 'Windows Taskbar Hidden';
      case TaskbarReplacementState.restoring:
        return 'Restoration in Progress';
      case TaskbarReplacementState.restoredSuccessfully:
        return 'Restored Successfully';
      case TaskbarReplacementState.failedToActivate:
        return 'Failed to Activate';
      case TaskbarReplacementState.failedToRestore:
        return 'Failed to Restore';
      case TaskbarReplacementState.recoveryRequired:
        return 'Recovery Required';
    }
  }

  bool get isHealthy =>
      this == TaskbarReplacementState.disabled ||
      this == TaskbarReplacementState.windowsTaskbarActive ||
      this == TaskbarReplacementState.wallSyncTaskbarActive ||
      this == TaskbarReplacementState.windowsTaskbarHidden ||
      this == TaskbarReplacementState.restoredSuccessfully ||
      this == TaskbarReplacementState.customTaskbarReady;

  bool get isProcessing =>
      this == TaskbarReplacementState.preparing ||
      this == TaskbarReplacementState.starting ||
      this == TaskbarReplacementState.nativeTaskbarDetected ||
      this == TaskbarReplacementState.customTaskbarCreating ||
      this == TaskbarReplacementState.nativeTaskbarHidePending ||
      this == TaskbarReplacementState.restoring;

  bool get isError =>
      this == TaskbarReplacementState.failedToActivate ||
      this == TaskbarReplacementState.failedToRestore ||
      this == TaskbarReplacementState.recoveryRequired;
}

/// Dedicated, versioned settings model for desktop taskbar & dock management.
class TaskbarSettings {
  final DesktopTaskbarMode desktopTaskbarMode;
  final bool customTaskbarEnabled;
  final bool nativeTaskbarHideEnabled;
  final bool nativeTaskbarVisibilityBeforeActivation;
  final String activeTemplateId;
  final String? activeMonitorId;
  final String taskbarPosition;
  final bool autoHideEnabled;
  final bool recoveryEnabled;
  final DateTime? lastSuccessfulActivation;
  final DateTime? lastSuccessfulRestoration;
  final bool recoveryPending;
  final int configurationVersion;

  const TaskbarSettings({
    this.desktopTaskbarMode = DesktopTaskbarMode.windowsTaskbar,
    this.customTaskbarEnabled = false,
    this.nativeTaskbarHideEnabled = false,
    this.nativeTaskbarVisibilityBeforeActivation = true,
    this.activeTemplateId = 'centered_dock',
    this.activeMonitorId,
    this.taskbarPosition = 'bottom',
    this.autoHideEnabled = false,
    this.recoveryEnabled = true,
    this.lastSuccessfulActivation,
    this.lastSuccessfulRestoration,
    this.recoveryPending = false,
    this.configurationVersion = 1,
  });

  factory TaskbarSettings.defaults() => const TaskbarSettings();

  TaskbarSettings copyWith({
    DesktopTaskbarMode? desktopTaskbarMode,
    bool? customTaskbarEnabled,
    bool? nativeTaskbarHideEnabled,
    bool? nativeTaskbarVisibilityBeforeActivation,
    String? activeTemplateId,
    String? activeMonitorId,
    String? taskbarPosition,
    bool? autoHideEnabled,
    bool? recoveryEnabled,
    DateTime? lastSuccessfulActivation,
    DateTime? lastSuccessfulRestoration,
    bool? recoveryPending,
    int? configurationVersion,
  }) {
    return TaskbarSettings(
      desktopTaskbarMode: desktopTaskbarMode ?? this.desktopTaskbarMode,
      customTaskbarEnabled: customTaskbarEnabled ?? this.customTaskbarEnabled,
      nativeTaskbarHideEnabled:
          nativeTaskbarHideEnabled ?? this.nativeTaskbarHideEnabled,
      nativeTaskbarVisibilityBeforeActivation:
          nativeTaskbarVisibilityBeforeActivation ??
              this.nativeTaskbarVisibilityBeforeActivation,
      activeTemplateId: activeTemplateId ?? this.activeTemplateId,
      activeMonitorId: activeMonitorId ?? this.activeMonitorId,
      taskbarPosition: taskbarPosition ?? this.taskbarPosition,
      autoHideEnabled: autoHideEnabled ?? this.autoHideEnabled,
      recoveryEnabled: recoveryEnabled ?? this.recoveryEnabled,
      lastSuccessfulActivation:
          lastSuccessfulActivation ?? this.lastSuccessfulActivation,
      lastSuccessfulRestoration:
          lastSuccessfulRestoration ?? this.lastSuccessfulRestoration,
      recoveryPending: recoveryPending ?? this.recoveryPending,
      configurationVersion: configurationVersion ?? this.configurationVersion,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'desktopTaskbarMode': desktopTaskbarMode.name,
      'customTaskbarEnabled': customTaskbarEnabled,
      'nativeTaskbarHideEnabled': nativeTaskbarHideEnabled,
      'nativeTaskbarVisibilityBeforeActivation':
          nativeTaskbarVisibilityBeforeActivation,
      'activeTemplateId': activeTemplateId,
      'activeMonitorId': activeMonitorId,
      'taskbarPosition': taskbarPosition,
      'autoHideEnabled': autoHideEnabled,
      'recoveryEnabled': recoveryEnabled,
      'lastSuccessfulActivation':
          lastSuccessfulActivation?.toIso8601String(),
      'lastSuccessfulRestoration':
          lastSuccessfulRestoration?.toIso8601String(),
      'recoveryPending': recoveryPending,
      'configurationVersion': configurationVersion,
    };
  }

  factory TaskbarSettings.fromJson(Map<String, dynamic> json) {
    DesktopTaskbarMode mode = DesktopTaskbarMode.windowsTaskbar;
    final modeStr = json['desktopTaskbarMode'] as String?;
    if (modeStr != null) {
      for (final m in DesktopTaskbarMode.values) {
        if (m.name == modeStr) {
          mode = m;
          break;
        }
      }
    }

    DateTime? lastActivation;
    if (json['lastSuccessfulActivation'] != null) {
      lastActivation = DateTime.tryParse(json['lastSuccessfulActivation'] as String);
    }

    DateTime? lastRestoration;
    if (json['lastSuccessfulRestoration'] != null) {
      lastRestoration = DateTime.tryParse(json['lastSuccessfulRestoration'] as String);
    }

    return TaskbarSettings(
      desktopTaskbarMode: mode,
      customTaskbarEnabled: json['customTaskbarEnabled'] as bool? ?? false,
      nativeTaskbarHideEnabled:
          json['nativeTaskbarHideEnabled'] as bool? ?? false,
      nativeTaskbarVisibilityBeforeActivation:
          json['nativeTaskbarVisibilityBeforeActivation'] as bool? ?? true,
      activeTemplateId:
          json['activeTemplateId'] as String? ?? 'centered_dock',
      activeMonitorId: json['activeMonitorId'] as String?,
      taskbarPosition: json['taskbarPosition'] as String? ?? 'bottom',
      autoHideEnabled: json['autoHideEnabled'] as bool? ?? false,
      recoveryEnabled: json['recoveryEnabled'] as bool? ?? true,
      lastSuccessfulActivation: lastActivation,
      lastSuccessfulRestoration: lastRestoration,
      recoveryPending: json['recoveryPending'] as bool? ?? false,
      configurationVersion: json['configurationVersion'] as int? ?? 1,
    );
  }

  String toRawJson() => jsonEncode(toJson());

  factory TaskbarSettings.fromRawJson(String raw) =>
      TaskbarSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

