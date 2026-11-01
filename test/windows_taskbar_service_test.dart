import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/models/taskbar_settings.dart';
import 'package:wall_sync/services/settings_service.dart';
import 'package:wall_sync/services/windows_taskbar_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TaskbarSettings Model Tests', () {
    test('Default values are secure and standard', () {
      final settings = TaskbarSettings.defaults();
      expect(settings.desktopTaskbarMode, DesktopTaskbarMode.windowsTaskbar);
      expect(settings.customTaskbarEnabled, false);
      expect(settings.nativeTaskbarHideEnabled, false);
      expect(settings.recoveryPending, false);
      expect(settings.activeTemplateId, 'centered_dock');
      expect(settings.configurationVersion, 1);
    });

    test('JSON serialization & deserialization roundtrip', () {
      final original = TaskbarSettings(
        desktopTaskbarMode: DesktopTaskbarMode.dockWithNativeHidden,
        customTaskbarEnabled: true,
        nativeTaskbarHideEnabled: true,
        nativeTaskbarVisibilityBeforeActivation: true,
        activeTemplateId: 'minimal_floating',
        activeMonitorId: 'DISPLAY1',
        taskbarPosition: 'bottom',
        autoHideEnabled: true,
        recoveryEnabled: true,
        lastSuccessfulActivation: DateTime(2026, 11, 1, 12, 0, 0),
        lastSuccessfulRestoration: DateTime(2026, 11, 1, 12, 5, 0),
        recoveryPending: false,
        configurationVersion: 2,
      );

      final json = original.toJson();
      final restored = TaskbarSettings.fromJson(json);

      expect(restored.desktopTaskbarMode, DesktopTaskbarMode.dockWithNativeHidden);
      expect(restored.customTaskbarEnabled, true);
      expect(restored.nativeTaskbarHideEnabled, true);
      expect(restored.activeTemplateId, 'minimal_floating');
      expect(restored.activeMonitorId, 'DISPLAY1');
      expect(restored.taskbarPosition, 'bottom');
      expect(restored.autoHideEnabled, true);
      expect(restored.recoveryEnabled, true);
      expect(restored.lastSuccessfulActivation, DateTime(2026, 11, 1, 12, 0, 0));
      expect(restored.lastSuccessfulRestoration, DateTime(2026, 11, 1, 12, 5, 0));
      expect(restored.recoveryPending, false);
      expect(restored.configurationVersion, 2);
    });

    test('copyWith properly overrides values while preserving others', () {
      final original = TaskbarSettings.defaults();
      final updated = original.copyWith(
        customTaskbarEnabled: true,
        nativeTaskbarHideEnabled: true,
        desktopTaskbarMode: DesktopTaskbarMode.dockWithNativeHidden,
      );

      expect(updated.customTaskbarEnabled, true);
      expect(updated.nativeTaskbarHideEnabled, true);
      expect(updated.desktopTaskbarMode, DesktopTaskbarMode.dockWithNativeHidden);
      expect(updated.activeTemplateId, original.activeTemplateId);
      expect(updated.configurationVersion, original.configurationVersion);
    });

    test('fromJson gracefully falls back for unknown/null values', () {
      final empty = TaskbarSettings.fromJson({});
      expect(empty.desktopTaskbarMode, DesktopTaskbarMode.windowsTaskbar);
      expect(empty.customTaskbarEnabled, false);
      expect(empty.nativeTaskbarHideEnabled, false);
      expect(empty.activeTemplateId, 'centered_dock');
    });
  });

  group('TaskbarReplacementState Display and Flags Tests', () {
    test('State display names and predicates are accurate', () {
      expect(
        TaskbarReplacementState.disabled.displayName,
        'Custom Taskbar Disabled',
      );
      expect(
        TaskbarReplacementState.windowsTaskbarActive.displayName,
        'Windows Taskbar Active',
      );
      expect(
        TaskbarReplacementState.preparing.displayName,
        'WallSync Taskbar Preparing',
      );
      expect(
        TaskbarReplacementState.nativeTaskbarDetected.displayName,
        'Native Taskbar Detected',
      );
      expect(
        TaskbarReplacementState.customTaskbarCreating.displayName,
        'Custom Taskbar Creating',
      );
      expect(
        TaskbarReplacementState.customTaskbarReady.displayName,
        'Custom Taskbar Ready',
      );
      expect(
        TaskbarReplacementState.starting.displayName,
        'WallSync Taskbar Starting',
      );
      expect(
        TaskbarReplacementState.wallSyncTaskbarActive.displayName,
        'WallSync Taskbar Active',
      );
      expect(
        TaskbarReplacementState.nativeTaskbarHidePending.displayName,
        'Native Hide Pending',
      );
      expect(
        TaskbarReplacementState.windowsTaskbarHidden.displayName,
        'Windows Taskbar Hidden',
      );
      expect(
        TaskbarReplacementState.restoring.displayName,
        'Restoration in Progress',
      );
      expect(
        TaskbarReplacementState.restoredSuccessfully.displayName,
        'Restored Successfully',
      );
      expect(
        TaskbarReplacementState.failedToActivate.displayName,
        'Failed to Activate',
      );
      expect(
        TaskbarReplacementState.failedToRestore.displayName,
        'Failed to Restore',
      );
      expect(
        TaskbarReplacementState.recoveryRequired.displayName,
        'Recovery Required',
      );

      expect(TaskbarReplacementState.windowsTaskbarActive.isHealthy, true);
      expect(TaskbarReplacementState.wallSyncTaskbarActive.isHealthy, true);
      expect(TaskbarReplacementState.windowsTaskbarHidden.isHealthy, true);
      expect(TaskbarReplacementState.restoredSuccessfully.isHealthy, true);
      expect(TaskbarReplacementState.customTaskbarReady.isHealthy, true);

      expect(TaskbarReplacementState.preparing.isProcessing, true);
      expect(TaskbarReplacementState.starting.isProcessing, true);
      expect(TaskbarReplacementState.nativeTaskbarDetected.isProcessing, true);
      expect(TaskbarReplacementState.customTaskbarCreating.isProcessing, true);
      expect(TaskbarReplacementState.nativeTaskbarHidePending.isProcessing, true);
      expect(TaskbarReplacementState.restoring.isProcessing, true);

      expect(TaskbarReplacementState.failedToActivate.isError, true);
      expect(TaskbarReplacementState.failedToRestore.isError, true);
      expect(TaskbarReplacementState.recoveryRequired.isError, true);
    });
  });

  group('WindowsTaskbarService Tests', () {
    const channelName = 'wallsync/live_wallpaper';
    final List<MethodCall> methodCalls = [];
    bool mockTaskbarVisible = true;
    bool shouldFailHide = false;

    setUp(() {
      methodCalls.clear();
      mockTaskbarVisible = true;
      shouldFailHide = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), (call) async {
        methodCalls.add(call);
        switch (call.method) {
          case 'getWindowsTaskbarInfo':
            return {
              'primaryPresent': true,
              'primaryVisible': mockTaskbarVisible,
              'secondaryCount': 0,
              'secondaryVisibleCount': 0,
              'allVisible': mockTaskbarVisible,
              'anyVisible': mockTaskbarVisible,
            };
          case 'setWindowsTaskbarVisibility':
            if (shouldFailHide) return false;
            final visible = (call.arguments as Map)['visible'] as bool;
            mockTaskbarVisible = visible;
            return true;
          case 'restoreWindowsTaskbar':
            mockTaskbarVisible = true;
            return true;
          default:
            return null;
        }
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), null);
    });

    test('Service initializes cleanly with standard Windows taskbar active', () async {
      final service = WindowsTaskbarService();
      await service.init();
      expect(service.state, TaskbarReplacementState.windowsTaskbarActive);
      expect(service.isCustomTaskbarActive, false);
      expect(service.isWindowsTaskbarHidden, false);
    });

    test('Transactional custom taskbar activation without hiding native taskbar', () async {
      final service = WindowsTaskbarService();
      await service.init();

      final success = await service.enableCustomTaskbar(hideNativeTaskbar: false);
      expect(success, true);
      expect(service.state, TaskbarReplacementState.wallSyncTaskbarActive);
      expect(service.isCustomTaskbarActive, true);
      expect(service.isWindowsTaskbarHidden, false);
      expect(mockTaskbarVisible, true);
    });

    test('Transactional custom taskbar activation WITH hiding native taskbar', () async {
      final service = WindowsTaskbarService();
      await service.init();

      final success = await service.enableCustomTaskbar(hideNativeTaskbar: true);
      expect(success, true);
      expect(service.state, TaskbarReplacementState.windowsTaskbarHidden);
      expect(service.isCustomTaskbarActive, true);
      expect(service.isWindowsTaskbarHidden, true);
      expect(mockTaskbarVisible, false);
    });

    test('Restoration restores native Windows taskbar and updates state', () async {
      final service = WindowsTaskbarService();
      await service.init();
      await service.enableCustomTaskbar(hideNativeTaskbar: true);

      final restored = await service.restoreWindowsTaskbar();
      expect(restored, true);
      expect(mockTaskbarVisible, true);
      expect(service.isWindowsTaskbarHidden, false);
      expect(service.state == TaskbarReplacementState.restoredSuccessfully ||
          service.state == TaskbarReplacementState.windowsTaskbarActive, true);
    });

    test('Safe rollback when hiding native taskbar fails', () async {
      shouldFailHide = true;
      final service = WindowsTaskbarService();
      await service.init();

      final success = await service.enableCustomTaskbar(hideNativeTaskbar: true);
      expect(success, false);
      expect(service.state, TaskbarReplacementState.failedToActivate);
      expect(mockTaskbarVisible, true);
    });

    test('Option A: Reset Appearance resets colors to safe defaults', () async {
      final service = WindowsTaskbarService();
      await service.init();

      await service.resetAppearance();
      final settings = SettingsService().settings;
      expect(settings.taskbarBgColor, 0xDD16181F);
      expect(settings.taskbarAccentColor, 0xFF38BDF8);
      expect(settings.taskbarTextColor, 0xFFFFFFFF);
    });

    test('Option B: Reset Layout resets dock position and modules', () async {
      final service = WindowsTaskbarService();
      await service.init();

      await service.resetLayout();
      final settings = SettingsService().settings;
      expect(settings.taskbarSettings.taskbarPosition, 'bottom');
      expect(settings.taskbarSettings.autoHideEnabled, false);
      expect(settings.width, 640.0);
      expect(settings.height, 48.0);
    });

    test('Option C: Full Taskbar Reset restores taskbar and resets defaults', () async {
      final service = WindowsTaskbarService();
      await service.init();
      await service.enableCustomTaskbar(hideNativeTaskbar: true);

      await service.resetFullTaskbar();
      expect(mockTaskbarVisible, true);
      expect(service.state, TaskbarReplacementState.windowsTaskbarActive);
      expect(service.isCustomTaskbarActive, false);
    });

    test('Custom taskbar dock spawner and closer lifecycle verification', () async {
      final service = WindowsTaskbarService();
      bool spawnerCalled = false;
      bool closerCalled = false;

      service.setDependencies(
        taskbarSpawner: () async {
          spawnerCalled = true;
          return true;
        },
        taskbarCloser: () async {
          closerCalled = true;
        },
      );

      await service.init();
      final activated = await service.enableCustomTaskbar(hideNativeTaskbar: true);
      expect(activated, true);
      expect(spawnerCalled, true);
      expect(service.isCustomTaskbarActive, true);

      final restored = await service.restoreWindowsTaskbar();
      expect(restored, true);
      expect(closerCalled, true);
      expect(service.isCustomTaskbarActive, false);
    });

    test('syncDockSettings updates dock instance settings file', () async {
      final service = WindowsTaskbarService();
      await service.init();

      final currentSettings = SettingsService().settings.copyWith(
        taskbarAccentColor: 0xFFFF5722,
        taskbarBgColor: 0xEE101015,
        taskbarShowCpu: false,
        taskbarShowWeather: true,
      );

      await service.syncDockSettings(currentSettings);
      final dockSettings = await SettingsService(instanceId: 'taskbar_dock').loadSettings();

      expect(dockSettings.taskbarAccentColor, 0xFFFF5722);
      expect(dockSettings.taskbarBgColor, 0xEE101015);
      expect(dockSettings.taskbarShowCpu, false);
      expect(dockSettings.taskbarShowWeather, true);
      expect(dockSettings.widgetTemplate, 'taskbar_dock');
    });
  });
}
