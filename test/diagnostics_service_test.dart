import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/diagnostics_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DiagnosticsService.instance.init(enablePeriodicSampling: false);
    DiagnosticsService.instance.resetSmoothnessMetrics();
  });

  tearDown(() {
    DiagnosticsService.instance.dispose();
  });

  test('DiagnosticsService gathers valid memory snapshot', () {
    final before = DateTime.now();
    final mem = DiagnosticsService.instance.getMemorySnapshot();
    final after = DateTime.now();
    expect(mem.processRssBytes, isNonNegative);
    expect(mem.processRssMb, isNonNegative);
    expect(mem.dartHeapBytes, isNull);
    expect(mem.processId, pid);
    expect(
      mem.sampledAt.isAfter(before.subtract(const Duration(seconds: 1))),
      isTrue,
    );
    expect(
      mem.sampledAt.isBefore(after.add(const Duration(seconds: 1))),
      isTrue,
    );
    expect(mem.systemTotalPhysBytes, isNonNegative);
    expect(mem.systemMemoryLoadPercent, inInclusiveRange(0, 100));
    if (Platform.isWindows) {
      expect(mem.processRssBytes, greaterThan(0));
      expect(mem.processPrivateBytes, greaterThan(0));
      expect(mem.processRssBytes, lessThan(mem.systemTotalPhysBytes));
      expect(
        mem.processSessionPeakRssBytes,
        greaterThanOrEqualTo(mem.processRssBytes),
      );
      expect(
        mem.processSessionPeakPrivateBytes,
        greaterThanOrEqualTo(mem.processPrivateBytes!),
      );
    }
    expect(mem.toString(), contains('Process RSS'));
    expect(mem.toString(), contains('Process Lifetime Peak RSS'));
    expect(mem.toMap()['processSessionPeakRssMb'], isNotNull);
    expect(mem.samplingDurationMs, isNonNegative);
    expect(mem.toString(), contains('Main PID: $pid'));
    expect(mem.toMap()['sampledAt'], mem.sampledAt.toIso8601String());
    expect(
      mem.toMap()['processLifetimePeakRssMb'],
      mem.processMaxRssMb.toStringAsFixed(1),
    );
    expect(mem.toMap()['processId'], pid);
  });

  test('DiagnosticsService gathers valid CPU snapshot', () {
    final cpu = DiagnosticsService.instance.getCpuSnapshot();
    expect(cpu.processCpuPercent, inInclusiveRange(0.0, 100.0));
    expect(cpu.systemCpuPercent, inInclusiveRange(0.0, 100.0));
    expect(cpu.toString(), contains('Process CPU'));
  });

  test('DiagnosticsService calculates smoothness snapshot', () {
    final smooth = DiagnosticsService.instance.getSmoothnessSnapshot();
    expect(smooth.totalFrames, isNonNegative);
    expect(smooth.jankFrames, isNonNegative);
    expect(smooth.smoothnessPercentage, inInclusiveRange(0.0, 100.0));
    expect(smooth.toString(), contains('Smoothness'));
  });

  test(
    'smoothness excludes pipeline gaps but counts actual long frame work',
    () {
      final diag = DiagnosticsService.instance;
      diag.recordFrameTimingForTesting(
        build: const Duration(milliseconds: 5),
        raster: const Duration(milliseconds: 4),
        totalSpan: const Duration(milliseconds: 12),
      );
      diag.recordFrameTimingForTesting(
        build: const Duration(milliseconds: 20),
        raster: const Duration(milliseconds: 5),
        totalSpan: const Duration(milliseconds: 30),
      );
      diag.recordFrameTimingForTesting(
        build: const Duration(milliseconds: 1600),
        raster: const Duration(milliseconds: 2),
        totalSpan: const Duration(milliseconds: 1610),
      );
      diag.recordFrameTimingForTesting(
        build: const Duration(milliseconds: 4),
        raster: const Duration(milliseconds: 4),
        totalSpan: const Duration(milliseconds: 5000),
      );

      final smooth = diag.getSmoothnessSnapshot();
      expect(smooth.totalFrames, 4);
      expect(smooth.eligibleFrames, 3);
      expect(smooth.suspendedFrames, 1);
      expect(smooth.jankFrames, 2);
      expect(smooth.severeJankFrames, 1);
      expect(smooth.smoothnessPercentage, closeTo(33.333, 0.01));
      expect(smooth.averageBuildTimeMs, closeTo(541.667, 0.01));
      expect(smooth.averageRasterTimeMs, closeTo(3.667, 0.01));
      expect(smooth.recentFrameSamples, hasLength(4));
      expect(smooth.recentFrameSamples[2], contains('class=jank'));
      expect(smooth.recentFrameSamples[3], contains('class=gap'));
    },
  );

  test(
    'DiagnosticsService tracks async operations and detects durations',
    () async {
      final result = await DiagnosticsService.instance.trackAsyncOperation(
        tag: 'TestTag',
        name: 'fastOperation',
        operation: () async {
          await Future.delayed(const Duration(milliseconds: 20));
          return 42;
        },
        warningThreshold: const Duration(seconds: 1),
      );

      expect(result, 42);
      expect(DiagnosticsService.instance.activeOperationCount, 0);
    },
  );

  test(
    'DiagnosticsService generates structured plain-text diagnostic report',
    () async {
      final report = await DiagnosticsService.instance
          .generateDiagnosticReport();
      expect(report, contains('WALLSYNC RUNTIME DIAGNOSTIC REPORT'));
      expect(report, contains('1. MEMORY & RAM PROFILING'));
      expect(report, contains('Diagnostics Session Started'));
      expect(report, contains('Memory Sample Duration'));
      expect(report, contains('Session Sampled Peak'));
      expect(report, contains('2. CPU UTILIZATION'));
      expect(report, contains('3. STORAGE & DISK FOOTPRINT'));
      expect(report, contains('4. UI SMOOTHNESS & 60 FPS JANK METRICS'));
      expect(report, contains('5. RUNTIME STABILITY & HANG DETECTIONS'));
    },
  );

  test('DiagnosticsService trimWorkingSet is a safe no-op by default', () {
    // Calling trimWorkingSet without force must execute cleanly as a safe no-op
    // to prevent page-fault storms on Windows under heavy system load.
    expect(() => DiagnosticsService.instance.trimWorkingSet(), returnsNormally);
  });

  test(
    'MemorySnapshot supports commit charge, canonical aliases, and working-set trimming detection',
    () {
      final snapshot = MemorySnapshot(
        processRssBytes: 400 * 1024 * 1024,
        processMaxRssBytes: 900 * 1024 * 1024,
        processPrivateBytes: 1100 * 1024 * 1024,
        processCommitChargeBytes: 1150 * 1024 * 1024,
        processSessionPeakRssBytes: 880 * 1024 * 1024,
        processSessionPeakPrivateBytes: 1100 * 1024 * 1024,
        systemTotalPhysBytes: 16 * 1024 * 1024 * 1024,
        systemAvailPhysBytes: 250 * 1024 * 1024,
        systemMemoryLoadPercent: 96,
        processId: 12345,
        sampledAt: DateTime.now(),
      );

      expect(snapshot.processWorkingSetBytes, snapshot.processRssBytes);
      expect(snapshot.processPeakWorkingSetBytes, snapshot.processMaxRssBytes);
      expect(snapshot.processPrivateCommitBytes, snapshot.processPrivateBytes);
      expect(snapshot.processCommitChargeMb, closeTo(1150.0, 0.5));
      expect(snapshot.isSystemMemoryConstrained, isTrue);
      expect(snapshot.isWorkingSetTrimmed, isTrue);
      expect(snapshot.toString(), contains('trimmed working set'));
    },
  );

  test(
    'SmoothnessSnapshot reports both cumulative and rolling smoothness percentages',
    () {
      final diag = DiagnosticsService.instance;
      for (int i = 0; i < 5; i++) {
        diag.recordFrameTimingForTesting(
          build: const Duration(milliseconds: 4),
          raster: const Duration(milliseconds: 4),
          totalSpan: const Duration(milliseconds: 10),
        );
      }
      diag.recordFrameTimingForTesting(
        build: const Duration(milliseconds: 25),
        raster: const Duration(milliseconds: 4),
        totalSpan: const Duration(milliseconds: 30),
      );

      final snapshot = diag.getSmoothnessSnapshot();
      expect(snapshot.totalFrames, 6);
      expect(snapshot.eligibleFrames, 6);
      expect(snapshot.jankFrames, 1);
      expect(snapshot.cumulativeSmoothnessPercentage, closeTo(83.33, 0.05));
      expect(snapshot.rollingSmoothnessPercentage, closeTo(83.33, 0.05));
      expect(
        snapshot.smoothnessPercentage,
        snapshot.cumulativeSmoothnessPercentage,
      );
    },
  );
}
