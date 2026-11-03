import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/models/taskbar_settings.dart';
import 'package:wall_sync/services/overlay_lifecycle_service.dart';
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

      expect(
        restored.desktopTaskbarMode,
        DesktopTaskbarMode.dockWithNativeHidden,
      );
      expect(restored.customTaskbarEnabled, true);
      expect(restored.nativeTaskbarHideEnabled, true);
      expect(restored.activeTemplateId, 'minimal_floating');
      expect(restored.activeMonitorId, 'DISPLAY1');
      expect(restored.taskbarPosition, 'bottom');
      expect(restored.autoHideEnabled, true);
      expect(restored.recoveryEnabled, true);
      expect(
        restored.lastSuccessfulActivation,
        DateTime(2026, 11, 1, 12, 0, 0),
      );
      expect(
        restored.lastSuccessfulRestoration,
        DateTime(2026, 11, 1, 12, 5, 0),
      );
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
      expect(
        updated.desktopTaskbarMode,
        DesktopTaskbarMode.dockWithNativeHidden,
      );
      expect(updated.activeTemplateId, original.activeTemplateId);
      expect(updated.configurationVersion, original.configurationVersion);
    });

    test('resolved mode normalizes dock replacement aliases', () {
      final replacement = TaskbarSettings(
        desktopTaskbarMode: DesktopTaskbarMode.dockWithNativeHidden,
        customTaskbarEnabled: true,
        nativeTaskbarHideEnabled: true,
      );
      expect(
        replacement.resolvedDesktopTaskbarMode,
        DesktopTaskbarMode.customTaskbar,
      );

      final alongside = TaskbarSettings(
        desktopTaskbarMode: DesktopTaskbarMode.dockOnly,
        customTaskbarEnabled: true,
        nativeTaskbarHideEnabled: false,
      );
      expect(alongside.resolvedDesktopTaskbarMode, DesktopTaskbarMode.dockOnly);
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
      expect(
        TaskbarReplacementState.nativeTaskbarHidePending.isProcessing,
        true,
      );
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
    bool shouldFailPositionDock = false;
    int secondaryVisibleCount = 0;

    setUp(() {
      methodCalls.clear();
      mockTaskbarVisible = true;
      shouldFailHide = false;
      shouldFailPositionDock = false;
      secondaryVisibleCount = 0;
      WindowsTaskbarService.instance.setDependencies(isTest: true);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(channelName), (
            call,
          ) async {
            methodCalls.add(call);
            switch (call.method) {
              case 'getWindowsTaskbarInfo':
                return {
                  'primaryPresent': true,
                  'primaryVisible': mockTaskbarVisible,
                  'secondaryCount': 0,
                  'secondaryVisibleCount': secondaryVisibleCount,
                  'allVisible': mockTaskbarVisible,
                  'anyVisible': mockTaskbarVisible,
                };
              case 'positionDockForReplacement':
                if (shouldFailPositionDock) {
                  return {'success': false, 'error': 'position failed'};
                }
                return {
                  'success': true,
                  'hwnd': (call.arguments as Map)['hwnd'],
                  'ownerPid': (call.arguments as Map)['pid'],
                  'targetRect': {
                    'left': 0,
                    'top': 1030,
                    'right': 1920,
                    'bottom': 1080,
                    'width': 1920,
                    'height': 50,
                  },
                };
              case 'runTaskbarCommand':
                return true;
              case 'setWindowsTaskbarVisibility':
                if (shouldFailHide) return false;
                final visible = (call.arguments as Map)['visible'] as bool;
                mockTaskbarVisible = visible;
                return true;
              case 'restoreWindowsTaskbar':
                mockTaskbarVisible = true;
                return true;
              case 'getDesktopWindows':
                return [
                  {
                    'hwnd': 1234,
                    'pid': 5678,
                    'title': 'Editor',
                    'executable': r'C:\Program Files\Editor\editor.exe',
                    'isForeground': true,
                  },
                ];
              case 'activateDesktopWindow':
              case 'launchDockItem':
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

    test(
      'Service initializes cleanly with standard Windows taskbar active',
      () async {
        final service = WindowsTaskbarService();
        await service.init();
        expect(service.state, TaskbarReplacementState.windowsTaskbarActive);
        expect(service.isCustomTaskbarActive, false);
        expect(service.isWindowsTaskbarHidden, false);
      },
    );

    test(
      'Transactional custom taskbar activation without hiding native taskbar',
      () async {
        final service = WindowsTaskbarService();
        await service.init();

        final success = await service.enableCustomTaskbar(
          hideNativeTaskbar: false,
        );
        expect(success, true);
        expect(service.state, TaskbarReplacementState.wallSyncTaskbarActive);
        expect(service.isCustomTaskbarActive, true);
        expect(service.isWindowsTaskbarHidden, false);
        expect(mockTaskbarVisible, true);
      },
    );

    test(
      'Transactional custom taskbar activation WITH hiding native taskbar',
      () async {
        final service = WindowsTaskbarService();
        await service.init();

        final success = await service.enableCustomTaskbar(
          hideNativeTaskbar: true,
        );
        expect(success, true);
        expect(service.state, TaskbarReplacementState.windowsTaskbarHidden);
        expect(service.isCustomTaskbarActive, true);
        expect(service.isWindowsTaskbarHidden, true);
        expect(mockTaskbarVisible, false);
        final positionIndex = methodCalls.indexWhere(
          (call) => call.method == 'positionDockForReplacement',
        );
        final hideIndex = methodCalls.indexWhere(
          (call) =>
              call.method == 'setWindowsTaskbarVisibility' &&
              (call.arguments as Map)['visible'] == false,
        );
        expect(positionIndex, greaterThanOrEqualTo(0));
        expect(hideIndex, greaterThan(positionIndex));
        final dockSettings = await SettingsService(
          instanceId: 'taskbar_dock',
        ).loadSettings();
        expect(dockSettings.taskbarSettings.customTaskbarEnabled, true);
        expect(dockSettings.taskbarSettings.nativeTaskbarHideEnabled, true);
      },
    );

    test(
      'Restoration restores native Windows taskbar and updates state',
      () async {
        final service = WindowsTaskbarService();
        await service.init();
        await service.enableCustomTaskbar(hideNativeTaskbar: true);

        final restored = await service.restoreWindowsTaskbar();
        expect(restored, true);
        expect(mockTaskbarVisible, true);
        expect(service.isWindowsTaskbarHidden, false);
        expect(
          service.state == TaskbarReplacementState.restoredSuccessfully ||
              service.state == TaskbarReplacementState.windowsTaskbarActive,
          true,
        );
      },
    );

    test('Safe rollback when hiding native taskbar fails', () async {
      shouldFailHide = true;
      final service = WindowsTaskbarService();
      await service.init();

      final success = await service.enableCustomTaskbar(
        hideNativeTaskbar: true,
      );
      expect(success, false);
      expect(service.state, TaskbarReplacementState.failedToActivate);
      expect(mockTaskbarVisible, true);
    });

    test(
      'Replacement alignment failure leaves native taskbar visible',
      () async {
        shouldFailPositionDock = true;
        final service = WindowsTaskbarService();
        await service.init();

        final success = await service.enableCustomTaskbar(
          hideNativeTaskbar: true,
        );

        expect(success, false);
        expect(mockTaskbarVisible, true);
        expect(
          methodCalls.any(
            (call) =>
                call.method == 'setWindowsTaskbarVisibility' &&
                (call.arguments as Map)['visible'] == false,
          ),
          false,
        );
      },
    );

    test('Replacement refuses to hide additional monitor taskbars', () async {
      secondaryVisibleCount = 1;
      final service = WindowsTaskbarService();
      await service.init();

      final success = await service.enableCustomTaskbar(
        hideNativeTaskbar: true,
      );

      expect(success, false);
      expect(mockTaskbarVisible, true);
      expect(
        methodCalls.any((call) => call.method == 'positionDockForReplacement'),
        false,
      );
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

    test(
      'Option C: Full Taskbar Reset restores taskbar and resets defaults',
      () async {
        final service = WindowsTaskbarService();
        await service.init();
        await service.enableCustomTaskbar(hideNativeTaskbar: true);

        await service.resetFullTaskbar();
        expect(mockTaskbarVisible, true);
        expect(service.state, TaskbarReplacementState.windowsTaskbarActive);
        expect(service.isCustomTaskbarActive, false);
      },
    );

    test(
      'Custom taskbar dock spawner and closer lifecycle verification',
      () async {
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
        final activated = await service.enableCustomTaskbar(
          hideNativeTaskbar: true,
        );
        expect(activated, true);
        expect(spawnerCalled, true);
        expect(service.isCustomTaskbarActive, true);

        final restored = await service.restoreWindowsTaskbar();
        expect(restored, true);
        expect(closerCalled, true);
        expect(service.isCustomTaskbarActive, false);
      },
    );

    test('syncDockSettings updates dock instance settings file', () async {
      final service = WindowsTaskbarService();
      await service.init();

      final currentSettings = SettingsService().settings.copyWith(
        taskbarAccentColor: 0xFFFF5722,
        taskbarBgColor: 0xEE101015,
        taskbarShowCpu: false,
        taskbarShowWeather: true,
      );

      await service.syncDockSettings(settings: currentSettings);
      final dockSettings = await SettingsService(
        instanceId: 'taskbar_dock',
      ).loadSettings();

      expect(dockSettings.taskbarAccentColor, 0xFFFF5722);
      expect(dockSettings.taskbarBgColor, 0xEE101015);
      expect(dockSettings.taskbarShowCpu, false);
      expect(dockSettings.taskbarShowWeather, true);
      expect(dockSettings.widgetTemplate, 'taskbar_dock');
      expect(dockSettings.taskbarSettings.customTaskbarEnabled, false);
      expect(dockSettings.taskbarSettings.nativeTaskbarHideEnabled, false);
    });

    test(
      'Dock spawner failure triggers rollback and does NOT report success',
      () async {
        final service = WindowsTaskbarService();
        service.setDependencies(
          taskbarSpawner: () async => false, // simulates dock spawn failure
        );
        await service.init();

        final success = await service.enableCustomTaskbar(
          hideNativeTaskbar: true,
        );
        expect(success, false);
        expect(service.state, TaskbarReplacementState.failedToActivate);
        expect(service.isCustomTaskbarActive, false);
        expect(mockTaskbarVisible, true);
      },
    );

    test('Operation ID cancellation supersedes stale activation', () async {
      final service = WindowsTaskbarService();

      service.setDependencies(
        taskbarSpawner: () async {
          // Simulate slow spawner
          await Future.delayed(const Duration(milliseconds: 50));
          return true;
        },
      );
      await service.init();

      // Launch first activation
      final future1 = service.enableCustomTaskbar(hideNativeTaskbar: true);
      // Immediately restore (or cancel) which increments operation ID
      await service.restoreWindowsTaskbar();

      final result1 = await future1;
      expect(
        result1,
        false,
      ); // Must return false, cannot report false activation success!
      expect(
        service.state,
        isNot(TaskbarReplacementState.wallSyncTaskbarActive),
      );
      expect(
        service.state,
        isNot(TaskbarReplacementState.windowsTaskbarHidden),
      );
      expect(mockTaskbarVisible, true);
    });

    test('verifyDockWindow returns structured Win32 properties', () async {
      final service = WindowsTaskbarService();
      await service.init();

      final verification = await service.verifyDockWindow(9999);
      expect(verification['found'], true);
      expect(verification['hwnd'], 123456);
      expect(verification['pidMatches'], true);
      expect(verification['isVisible'], true);
      expect(verification['onMonitor'], true);
      expect(verification['rect']['width'], 1920);
    });

    test('dock lists and activates native Windows app windows', () async {
      final service = WindowsTaskbarService();
      await service.init();

      final windows = await service.getDesktopWindows();
      expect(windows, hasLength(1));
      expect(windows.single.handle, 1234);
      expect(windows.single.processId, 5678);
      expect(windows.single.title, 'Editor');
      expect(windows.single.executable, r'C:\Program Files\Editor\editor.exe');
      expect(windows.single.isForeground, true);

      expect(await service.activateDesktopWindow(1234), true);
      expect(methodCalls.last.method, 'activateDesktopWindow');
      expect((methodCalls.last.arguments as Map)['hwnd'], 1234);
    });

    test(
      'dock launches configured app, file, and URL targets natively',
      () async {
        final service = WindowsTaskbarService();
        await service.init();

        expect(await service.launchDockItem('wt'), true);
        expect(methodCalls.last.method, 'launchDockItem');
        expect((methodCalls.last.arguments as Map)['target'], 'wt');

        expect(await service.launchDockItem('  '), false);
      },
    );

    test('replacement taskbar actions route to the native runner', () async {
      final service = WindowsTaskbarService();
      await service.init();

      expect(await service.runTaskbarCommand('search'), true);
      expect(methodCalls.last.method, 'runTaskbarCommand');
      expect((methodCalls.last.arguments as Map)['command'], 'search');
    });
  });

  group('DockReadinessStage & OverlayProcessRecord Tests', () {
    test('12 DockReadinessStages have valid display names and predicates', () {
      expect(DockReadinessStage.values.length, 12);
      expect(
        DockReadinessStage.processNotStarted.displayName,
        'Process Not Started',
      );
      expect(
        DockReadinessStage.processStarting.displayName,
        'Process Starting',
      );
      expect(DockReadinessStage.processRunning.displayName, 'Process Running');
      expect(
        DockReadinessStage.windowNotCreated.displayName,
        'Window Not Created',
      );
      expect(DockReadinessStage.windowFound.displayName, 'Window Found');
      expect(DockReadinessStage.windowVerified.displayName, 'Window Verified');
      expect(DockReadinessStage.windowVisible.displayName, 'Window Visible');
      expect(
        DockReadinessStage.windowInteractive.displayName,
        'Window Interactive',
      );
      expect(DockReadinessStage.dockReady.displayName, 'Dock Ready');
      expect(DockReadinessStage.failed.displayName, 'Failed');
      expect(DockReadinessStage.stopping.displayName, 'Stopping');
      expect(DockReadinessStage.stopped.displayName, 'Stopped');

      expect(DockReadinessStage.dockReady.isReady, true);
      expect(DockReadinessStage.processRunning.isReady, false);
      expect(DockReadinessStage.failed.isTerminal, true);
      expect(DockReadinessStage.stopped.isTerminal, true);
      expect(DockReadinessStage.dockReady.isTerminal, false);
    });

    test('OverlayProcessRecord roundtrip with 12-stage handshake fields', () {
      final record = OverlayProcessRecord(
        pid: 14200,
        creationTime: 13350000000,
        executablePath: r'C:\WallSync\WallSync.exe',
        ready: true,
        instanceId: 'taskbar_dock',
        hwnd: 78910,
        configurationRevision: 5,
        stage: DockReadinessStage.dockReady,
        operationId: 42,
        startupTimestamp: 1730460000000,
        healthCheck: true,
      );

      final json = record.toJson();
      expect(json['pid'], 14200);
      expect(json['instanceId'], 'taskbar_dock');
      expect(json['hwnd'], 78910);
      expect(json['configurationRevision'], 5);
      expect(json['stage'], 'dockReady');
      expect(json['operationId'], 42);
      expect(json['startupTimestamp'], 1730460000000);
      expect(json['healthCheck'], true);

      final parsed = OverlayProcessRecord.tryParse(jsonEncode(json));
      expect(parsed, isNotNull);
      expect(parsed!.pid, 14200);
      expect(parsed.instanceId, 'taskbar_dock');
      expect(parsed.hwnd, 78910);
      expect(parsed.configurationRevision, 5);
      expect(parsed.stage, DockReadinessStage.dockReady);
      expect(parsed.operationId, 42);
      expect(parsed.startupTimestamp, 1730460000000);
      expect(parsed.healthCheck, true);
      expect(parsed.ready, true);
    });
  });
}
