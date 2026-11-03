import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/models/system_tray_state.dart';
import 'package:wall_sync/models/taskbar_settings.dart';
import 'package:wall_sync/services/diagnostics_service.dart';
import 'package:wall_sync/services/overlay_lifecycle_service.dart';
import 'package:wall_sync/services/settings_service.dart';

void main() {
  group('SystemTrayState & Window Accessibility Tests', () {
    test(
      'SystemTrayState transitions and state predicates operate correctly',
      () {
        expect(SystemTrayState.uninitialized.isReady, isFalse);
        expect(SystemTrayState.uninitialized.isUnavailableOrFailed, isFalse);

        expect(SystemTrayState.initializing.isReady, isFalse);
        expect(SystemTrayState.initializing.isUnavailableOrFailed, isFalse);

        expect(SystemTrayState.ready.isReady, isTrue);
        expect(SystemTrayState.ready.isUnavailableOrFailed, isFalse);

        expect(SystemTrayState.unavailable.isReady, isFalse);
        expect(SystemTrayState.unavailable.isUnavailableOrFailed, isTrue);
        expect(SystemTrayState.unavailable.isRetryable, isTrue);

        expect(SystemTrayState.failed.isReady, isFalse);
        expect(SystemTrayState.failed.isUnavailableOrFailed, isTrue);
        expect(SystemTrayState.failed.isRetryable, isTrue);
      },
    );

    test(
      'WidgetSettings includes closeToTray and minimizeToTray with true defaults',
      () {
        final defaultSettings = WidgetSettings();
        expect(defaultSettings.closeToTray, isTrue);
        expect(defaultSettings.minimizeToTray, isTrue);

        final modified = defaultSettings.copyWith(
          closeToTray: false,
          minimizeToTray: false,
        );
        expect(modified.closeToTray, isFalse);
        expect(modified.minimizeToTray, isFalse);

        final json = modified.toJson();
        expect(json['closeToTray'], isFalse);
        expect(json['minimizeToTray'], isFalse);

        final deserialized = WidgetSettings.fromJson(json);
        expect(deserialized.closeToTray, isFalse);
        expect(deserialized.minimizeToTray, isFalse);
      },
    );
  });

  group('WidgetProcessLifecycleState & Readiness Verification Tests', () {
    test('WidgetProcessLifecycleState states and isRunning predicate', () {
      expect(WidgetProcessLifecycleState.spawnRequested.isRunning, isFalse);
      expect(WidgetProcessLifecycleState.spawned.isRunning, isTrue);
      expect(WidgetProcessLifecycleState.processAlive.isRunning, isTrue);
      expect(WidgetProcessLifecycleState.runtimeInitializing.isRunning, isTrue);
      expect(WidgetProcessLifecycleState.pidFileReady.isRunning, isTrue);
      expect(WidgetProcessLifecycleState.windowCreating.isRunning, isTrue);
      expect(WidgetProcessLifecycleState.windowReady.isRunning, isTrue);
      expect(WidgetProcessLifecycleState.ipcConnecting.isRunning, isTrue);
      expect(WidgetProcessLifecycleState.ipcReady.isRunning, isTrue);
      expect(WidgetProcessLifecycleState.ready.isRunning, isTrue);
      expect(WidgetProcessLifecycleState.failed.isRunning, isFalse);
      expect(WidgetProcessLifecycleState.exited.isRunning, isFalse);
      expect(WidgetProcessLifecycleState.values.length, equals(12));
    });

    test(
      'waitForOverlayReadiness does NOT report processNotStarted when expectedPid is running',
      () async {
        // Mock process inspection where PID 22116 is alive
        const inspection = OverlayProcessInspection(
          isRunning: true,
          creationTime: 123456789,
          executablePath: 'C:\\WallSync\\WallSync.exe',
        );

        final result = await waitForOverlayReadiness(
          readRecord: () async => null, // child hasn't written record yet
          inspectProcess: (pid) async => inspection,
          expectedPid: 22116,
          timeout: const Duration(milliseconds: 300),
          pollInterval: const Duration(milliseconds: 50),
        );

        // Status should be timeout, but stage must NEVER be processNotStarted!
        expect(result.status, equals(OverlayReadinessStatus.timeout));
        expect(result.stage, equals(OverlayReadinessStage.processRunning));
        expect(
          result.stage,
          isNot(equals(OverlayReadinessStage.processNotStarted)),
        );
      },
    );

    test(
      'waitForOverlayReadiness immediately reports processExited when expectedPid terminates early',
      () async {
        // Mock process inspection where PID 22116 has exited
        const deadInspection = OverlayProcessInspection(
          isRunning: false,
          creationTime: 123456789,
          executablePath: 'C:\\WallSync\\WallSync.exe',
        );

        final sw = Stopwatch()..start();
        final result = await waitForOverlayReadiness(
          readRecord: () async => null,
          inspectProcess: (pid) async => deadInspection,
          expectedPid: 22116,
          timeout: const Duration(seconds: 10), // Should NOT wait 10 seconds!
          pollInterval: const Duration(milliseconds: 50),
        );

        expect(sw.elapsedMilliseconds, lessThan(1000));
        expect(result.status, equals(OverlayReadinessStatus.processExited));
        expect(result.stage, equals(OverlayReadinessStage.failed));
      },
    );
  });

  group('Structured Diagnostic Events Tests', () {
    test(
      'recordWindowEvent records structured MainWindow history and logs',
      () {
        final diag = DiagnosticsService.instance;
        diag.clearHistoryEntries();

        diag.recordWindowEvent(
          'hidden',
          reason: 'close_to_tray',
          details: {'canHideToTray': true},
        );

        final entries = diag.getHistoryEntries(category: 'MainWindow');
        expect(entries.length, equals(1));
        expect(entries.first.category, equals('MainWindow'));
        expect(entries.first.message, contains('event=hidden'));
        expect(entries.first.message, contains('reason=close_to_tray'));
        expect(entries.first.message, contains('canHideToTray: true'));
      },
    );

    test('recordTrayEvent records structured SystemTray history and logs', () {
      final diag = DiagnosticsService.instance;
      diag.clearHistoryEntries();

      diag.recordTrayEvent(
        'native_resolution_failed',
        stage: 'unavailable',
        error: "Couldn't resolve native function 'native_image_from_file'",
      );

      final entries = diag.getHistoryEntries(category: 'SystemTray');
      expect(entries.length, equals(1));
      expect(entries.first.category, equals('SystemTray'));
      expect(entries.first.severity, equals('WARN'));
      expect(entries.first.message, contains('native_resolution_failed'));
      expect(entries.first.message, contains('stage=unavailable'));
      expect(entries.first.message, contains("native_image_from_file"));
    });

    test(
      'recordWidgetLifecycleEvent records structured WidgetLifecycle history and logs',
      () {
        final diag = DiagnosticsService.instance;
        diag.clearHistoryEntries();

        diag.recordWidgetLifecycleEvent(
          'cyber_hud',
          'spawned',
          pid: 22116,
          executable: 'C:\\WallSync\\WallSync.exe',
          args: ['--overlay', '--instance-id=cyber_hud'],
          workingDirectory: 'C:\\WallSync',
          pidFilePath: 'C:\\WallSync\\overlay.pid',
          pidFileCreated: true,
          ipcStatus: 'connected',
        );

        final entries = diag.getHistoryEntries(category: 'WidgetLifecycle');
        expect(entries.length, equals(1));
        expect(entries.first.category, equals('WidgetLifecycle'));
        expect(entries.first.severity, equals('INFO'));
        expect(entries.first.message, contains('widget="cyber_hud"'));
        expect(entries.first.message, contains('stage=spawned'));
        expect(entries.first.message, contains('pid=22116'));
        expect(entries.first.message, contains('workDir="C:\\WallSync"'));
        expect(
          entries.first.message,
          contains('pidFile="C:\\WallSync\\overlay.pid"'),
        );
        expect(entries.first.message, contains('pidCreated=true'));
        expect(entries.first.message, contains('ipcStatus=connected'));
      },
    );
  });
}
