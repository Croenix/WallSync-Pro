import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:win32/win32.dart';

import 'live_wallpaper_manager.dart';
import 'overlay_lifecycle_service.dart';
import 'settings_service.dart';

final class _ProcessMemoryCountersEx extends Struct {
  @DWORD()
  external int cb;
  @DWORD()
  external int pageFaultCount;
  @SIZE_T()
  external int peakWorkingSetSize;
  @SIZE_T()
  external int workingSetSize;
  @SIZE_T()
  external int quotaPeakPagedPoolUsage;
  @SIZE_T()
  external int quotaPagedPoolUsage;
  @SIZE_T()
  external int quotaPeakNonPagedPoolUsage;
  @SIZE_T()
  external int quotaNonPagedPoolUsage;
  @SIZE_T()
  external int pagefileUsage;
  @SIZE_T()
  external int peakPagefileUsage;
  @SIZE_T()
  external int privateUsage;
}

class _ProcessMemorySample {
  const _ProcessMemorySample(
    this.workingSetBytes,
    this.peakWorkingSetBytes,
    this.privateBytes, [
    this.commitChargeBytes = 0,
  ]);
  final int workingSetBytes;
  final int peakWorkingSetBytes;
  final int privateBytes;
  final int commitChargeBytes;
}

typedef _GetProcessMemoryInfoNative =
    Int32 Function(
      Pointer hProcess,
      Pointer<_ProcessMemoryCountersEx> ppsmex,
      Uint32 cb,
    );
typedef _GetProcessMemoryInfoDart =
    int Function(
      HANDLE hProcess,
      Pointer<_ProcessMemoryCountersEx> ppsmex,
      int cb,
    );

DynamicLibrary? _psapiLib;
_GetProcessMemoryInfoDart? _cachedGetProcessMemoryInfo;

_GetProcessMemoryInfoDart? _getProcessMemoryInfoFn() {
  if (_cachedGetProcessMemoryInfo != null) return _cachedGetProcessMemoryInfo;
  try {
    _psapiLib ??= DynamicLibrary.open('psapi.dll');
    _cachedGetProcessMemoryInfo = _psapiLib!
        .lookupFunction<_GetProcessMemoryInfoNative, _GetProcessMemoryInfoDart>(
          'GetProcessMemoryInfo',
        );
  } catch (_) {}
  return _cachedGetProcessMemoryInfo;
}

/// Snapshot of system and application memory usage.
class MemorySnapshot {
  /// Physical RAM bytes currently resident in memory (Windows `workingSetSize`).
  final int processRssBytes;

  /// Process lifetime peak resident physical RAM bytes (Windows `peakWorkingSetSize`).
  final int processMaxRssBytes;

  /// Process private virtual committed memory bytes (Windows `privateUsage`).
  final int? processPrivateBytes;

  /// Process committed virtual memory charge bytes (Windows `pagefileUsage`).
  final int? processCommitChargeBytes;

  final int? processSessionPeakRssBytes;
  final int? processSessionPeakPrivateBytes;
  final int systemTotalPhysBytes;
  final int systemAvailPhysBytes;
  final int systemMemoryLoadPercent;
  final int? imageCacheBytes;
  final int? imageCacheCount;
  final int? dartHeapBytes;
  final int processId;
  final int? mpvProcessId;
  final int? mpvRssBytes;
  final int? mpvPrivateBytes;
  final int? mpvCommitChargeBytes;
  final int? overlayProcessId;
  final int? overlayRssBytes;
  final int? overlayPrivateBytes;
  final int? overlayCommitChargeBytes;
  final String overlayProcessStatus;
  final DateTime sampledAt;
  final int samplingDurationMs;

  MemorySnapshot({
    required this.processRssBytes,
    required this.processMaxRssBytes,
    this.processPrivateBytes,
    this.processCommitChargeBytes,
    this.processSessionPeakRssBytes,
    this.processSessionPeakPrivateBytes,
    required this.systemTotalPhysBytes,
    required this.systemAvailPhysBytes,
    required this.systemMemoryLoadPercent,
    this.imageCacheBytes,
    this.imageCacheCount,
    this.dartHeapBytes,
    required this.processId,
    this.mpvProcessId,
    this.mpvRssBytes,
    this.mpvPrivateBytes,
    this.mpvCommitChargeBytes,
    this.overlayProcessId,
    this.overlayRssBytes,
    this.overlayPrivateBytes,
    this.overlayCommitChargeBytes,
    this.overlayProcessStatus = 'not-checked',
    required this.sampledAt,
    this.samplingDurationMs = 0,
  });

  /// Canonical aliases for Windows process memory counters.
  int get processWorkingSetBytes => processRssBytes;
  int get processPeakWorkingSetBytes => processMaxRssBytes;
  int? get processPrivateCommitBytes => processPrivateBytes;

  double get processRssMb => processRssBytes / (1024 * 1024);
  double get processMaxRssMb => processMaxRssBytes / (1024 * 1024);
  double? get processPrivateMb =>
      processPrivateBytes == null ? null : processPrivateBytes! / (1024 * 1024);
  double? get processCommitChargeMb => processCommitChargeBytes == null
      ? null
      : processCommitChargeBytes! / (1024 * 1024);
  double get systemTotalPhysMb => systemTotalPhysBytes / (1024 * 1024);
  double get systemAvailPhysMb => systemAvailPhysBytes / (1024 * 1024);
  double get imageCacheMb => (imageCacheBytes ?? 0) / (1024 * 1024);
  double? get dartHeapMb =>
      dartHeapBytes == null ? null : dartHeapBytes! / (1024 * 1024);
  double get mpvRssMb => (mpvRssBytes ?? 0) / (1024 * 1024);
  double? get mpvPrivateMb =>
      mpvPrivateBytes == null ? null : mpvPrivateBytes! / (1024 * 1024);

  /// True when Windows system RAM is under high pressure (less than 500 MB free or >= 90% load).
  bool get isSystemMemoryConstrained =>
      systemAvailPhysBytes < 500 * 1024 * 1024 ||
      systemMemoryLoadPercent >= 90;

  /// True when Windows kernel has trimmed working set pages to pagefile under memory pressure.
  /// (Indicated by resident RSS significantly below session peak while private commit remains elevated).
  bool get isWorkingSetTrimmed =>
      isSystemMemoryConstrained &&
      processSessionPeakRssBytes != null &&
      processRssBytes < (processSessionPeakRssBytes! * 0.65) &&
      (processPrivateBytes ?? 0) >= (processRssBytes * 1.3);

  Map<String, dynamic> toMap() => {
    'processRssMb': processRssMb.toStringAsFixed(1),
    'processWorkingSetMb': processRssMb.toStringAsFixed(1),
    'processMaxRssMb': processMaxRssMb.toStringAsFixed(1),
    'processLifetimePeakRssMb': processMaxRssMb.toStringAsFixed(1),
    if (processPrivateMb != null)
      'processPrivateMb': processPrivateMb!.toStringAsFixed(1),
    if (processPrivateMb != null)
      'processPrivateCommitMb': processPrivateMb!.toStringAsFixed(1),
    if (processCommitChargeMb != null)
      'processCommitChargeMb': processCommitChargeMb!.toStringAsFixed(1),
    if (processSessionPeakRssBytes != null)
      'processSessionPeakRssMb': (processSessionPeakRssBytes! / (1024 * 1024))
          .toStringAsFixed(1),
    if (processSessionPeakPrivateBytes != null)
      'processSessionPeakPrivateMb':
          (processSessionPeakPrivateBytes! / (1024 * 1024)).toStringAsFixed(1),
    if (dartHeapMb != null) 'dartHeapMb': dartHeapMb!.toStringAsFixed(1),
    'processId': processId,
    if (mpvProcessId != null) 'mpvProcessId': mpvProcessId,
    if (mpvRssBytes != null) 'mpvRssMb': mpvRssMb.toStringAsFixed(1),
    if (mpvPrivateMb != null) 'mpvPrivateMb': mpvPrivateMb!.toStringAsFixed(1),
    if (overlayProcessId != null) 'overlayProcessId': overlayProcessId,
    if (overlayRssBytes != null)
      'overlayRssMb': (overlayRssBytes! / (1024 * 1024)).toStringAsFixed(1),
    if (overlayPrivateBytes != null)
      'overlayPrivateMb': (overlayPrivateBytes! / (1024 * 1024))
          .toStringAsFixed(1),
    'overlayProcessStatus': overlayProcessStatus,
    'isSystemMemoryConstrained': isSystemMemoryConstrained,
    'isWorkingSetTrimmed': isWorkingSetTrimmed,
    'sampledAt': sampledAt.toIso8601String(),
    'samplingDurationMs': samplingDurationMs,
    'systemTotalPhysMb': systemTotalPhysMb.toStringAsFixed(1),
    'systemAvailPhysMb': systemAvailPhysMb.toStringAsFixed(1),
    'systemMemoryLoadPercent': systemMemoryLoadPercent,
    'imageCacheMb': imageCacheMb.toStringAsFixed(1),
    'imageCacheCount': imageCacheCount ?? 0,
  };

  @override
  String toString() {
    final privateSuffix = processPrivateBytes != null
        ? ' [Private Commit: ${processPrivateMb!.toStringAsFixed(1)} MB]'
        : '';
    final mpvSuffix = mpvRssBytes != null
        ? ' | MPV PID $mpvProcessId RSS: ${mpvRssMb.toStringAsFixed(1)} MB'
              '${mpvPrivateMb == null ? '' : ' (Private ${mpvPrivateMb!.toStringAsFixed(1)} MB)'}'
        : '';
    final trimNote = isWorkingSetTrimmed
        ? ' [Note: Windows kernel trimmed working set pages under system RAM pressure ($systemMemoryLoadPercent% load, ${systemAvailPhysMb.toStringAsFixed(0)} MB free)]'
        : '';
    return 'Sampled: ${sampledAt.toIso8601String()} | Process RSS: ${processRssMb.toStringAsFixed(1)} MB (Process Lifetime Peak RSS: ${processMaxRssMb.toStringAsFixed(1)} MB)$privateSuffix$mpvSuffix$trimNote | '
        'Main PID: $processId | '
        'System RAM: ${systemAvailPhysMb.toStringAsFixed(0)} MB free / ${systemTotalPhysMb.toStringAsFixed(0)} MB ($systemMemoryLoadPercent% load) | '
        'ImageCache: ${imageCacheMb.toStringAsFixed(1)} MB (${imageCacheCount ?? 0} images)';
  }
}

/// Snapshot of system and application CPU usage.
class CpuSnapshot {
  final double processCpuPercent;
  final double systemCpuPercent;
  final int sampleIntervalMs;

  CpuSnapshot({
    required this.processCpuPercent,
    required this.systemCpuPercent,
    required this.sampleIntervalMs,
  });

  Map<String, dynamic> toMap() => {
    'processCpuPercent': processCpuPercent.toStringAsFixed(1),
    'systemCpuPercent': systemCpuPercent.toStringAsFixed(1),
    'sampleIntervalMs': sampleIntervalMs,
  };

  @override
  String toString() =>
      'Process CPU: ${processCpuPercent.toStringAsFixed(1)}% | System CPU: ${systemCpuPercent.toStringAsFixed(1)}%';
}

/// Storage usage breakdown for WallSync directories.
class StorageSnapshot {
  final int appDataBytes;
  final int localAppDataBytes;
  final int videoCacheBytes;
  final int thumbnailCacheBytes;
  final int logFileBytes;
  final int totalWallSyncBytes;

  StorageSnapshot({
    required this.appDataBytes,
    required this.localAppDataBytes,
    required this.videoCacheBytes,
    required this.thumbnailCacheBytes,
    required this.logFileBytes,
    required this.totalWallSyncBytes,
  });

  double get appDataMb => appDataBytes / (1024 * 1024);
  double get localAppDataMb => localAppDataBytes / (1024 * 1024);
  double get videoCacheMb => videoCacheBytes / (1024 * 1024);
  double get thumbnailCacheMb => thumbnailCacheBytes / (1024 * 1024);
  double get logFileMb => logFileBytes / (1024 * 1024);
  double get totalMb => totalWallSyncBytes / (1024 * 1024);

  Map<String, dynamic> toMap() => {
    'appDataMb': appDataMb.toStringAsFixed(2),
    'localAppDataMb': localAppDataMb.toStringAsFixed(2),
    'videoCacheMb': videoCacheMb.toStringAsFixed(2),
    'thumbnailCacheMb': thumbnailCacheMb.toStringAsFixed(2),
    'logFileMb': logFileMb.toStringAsFixed(2),
    'totalMb': totalMb.toStringAsFixed(2),
  };

  @override
  String toString() =>
      'Total: ${totalMb.toStringAsFixed(2)} MB (Videos: ${videoCacheMb.toStringAsFixed(1)} MB, '
      'Thumbs: ${thumbnailCacheMb.toStringAsFixed(1)} MB, Logs: ${logFileMb.toStringAsFixed(2)} MB)';
}

/// Frame rendering smoothness metrics.
class SmoothnessSnapshot {
  final int totalFrames;
  final int jankFrames; // frames taking > 16.66ms active compute
  final int severeJankFrames; // frames taking > 33.33ms active compute
  /// Frames delayed by OS standby / vsync suspension / long periods outside measured stages (>1000ms).
  /// Excluded from eligible frames so OS sleep/suspension is not misclassified as active frame jank.
  final int suspendedFrames;
  final int eligibleFrames;
  final int pipelineGapFrames;
  final double averageFrameTimeMs;
  final double averageTotalSpanMs;
  final double worstFrameTimeMs;
  final double averageBuildTimeMs;
  final double averageRasterTimeMs;
  final double worstBuildTimeMs;
  final double worstRasterTimeMs;
  final double p50FrameTimeMs;
  final double p90FrameTimeMs;
  final double p99FrameTimeMs;
  final double cumulativeSmoothnessPercentage;
  final double rollingSmoothnessPercentage;
  final List<String> recentFrameSamples;

  double get smoothnessPercentage => cumulativeSmoothnessPercentage;

  SmoothnessSnapshot({
    required this.totalFrames,
    required this.jankFrames,
    required this.severeJankFrames,
    this.suspendedFrames = 0,
    required this.eligibleFrames,
    this.pipelineGapFrames = 0,
    required this.averageFrameTimeMs,
    this.averageTotalSpanMs = 0.0,
    required this.worstFrameTimeMs,
    this.averageBuildTimeMs = 0.0,
    this.averageRasterTimeMs = 0.0,
    this.worstBuildTimeMs = 0.0,
    this.worstRasterTimeMs = 0.0,
    this.p50FrameTimeMs = 0.0,
    this.p90FrameTimeMs = 0.0,
    this.p99FrameTimeMs = 0.0,
    this.recentFrameSamples = const [],
    double? smoothnessPercentage,
    double? cumulativeSmoothnessPercentage,
    this.rollingSmoothnessPercentage = 100.0,
  }) : cumulativeSmoothnessPercentage =
           cumulativeSmoothnessPercentage ?? smoothnessPercentage ?? 100.0;

  Map<String, dynamic> toMap() => {
    'totalFrames': totalFrames,
    'jankFrames': jankFrames,
    'severeJankFrames': severeJankFrames,
    'suspendedFrames': suspendedFrames,
    'eligibleFrames': eligibleFrames,
    'pipelineGapFrames': pipelineGapFrames,
    'averageFrameTimeMs': averageFrameTimeMs.toStringAsFixed(2),
    'averageTotalSpanMs': averageTotalSpanMs.toStringAsFixed(2),
    'worstFrameTimeMs': worstFrameTimeMs.toStringAsFixed(2),
    'averageBuildTimeMs': averageBuildTimeMs.toStringAsFixed(2),
    'averageRasterTimeMs': averageRasterTimeMs.toStringAsFixed(2),
    'worstBuildTimeMs': worstBuildTimeMs.toStringAsFixed(2),
    'worstRasterTimeMs': worstRasterTimeMs.toStringAsFixed(2),
    'p50FrameTimeMs': p50FrameTimeMs.toStringAsFixed(2),
    'p90FrameTimeMs': p90FrameTimeMs.toStringAsFixed(2),
    'p99FrameTimeMs': p99FrameTimeMs.toStringAsFixed(2),
    'recentFrameSamples': recentFrameSamples,
    'cumulativeSmoothnessPercentage':
        cumulativeSmoothnessPercentage.toStringAsFixed(1),
    'rollingSmoothnessPercentage':
        rollingSmoothnessPercentage.toStringAsFixed(1),
    'smoothnessPercentage': cumulativeSmoothnessPercentage.toStringAsFixed(1),
  };

  @override
  String toString() =>
      'Frames: $totalFrames ($eligibleFrames measured, $suspendedFrames gaps) | '
      'Smoothness: ${cumulativeSmoothnessPercentage.toStringAsFixed(1)}% (Rolling: ${rollingSmoothnessPercentage.toStringAsFixed(1)}%) | '
      'Jank: $jankFrames (>16.6ms) | Severe Jank: $severeJankFrames (>33.3ms) | '
      'P50: ${p50FrameTimeMs.toStringAsFixed(1)}ms | P90: ${p90FrameTimeMs.toStringAsFixed(1)}ms | P99: ${p99FrameTimeMs.toStringAsFixed(1)}ms | '
      'Avg Active: ${averageFrameTimeMs.toStringAsFixed(2)}ms (Build: ${averageBuildTimeMs.toStringAsFixed(2)}ms, Raster: ${averageRasterTimeMs.toStringAsFixed(2)}ms, Span: $averageTotalSpanSpanSafe) | '
      'Peak Active: ${worstFrameTimeMs.toStringAsFixed(2)}ms';

  String get averageTotalSpanSpanSafe => averageTotalSpanMs.toStringAsFixed(2);
}

/// Active async operation tracker for detecting overloading & over-waiting.
class AsyncOperationRecord {
  final String id;
  final String tag;
  final String name;
  final DateTime startTime;
  final Duration warningThreshold;
  Timer? timeoutWarningTimer;

  AsyncOperationRecord({
    required this.id,
    required this.tag,
    required this.name,
    required this.startTime,
    required this.warningThreshold,
  });
}

/// Core Diagnostics, Performance Profiler & Hang/Watchdog Detector service.
class DiagnosticsService {
  static final DiagnosticsService instance = DiagnosticsService._internal();
  factory DiagnosticsService() => instance;
  DiagnosticsService._internal();

  bool _initialized = false;
  Timer? _periodicSamplerTimer;
  Timer? _watchdogHeartbeatTimer;

  // Frame timing metrics
  int _totalFrames = 0;
  int _eligibleFrames = 0;
  int _pipelineGapFrames = 0;
  int _jankFrames = 0;
  int _severeJankFrames = 0;
  int _suspendedFrames = 0;
  double _totalFrameDurationMs = 0.0;
  double _worstFrameDurationMs = 0.0;
  double _totalBuildDurationMs = 0.0;
  double _totalRasterDurationMs = 0.0;
  double _totalFrameSpanMs = 0.0;
  double _worstBuildDurationMs = 0.0;
  double _worstRasterDurationMs = 0.0;
  final List<double> _recentFrameDurations = [];
  final List<String> _recentRawFrameSamples = [];
  int? _overlayPid;
  String _overlayProcessStatus = 'not-checked';
  DateTime? _overlayLaunchRequestedAt;

  void markOverlayLaunchRequested() {
    _overlayLaunchRequestedAt = DateTime.now();
    _overlayPid = null;
    _overlayProcessStatus = 'launch-requested';
  }

  void clearOverlayLaunchRequest() {
    _overlayLaunchRequestedAt = null;
    if (_overlayProcessStatus == 'launch-requested') {
      _overlayProcessStatus = 'pid-file-missing';
    }
  }

  // CPU measurement state
  int _lastSysIdleTime = 0;
  int _lastSysKernelTime = 0;
  int _lastSysUserTime = 0;
  int _lastProcKernelTime = 0;
  int _lastProcUserTime = 0;
  DateTime _lastCpuSampleTime = DateTime.now();
  double _cachedProcCpuPercent = 0.0;
  double _cachedSysCpuPercent = 0.0;

  // Watchdog hang detection
  DateTime _lastHeartbeat = DateTime.now();
  static const Duration _watchdogInterval = Duration(milliseconds: 500);
  static const Duration _hangThreshold = Duration(milliseconds: 1000);

  // Overloading & Over-waiting tracking
  final Map<String, AsyncOperationRecord> _activeOperations = {};
  int _opCounter = 0;

  // Recent hang alerts
  final List<String> _hangEvents = [];

  bool get isInitialized => _initialized;
  int get activeOperationCount => _activeOperations.length;
  DateTime _diagnosticsSessionStartedAt = DateTime.now();
  int? _sampledSessionPeakRssBytes;
  int? _sampledSessionPeakPrivateBytes;

  /// Initializes the diagnostics system: frame callback, hang watchdog, and CPU tracking.
  void init({bool enablePeriodicSampling = true}) {
    if (_initialized || !kDebugMode) return;
    _initialized = true;

    logInfo(
      'DiagnosticsService',
      'Initializing performance profiler and runtime watchdog...',
    );

    // 1. Initialize Frame Timings Callback for Smoothness / Jank tracking
    try {
      SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
      logInfo(
        'DiagnosticsService',
        'Frame timing listener attached for 60 FPS smoothness analysis.',
      );
    } catch (e) {
      logWarning(
        'DiagnosticsService',
        'Could not attach FrameTimings callback: $e',
      );
    }

    // 2. Initialize Watchdog Heartbeat for detecting UI thread hangs / freezes
    _startWatchdog();

    // 3. Initialize periodic health sampling (every 30 seconds in dev/debug mode)
    if (enablePeriodicSampling) {
      _periodicSamplerTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        unawaited(_refreshOverlayPid().whenComplete(takePeriodicSnapshot));
      });
    }
    unawaited(_refreshOverlayPid());

    // Baseline CPU sample
    _sampleCpu();
    logInfo(
      'DiagnosticsService',
      'DiagnosticsService initialized successfully.',
    );
  }

  // Severe jank log throttling
  DateTime? _lastJankLogTime;

  void _onFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _recordFrameMetrics(
        timing.buildDuration.inMicroseconds / 1000.0,
        timing.rasterDuration.inMicroseconds / 1000.0,
        timing.totalSpan.inMicroseconds / 1000.0,
        DateTime.now(),
      );
    }
  }

  @visibleForTesting
  void recordFrameTimingForTesting({
    required Duration build,
    required Duration raster,
    required Duration totalSpan,
  }) {
    _recordFrameMetrics(
      build.inMicroseconds / 1000.0,
      raster.inMicroseconds / 1000.0,
      totalSpan.inMicroseconds / 1000.0,
      DateTime.now(),
    );
  }

  void _recordFrameMetrics(
    double buildMs,
    double rasterMs,
    double totalMs,
    DateTime now,
  ) {
    _totalFrames++;
    // Build and raster can overlap in the Flutter pipeline. Report each stage
    // separately and use the slower stage for per-frame jank classification.
    final activeMs = math.max(buildMs, rasterMs);
    final nonWorkSpanMs = math.max(0.0, totalMs - activeMs);
    final isSuspensionGap = nonWorkSpanMs > 1000.0;
    final isJankSample = !isSuspensionGap && activeMs > 16.66;
    _recentRawFrameSamples.add(
      'build=${buildMs.toStringAsFixed(2)}ms raster=${rasterMs.toStringAsFixed(2)}ms '
      'totalSpan=${totalMs.toStringAsFixed(2)}ms outsideStages=${nonWorkSpanMs.toStringAsFixed(2)}ms '
      'class=${isSuspensionGap
          ? 'gap'
          : isJankSample
          ? 'jank'
          : 'smooth'}',
    );
    if (_recentRawFrameSamples.length > 20) {
      _recentRawFrameSamples.removeAt(0);
    }

    // A long span outside measured build/raster work is kept separate from
    // frame work. FrameTiming cannot prove OS sleep vs debugger/compositor gap.
    if (nonWorkSpanMs > 1000.0) {
      _suspendedFrames++;
      return;
    }

    _eligibleFrames++;
    if (nonWorkSpanMs > 50.0) _pipelineGapFrames++;
    _totalFrameDurationMs += activeMs;
    _totalBuildDurationMs += buildMs;
    _totalRasterDurationMs += rasterMs;
    _totalFrameSpanMs += totalMs;

    if (activeMs > _worstFrameDurationMs) _worstFrameDurationMs = activeMs;
    if (buildMs > _worstBuildDurationMs) _worstBuildDurationMs = buildMs;
    if (rasterMs > _worstRasterDurationMs) _worstRasterDurationMs = rasterMs;

    _recentFrameDurations.add(activeMs);
    if (_recentFrameDurations.length > 120) _recentFrameDurations.removeAt(0);

    final isJank = activeMs > 16.66;
    final isSevereJank = activeMs > 33.33;
    if (isSevereJank) {
      _severeJankFrames++;
      _jankFrames++;
      final shouldLog =
          activeMs > 100.0 &&
          (_lastJankLogTime == null ||
              now.difference(_lastJankLogTime!).inMilliseconds > 3000);
      if (shouldLog) {
        _lastJankLogTime = now;
        logWarning(
          'DiagnosticsService',
          '[SEVERE FRAME WORK] pid=$pid '
              'max(build,raster)=${activeMs.toStringAsFixed(1)}ms '
              '(UI Build: ${buildMs.toStringAsFixed(1)}ms, Raster: ${rasterMs.toStringAsFixed(1)}ms; '
              'Total Span: ${totalMs.toStringAsFixed(1)}ms; outside stages: ${nonWorkSpanMs.toStringAsFixed(1)}ms)',
        );
      }
    } else if (isJank) {
      _jankFrames++;
    }
  }

  void _startWatchdog() {
    _lastHeartbeat = DateTime.now();
    _watchdogHeartbeatTimer?.cancel();
    _watchdogHeartbeatTimer = Timer.periodic(_watchdogInterval, (_) {
      final now = DateTime.now();
      final elapsed = now.difference(_lastHeartbeat);
      _lastHeartbeat = now;

      final hangDuration = elapsed - _watchdogInterval;
      if (hangDuration >= _hangThreshold) {
        final activeOperationDetails = _activeOperations.values
            .map(
              (operation) =>
                  '${operation.tag}.${operation.name}:'
                  '${now.difference(operation.startTime).inMilliseconds}ms',
            )
            .join(', ');
        final note =
            '[EVENT LOOP GAP] pid=$pid no watchdog heartbeat for '
            '${hangDuration.inMilliseconds} ms; this is event-loop delay / outside stages, '
            'not Flutter UI build time. OS/debugger cause is unverified. Active async ops: '
            '${_activeOperations.length}'
            '${activeOperationDetails.isEmpty ? '' : ' [$activeOperationDetails]'}';
        _hangEvents.add('[${now.toIso8601String()}] $note');
        logWarning('DiagnosticsService', note);
      }
    });
  }

  Future<void> _refreshOverlayPid() async {
    if (!Platform.isWindows) return;
    try {
      final pidFile = await SettingsService().pidFile;
      if (!await pidFile.exists()) {
        _overlayPid = null;
        final launchRequestedAt = _overlayLaunchRequestedAt;
        if (launchRequestedAt != null &&
            DateTime.now().difference(launchRequestedAt) <
                const Duration(seconds: 30)) {
          _overlayProcessStatus = 'launch-requested';
        } else {
          _overlayLaunchRequestedAt = null;
          _overlayProcessStatus = 'pid-file-missing';
        }
        return;
      }
      final record = OverlayProcessRecord.tryParse(
        (await pidFile.readAsString()).trim(),
      );
      if (record == null) {
        _overlayPid = null;
        _overlayProcessStatus = 'invalid-pid-file';
        return;
      }
      if (record.creationTime == null) {
        _overlayPid = null;
        _overlayProcessStatus = 'identity-unverified';
        return;
      }
      final inspection = await inspectWindowsProcess(record.pid);
      if (inspection == null) {
        _overlayPid = null;
        _overlayProcessStatus = 'liveness-query-failed';
      } else if (!inspection.isRunning && inspection.creationTime == 0) {
        _overlayPid = null;
        _overlayProcessStatus = 'stopped';
      } else if (!inspection.matches(record)) {
        _overlayPid = null;
        _overlayProcessStatus = 'process-identity-mismatch';
      } else if (!inspection.isRunning) {
        _overlayPid = null;
        _overlayProcessStatus = 'stopped';
      } else {
        _overlayLaunchRequestedAt = null;
        _overlayPid = record.pid;
        _overlayProcessStatus = record.ready ? 'running' : 'starting';
      }
    } catch (error, stackTrace) {
      _overlayPid = null;
      _overlayProcessStatus = 'liveness-query-failed';
      logWarning(
        'DiagnosticsService',
        'Could not verify overlay process liveness: $error\n$stackTrace',
      );
    }
  }

  /// Measures the main process and currently tracked children. Working set and
  /// private commit are independent process counters and must not be summed.
  MemorySnapshot getMemorySnapshot() {
    final samplingStopwatch = Stopwatch()..start();
    // ProcessInfo uses bytes on Windows, but it does not expose the Dart heap.
    // Keep these values only as fallback RSS/high-water measurements.
    int rss = ProcessInfo.currentRss;
    int maxRss = ProcessInfo.maxRss;
    int? privateBytes;
    int? commitChargeBytes;
    int totalPhys = 0;
    int availPhys = 0;
    int memLoad = 0;
    int? mpvRss;
    int? mpvPrivate;
    int? mpvCommitCharge;
    final int? mpvPid = LiveWallpaperManager().mpvPid;
    int? overlayRss;
    int? overlayPrivate;
    int? overlayCommitCharge;
    final int? overlayPid = _overlayPid;

    _ProcessMemorySample? queryMemory(HANDLE handle) {
      final getProcessMemoryInfo = _getProcessMemoryInfoFn();
      if (getProcessMemoryInfo == null) return null;
      final counters = calloc<_ProcessMemoryCountersEx>();
      try {
        counters.ref.cb = sizeOf<_ProcessMemoryCountersEx>();
        final success = getProcessMemoryInfo(
          handle,
          counters,
          sizeOf<_ProcessMemoryCountersEx>(),
        );
        if (success == 0) return null;
        return _ProcessMemorySample(
          counters.ref.workingSetSize,
          counters.ref.peakWorkingSetSize,
          counters.ref.privateUsage,
          counters.ref.pagefileUsage,
        );
      } finally {
        calloc.free(counters);
      }
    }

    if (Platform.isWindows) {
      Pointer<MEMORYSTATUSEX> memoryStatus = nullptr;
      try {
        memoryStatus = calloc<MEMORYSTATUSEX>();
        memoryStatus.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
        if (GlobalMemoryStatusEx(memoryStatus).value) {
          totalPhys = memoryStatus.ref.ullTotalPhys;
          availPhys = memoryStatus.ref.ullAvailPhys;
          memLoad = memoryStatus.ref.dwMemoryLoad;
        }
      } catch (_) {
      } finally {
        if (memoryStatus.address != 0) calloc.free(memoryStatus);
      }

      try {
        // GetCurrentProcess returns a non-owning pseudo-handle for this PID;
        // it must not be closed. PSAPI reports SIZE_T byte counts.
        final currentPid = GetCurrentProcessId();
        if (currentPid == pid) {
          final sample = queryMemory(GetCurrentProcess());
          if (sample != null) {
            if (sample.workingSetBytes > 0) rss = sample.workingSetBytes;
            if (sample.peakWorkingSetBytes > 0) {
              maxRss = sample.peakWorkingSetBytes;
            }
            privateBytes = sample.privateBytes;
            commitChargeBytes = sample.commitChargeBytes;
          }
        }
      } catch (_) {}

      _ProcessMemorySample? queryPid(int? candidatePid) {
        if (candidatePid == null || candidatePid <= 0 || candidatePid == pid) {
          return null;
        }
        HANDLE? processHandle;
        try {
          var opened = OpenProcess(
            PROCESS_QUERY_INFORMATION | PROCESS_VM_READ,
            false,
            candidatePid,
          );
          if (opened.value.address == 0) {
            opened = OpenProcess(
              PROCESS_QUERY_LIMITED_INFORMATION,
              false,
              candidatePid,
            );
          }
          processHandle = opened.value;
          return processHandle.address == 0 ? null : queryMemory(processHandle);
        } catch (_) {
        } finally {
          if (processHandle != null && processHandle.address != 0) {
            CloseHandle(processHandle);
          }
        }
        return null;
      }

      final mpvSample = queryPid(mpvPid);
      if (mpvSample != null) {
        mpvRss = mpvSample.workingSetBytes;
        mpvPrivate = mpvSample.privateBytes;
        mpvCommitCharge = mpvSample.commitChargeBytes;
      }
      final overlaySample = queryPid(overlayPid);
      if (overlaySample != null) {
        overlayRss = overlaySample.workingSetBytes;
        overlayPrivate = overlaySample.privateBytes;
        overlayCommitCharge = overlaySample.commitChargeBytes;
      }
    }

    _sampledSessionPeakRssBytes = math.max(
      _sampledSessionPeakRssBytes ?? 0,
      rss,
    );
    if (privateBytes != null) {
      _sampledSessionPeakPrivateBytes = math.max(
        _sampledSessionPeakPrivateBytes ?? 0,
        privateBytes,
      );
    }

    int? imageCacheBytes;
    int? imageCacheCount;
    try {
      imageCacheBytes = PaintingBinding.instance.imageCache.currentSizeBytes;
      imageCacheCount = PaintingBinding.instance.imageCache.currentSize;
    } catch (_) {}

    return MemorySnapshot(
      processRssBytes: rss,
      processMaxRssBytes: maxRss,
      processPrivateBytes: privateBytes,
      processCommitChargeBytes: commitChargeBytes,
      processSessionPeakRssBytes: _sampledSessionPeakRssBytes,
      processSessionPeakPrivateBytes: _sampledSessionPeakPrivateBytes,
      systemTotalPhysBytes: totalPhys,
      systemAvailPhysBytes: availPhys,
      systemMemoryLoadPercent: memLoad,
      imageCacheBytes: imageCacheBytes,
      imageCacheCount: imageCacheCount,
      dartHeapBytes: null,
      processId: pid,
      mpvProcessId: mpvRss == null ? null : mpvPid,
      mpvRssBytes: mpvRss,
      mpvPrivateBytes: mpvPrivate,
      mpvCommitChargeBytes: mpvCommitCharge,
      overlayProcessId: overlayPid,
      overlayRssBytes: overlayRss,
      overlayPrivateBytes: overlayPrivate,
      overlayCommitChargeBytes: overlayCommitCharge,
      overlayProcessStatus: overlayPid != null && overlayRss == null
          ? 'running-memory-query-failed'
          : _overlayProcessStatus,
      sampledAt: DateTime.now(),
      samplingDurationMs: samplingStopwatch.elapsedMilliseconds,
    );
  }

  /// Samples and calculates process and system CPU utilization.
  CpuSnapshot getCpuSnapshot() {
    _sampleCpu();
    return CpuSnapshot(
      processCpuPercent: _cachedProcCpuPercent,
      systemCpuPercent: _cachedSysCpuPercent,
      sampleIntervalMs: DateTime.now()
          .difference(_lastCpuSampleTime)
          .inMilliseconds,
    );
  }

  void _sampleCpu() {
    if (!Platform.isWindows) return;

    final now = DateTime.now();
    final elapsedMs = now.difference(_lastCpuSampleTime).inMilliseconds;
    // 50ms minimum guard — prevents division-by-zero and avoids
    // CPU% showing 0.0% in periodic health snapshots that run immediately
    // after a prior diagnostic call (was 200ms, too long for 30s intervals).
    if (elapsedMs < 50) return;

    try {
      // 1. System CPU via GetSystemTimes
      final idleTime = calloc<FILETIME>();
      final kernelTime = calloc<FILETIME>();
      final userTime = calloc<FILETIME>();

      if (GetSystemTimes(idleTime, kernelTime, userTime).value) {
        final int idle =
            (idleTime.ref.dwHighDateTime << 32) | idleTime.ref.dwLowDateTime;
        final int kernel =
            (kernelTime.ref.dwHighDateTime << 32) |
            kernelTime.ref.dwLowDateTime;
        final int user =
            (userTime.ref.dwHighDateTime << 32) | userTime.ref.dwLowDateTime;

        if (_lastSysIdleTime != 0) {
          final int usrDelta = user - _lastSysUserTime;
          final int kerDelta = kernel - _lastSysKernelTime;
          final int idlDelta = idle - _lastSysIdleTime;
          final int sysTotal = usrDelta + kerDelta;
          if (sysTotal > 0) {
            _cachedSysCpuPercent = (((sysTotal - idlDelta) * 100.0) / sysTotal)
                .clamp(0.0, 100.0);
          }
        }
        _lastSysIdleTime = idle;
        _lastSysKernelTime = kernel;
        _lastSysUserTime = user;
      }
      calloc.free(idleTime);
      calloc.free(kernelTime);
      calloc.free(userTime);

      // 2. Process CPU via GetProcessTimes
      final cTime = calloc<FILETIME>();
      final eTime = calloc<FILETIME>();
      final pKernelTime = calloc<FILETIME>();
      final pUserTime = calloc<FILETIME>();

      final hProcess = GetCurrentProcess();
      if (GetProcessTimes(
        hProcess,
        cTime,
        eTime,
        pKernelTime,
        pUserTime,
      ).value) {
        final int pKernel =
            (pKernelTime.ref.dwHighDateTime << 32) |
            pKernelTime.ref.dwLowDateTime;
        final int pUser =
            (pUserTime.ref.dwHighDateTime << 32) | pUserTime.ref.dwLowDateTime;

        if (_lastProcKernelTime != 0) {
          final int procTotal =
              (pKernel - _lastProcKernelTime) + (pUser - _lastProcUserTime);
          final int wallClock100ns = elapsedMs * 10000;
          final int numProcessors = Platform.numberOfProcessors;
          if (wallClock100ns > 0) {
            _cachedProcCpuPercent =
                ((procTotal * 100.0) / (wallClock100ns * numProcessors)).clamp(
                  0.0,
                  100.0,
                );
          }
        }
        _lastProcKernelTime = pKernel;
        _lastProcUserTime = pUser;
      }
      calloc.free(cTime);
      calloc.free(eTime);
      calloc.free(pKernelTime);
      calloc.free(pUserTime);
    } catch (_) {}

    _lastCpuSampleTime = now;
  }

  /// Calculates storage usage of WallSync app data, video cache, thumbnail cache, and logs.
  Future<StorageSnapshot> getStorageSnapshot() async {
    int appDataBytes = 0;
    int localAppDataBytes = 0;
    int videoCacheBytes = 0;
    int thumbCacheBytes = 0;
    int logFileBytes = 0;

    final appData = Platform.environment['APPDATA'];
    final localAppData = Platform.environment['LOCALAPPDATA'];

    if (appData != null) {
      final appDir = Directory('$appData\\com.example\\wallsync');
      if (await appDir.exists()) {
        try {
          await for (final entity in appDir.list(
            recursive: true,
            followLinks: false,
          )) {
            if (entity is File) {
              final len = await entity.length();
              appDataBytes += len;
              if (entity.path.contains('video_wallpapers')) {
                videoCacheBytes += len;
              } else if (entity.path.contains('video_thumbnails')) {
                thumbCacheBytes += len;
              } else if (entity.path.endsWith('.log')) {
                logFileBytes += len;
              }
            }
          }
        } catch (_) {}
      }
    }

    if (localAppData != null) {
      final localDir = Directory('$localAppData\\WallSync');
      if (await localDir.exists()) {
        try {
          await for (final entity in localDir.list(
            recursive: true,
            followLinks: false,
          )) {
            if (entity is File) {
              localAppDataBytes += await entity.length();
            }
          }
        } catch (_) {}
      }
    }

    return StorageSnapshot(
      appDataBytes: appDataBytes,
      localAppDataBytes: localAppDataBytes,
      videoCacheBytes: videoCacheBytes,
      thumbnailCacheBytes: thumbCacheBytes,
      logFileBytes: logFileBytes,
      totalWallSyncBytes: appDataBytes + localAppDataBytes,
    );
  }

  /// Calculates frame rendering smoothness statistics.
  SmoothnessSnapshot getSmoothnessSnapshot() {
    final double avg = _eligibleFrames > 0
        ? (_totalFrameDurationMs / _eligibleFrames)
        : 0.0;
    final double avgBuild = _eligibleFrames > 0
        ? (_totalBuildDurationMs / _eligibleFrames)
        : 0.0;
    final double avgRaster = _eligibleFrames > 0
        ? (_totalRasterDurationMs / _eligibleFrames)
        : 0.0;
    final double avgSpan = _eligibleFrames > 0
        ? (_totalFrameSpanMs / _eligibleFrames)
        : 0.0;
    final double smooth = _eligibleFrames > 0
        ? (((_eligibleFrames - _jankFrames) * 100.0) / _eligibleFrames)
        : 100.0;

    double p50 = 0.0;
    double p90 = 0.0;
    double p99 = 0.0;
    double rollingSmooth = 100.0;
    if (_recentFrameDurations.isNotEmpty) {
      final sorted = List<double>.from(_recentFrameDurations)..sort();
      final int p50Idx = (sorted.length * 0.50).floor().clamp(0, sorted.length - 1);
      final int p90Idx = (sorted.length * 0.90).floor().clamp(0, sorted.length - 1);
      final int p99Idx = (sorted.length * 0.99).floor().clamp(0, sorted.length - 1);
      p50 = sorted[p50Idx];
      p90 = sorted[p90Idx];
      p99 = sorted[p99Idx];

      final smoothRecentCount =
          _recentFrameDurations.where((d) => d <= 16.66).length;
      rollingSmooth =
          (smoothRecentCount * 100.0) / _recentFrameDurations.length;
    }

    return SmoothnessSnapshot(
      totalFrames: _totalFrames,
      jankFrames: _jankFrames,
      severeJankFrames: _severeJankFrames,
      suspendedFrames: _suspendedFrames,
      eligibleFrames: _eligibleFrames,
      pipelineGapFrames: _pipelineGapFrames,
      averageFrameTimeMs: avg,
      averageTotalSpanMs: avgSpan,
      worstFrameTimeMs: _worstFrameDurationMs,
      averageBuildTimeMs: avgBuild,
      averageRasterTimeMs: avgRaster,
      worstBuildTimeMs: _worstBuildDurationMs,
      worstRasterTimeMs: _worstRasterDurationMs,
      p50FrameTimeMs: p50,
      p90FrameTimeMs: p90,
      p99FrameTimeMs: p99,
      recentFrameSamples: List.unmodifiable(_recentRawFrameSamples),
      cumulativeSmoothnessPercentage: smooth.clamp(0.0, 100.0),
      rollingSmoothnessPercentage: rollingSmooth.clamp(0.0, 100.0),
    );
  }

  /// Resets recorded frame timings and hang alerts for a clean benchmark run.
  void resetSmoothnessMetrics() {
    _diagnosticsSessionStartedAt = DateTime.now();
    _totalFrames = 0;
    _eligibleFrames = 0;
    _pipelineGapFrames = 0;
    _jankFrames = 0;
    _severeJankFrames = 0;
    _suspendedFrames = 0;
    _totalFrameDurationMs = 0.0;
    _worstFrameDurationMs = 0.0;
    _totalBuildDurationMs = 0.0;
    _totalRasterDurationMs = 0.0;
    _totalFrameSpanMs = 0.0;
    _worstBuildDurationMs = 0.0;
    _worstRasterDurationMs = 0.0;
    _recentFrameDurations.clear();
    _recentRawFrameSamples.clear();
    _hangEvents.clear();
    _lastJankLogTime = null;
    logInfo(
      'DiagnosticsService',
      'Smoothness and hang metrics reset to baseline.',
    );
  }

  /// Executes an async task while measuring duration and tracking over-waiting and overloading.
  /// Emits an explicit warning if the task takes longer than [warningThreshold].
  Future<T> trackAsyncOperation<T>({
    required String tag,
    required String name,
    required Future<T> Function() operation,
    Duration warningThreshold = const Duration(seconds: 3),
  }) async {
    if (!kDebugMode) {
      return await operation();
    }
    final opId = '${name}_${++_opCounter}';
    final startTime = DateTime.now();

    final record = AsyncOperationRecord(
      id: opId,
      tag: tag,
      name: name,
      startTime: startTime,
      warningThreshold: warningThreshold,
    );
    final timelineTask = developer.TimelineTask()
      ..start('WallSync $tag.$name', arguments: {'operationId': opId});

    // Schedule over-wait warning timer
    record.timeoutWarningTimer = Timer(warningThreshold, () {
      if (_activeOperations.containsKey(opId)) {
        final elapsed = DateTime.now().difference(startTime);
        logWarning(
          tag,
          '[OVERWAIT WARNING] Operation "$name" is still running after ${elapsed.inMilliseconds} ms! '
          'Active parallel ops: ${_activeOperations.length}',
        );
      }
    });

    _activeOperations[opId] = record;
    if (_activeOperations.length > 5) {
      logWarning(
        'DiagnosticsService',
        '[OVERLOAD WARNING] High concurrent async load: ${_activeOperations.length} active tasks!',
      );
    }

    try {
      final result = await operation();
      final duration = DateTime.now().difference(startTime);
      record.timeoutWarningTimer?.cancel();
      _activeOperations.remove(opId);

      if (duration > warningThreshold) {
        logInfo(
          tag,
          '[SLOW OPERATION RESOLVED] "$name" completed in ${duration.inMilliseconds} ms',
        );
      } else {
        logDebug(
          tag,
          '[OP COMPLETED] "$name" in ${duration.inMilliseconds} ms',
        );
      }
      timelineTask.finish(
        arguments: {'durationMs': duration.inMilliseconds, 'success': true},
      );
      return result;
    } catch (e, st) {
      final duration = DateTime.now().difference(startTime);
      record.timeoutWarningTimer?.cancel();
      _activeOperations.remove(opId);
      logError(
        tag,
        '[OP FAILED] "$name" failed after ${duration.inMilliseconds} ms: $e',
        e,
        st,
      );
      timelineTask.finish(
        arguments: {'durationMs': duration.inMilliseconds, 'success': false},
      );
      rethrow;
    }
  }

  /// Safely manages working set. Default is a no-op to avoid hard page-fault storms
  /// and severe UI thread stalls under Windows memory pressure.
  void trimWorkingSet({bool force = false}) {
    if (!Platform.isWindows || !force) return;
    try {
      final hProcess = GetCurrentProcess();
      SetProcessWorkingSetSize(hProcess, -1, -1);
    } catch (_) {}
  }

  /// Takes a periodic diagnostic snapshot and outputs to the log.
  Future<void> takePeriodicSnapshot() async {
    try {
      final mem = getMemorySnapshot();
      final cpu = getCpuSnapshot();
      final smooth = getSmoothnessSnapshot();

      // NOTE ON MEMORY LABELS (Windows):
      // - WorkingSet (RSS): Resident pages in physical RAM. Includes shared DLL/driver pages
      //   (D3D11, GPU driver, WebView2). NOT the same as Dart heap or private memory.
      // - PeakWorkingSet: Lifetime high-water mark. Persists across hot restarts in debug mode.
      // - PrivateCommit: PROCESS_MEMORY_COUNTERS_EX.PrivateUsage, the process
      //   commit charge. It is not a Dart heap measurement and is not additive
      //   with working set, image cache, or child-process counters.
      // - ImageCache: Flutter decoded bitmap bytes currently in the painting cache.
      // This sampler cannot attribute private commit to a Dart object, GPU
      // allocation, or plugin; use native heap/GPU tracing before assigning cause.
      logInfo(
        'PERF_MONITOR',
        '[HEALTH SNAPSHOT] '
            'sample=${mem.sampledAt.toIso8601String()} '
            'diagnosticsSessionStarted=${_diagnosticsSessionStartedAt.toIso8601String()} '
            'mainPid=${mem.processId} '
            'rss=${mem.processRssMb.toStringAsFixed(1)}MB '
            'private=${mem.processPrivateMb?.toStringAsFixed(1) ?? "unavailable"}MB '
            'processLifetimePeakRss=${mem.processMaxRssMb.toStringAsFixed(1)}MB | '
            'sampledSessionPeakRss=${mem.processSessionPeakRssBytes == null ? "unavailable" : (mem.processSessionPeakRssBytes! / (1024 * 1024)).toStringAsFixed(1)}MB '
            'sampledSessionPeakPrivate=${mem.processSessionPeakPrivateBytes == null ? "unavailable" : (mem.processSessionPeakPrivateBytes! / (1024 * 1024)).toStringAsFixed(1)}MB | '
            'memorySample=${mem.samplingDurationMs}ms | '
            '${mem.mpvProcessId == null ? '' : 'mpvPid=${mem.mpvProcessId} rss=${mem.mpvRssMb.toStringAsFixed(1)}MB private=${mem.mpvPrivateMb?.toStringAsFixed(1) ?? "unavailable"}MB | '}'
            'Overlay: ${mem.overlayProcessId == null ? mem.overlayProcessStatus : 'pid=${mem.overlayProcessId} ${mem.overlayProcessStatus}${mem.overlayRssBytes == null ? '' : ' rss=${(mem.overlayRssBytes! / (1024 * 1024)).toStringAsFixed(1)}MB'}${mem.overlayPrivateBytes == null ? '' : ' private=${(mem.overlayPrivateBytes! / (1024 * 1024)).toStringAsFixed(1)}MB'}'} | '
            'ImageCache: ${mem.imageCacheMb.toStringAsFixed(1)}MB (${mem.imageCacheCount ?? 0} imgs) | '
            'SysRAM: ${mem.systemAvailPhysMb.toStringAsFixed(0)}/${mem.systemTotalPhysMb.toStringAsFixed(0)}MB (${mem.systemMemoryLoadPercent}% used) | '
            'CPU: ${cpu.processCpuPercent.toStringAsFixed(1)}% process | ${cpu.systemCpuPercent.toStringAsFixed(1)}% sys | '
            'Smoothness: ${smooth.smoothnessPercentage.toStringAsFixed(1)}% '
            '(${smooth.jankFrames}/${smooth.eligibleFrames} measured frames jank; '
            '${smooth.suspendedFrames} long timing gaps excluded) | '
            'Active Ops: ${_activeOperations.length}',
      );
    } catch (e) {
      logError('DiagnosticsService', 'Error taking periodic snapshot', e);
    }
  }

  /// Generates a comprehensive plain-text diagnostic review report.
  Future<String> generateDiagnosticReport() async {
    final mem = getMemorySnapshot();
    final cpu = getCpuSnapshot();
    final storage = await getStorageSnapshot();
    final smooth = getSmoothnessSnapshot();

    final buffer = StringBuffer();
    buffer.writeln(
      '================================================================',
    );
    buffer.writeln(
      '               WALLSYNC RUNTIME DIAGNOSTIC REPORT               ',
    );
    buffer.writeln(
      '================================================================',
    );
    buffer.writeln('Timestamp: ${DateTime.now().toIso8601String()}');
    buffer.writeln(
      'Diagnostics Session Started: '
      '${_diagnosticsSessionStartedAt.toIso8601String()} '
      '(frame counters reset with this Dart isolate; process lifetime peak '
      'memory survives hot restart)',
    );
    buffer.writeln('Platform: Windows (${Platform.operatingSystemVersion})');
    buffer.writeln('Dart SDK: ${Platform.version}');
    buffer.writeln('Process ID: $pid');
    buffer.writeln(
      'Memory Sample Duration: ${mem.samplingDurationMs} ms (synchronous Windows counter queries)',
    );
    buffer.writeln('CPU Cores: ${Platform.numberOfProcessors}');
    buffer.writeln('');
    buffer.writeln('--- 1. MEMORY & RAM PROFILING ---');
    buffer.writeln(
      'Process Working Set:     ${mem.processRssMb.toStringAsFixed(2)} MB'
      ' (Main PID ${mem.processId}; RSS/working set includes shared and mapped pages)',
    );
    buffer.writeln(
      'Peak Working Set:        ${mem.processMaxRssMb.toStringAsFixed(2)} MB'
      ' (process lifetime high-water mark; includes prior hot restarts, not current)',
    );
    if (mem.processPrivateBytes != null) {
      buffer.writeln(
        'Private Commit:          ${mem.processPrivateMb!.toStringAsFixed(2)} MB'
        ' (PROCESS_MEMORY_COUNTERS_EX.PrivateUsage: process commit charge)',
      );
    }
    buffer.writeln(
      'Session Sampled Peak:    RSS '
      '${mem.processSessionPeakRssBytes == null ? "unavailable" : (mem.processSessionPeakRssBytes! / (1024 * 1024)).toStringAsFixed(2)} MB; private '
      '${mem.processSessionPeakPrivateBytes == null ? "unavailable" : (mem.processSessionPeakPrivateBytes! / (1024 * 1024)).toStringAsFixed(2)} MB'
      ' (maximum observed by diagnostics since isolate start; sampling may miss transient peaks)',
    );
    if (mem.mpvProcessId != null) {
      buffer.writeln('MPV Child PID:           ${mem.mpvProcessId}');
      buffer.writeln(
        'MPV Working Set (RSS):   ${mem.mpvRssMb.toStringAsFixed(2)} MB',
      );
      if (mem.mpvPrivateMb != null) {
        buffer.writeln(
          'MPV Private Commit:      ${mem.mpvPrivateMb!.toStringAsFixed(2)} MB',
        );
      }
    } else {
      buffer.writeln('MPV Child Process:       Not running or not queryable');
    }
    if (mem.overlayProcessId != null) {
      buffer.writeln('Overlay Child PID:       ${mem.overlayProcessId}');
      buffer.writeln(
        'Overlay Working Set:     ${(mem.overlayRssBytes! / (1024 * 1024)).toStringAsFixed(2)} MB',
      );
      if (mem.overlayPrivateBytes != null) {
        buffer.writeln(
          'Overlay Private Commit:  ${(mem.overlayPrivateBytes! / (1024 * 1024)).toStringAsFixed(2)} MB',
        );
      }
    } else {
      buffer.writeln('Overlay Child Process:   Not running or not queryable');
    }
    buffer.writeln(
      'Dart Heap:               Not exposed by this runtime sampler',
    );
    buffer.writeln(
      'GPU/shared allocations:  Not exposed by GetProcessMemoryInfo',
    );
    buffer.writeln(
      'Image Cache Footprint:   ${mem.imageCacheMb.toStringAsFixed(2)} MB (${mem.imageCacheCount ?? 0} decoded images)',
    );
    buffer.writeln(
      'System Physical RAM:     ${mem.systemTotalPhysMb.toStringAsFixed(0)} MB total',
    );
    buffer.writeln(
      'System Available RAM:    ${mem.systemAvailPhysMb.toStringAsFixed(0)} MB free',
    );
    buffer.writeln('System Memory Load:      ${mem.systemMemoryLoadPercent}%');
    buffer.writeln('');
    buffer.writeln('--- 2. CPU UTILIZATION ---');
    buffer.writeln(
      'WallSync Process CPU:    ${cpu.processCpuPercent.toStringAsFixed(2)}%',
    );
    buffer.writeln(
      'System CPU Overall:      ${cpu.systemCpuPercent.toStringAsFixed(2)}%',
    );
    buffer.writeln('Measurement Interval:    ${cpu.sampleIntervalMs} ms');
    buffer.writeln('');
    buffer.writeln('--- 3. STORAGE & DISK FOOTPRINT ---');
    buffer.writeln(
      'WallSync Total Disk:     ${storage.totalMb.toStringAsFixed(2)} MB',
    );
    buffer.writeln(
      'AppData Folder:          ${storage.appDataMb.toStringAsFixed(2)} MB',
    );
    buffer.writeln(
      'LocalAppData Folder:     ${storage.localAppDataMb.toStringAsFixed(2)} MB',
    );
    buffer.writeln(
      'Video Wallpapers Cache:  ${storage.videoCacheMb.toStringAsFixed(2)} MB',
    );
    buffer.writeln(
      'Video Thumbnails Cache:  ${storage.thumbnailCacheMb.toStringAsFixed(2)} MB',
    );
    buffer.writeln(
      'Debug Log File:          ${storage.logFileMb.toStringAsFixed(2)} MB',
    );
    buffer.writeln('');
    buffer.writeln('--- 4. UI SMOOTHNESS & 60 FPS JANK METRICS ---');
    buffer.writeln('Total Frames Rendered:   ${smooth.totalFrames}');
    buffer.writeln(
      'Smoothness Score:        ${smooth.smoothnessPercentage.toStringAsFixed(1)}%',
    );
    buffer.writeln(
      'Measured Frames:         ${smooth.eligibleFrames} active; ${smooth.pipelineGapFrames} had >50ms non-work span; ${smooth.suspendedFrames} >1s timing gaps excluded',
    );
    buffer.writeln(
      'Average Stage Work:      ${smooth.averageFrameTimeMs.toStringAsFixed(2)} ms max(build,raster); build ${smooth.averageBuildTimeMs.toStringAsFixed(2)}ms, raster ${smooth.averageRasterTimeMs.toStringAsFixed(2)}ms',
    );
    buffer.writeln(
      'Average Total Span:      ${smooth.averageTotalSpanMs.toStringAsFixed(2)} ms (includes pipeline/vsync gaps)',
    );
    buffer.writeln(
      'Worst Active Compute:    ${smooth.worstFrameTimeMs.toStringAsFixed(2)} ms (UI Build: ${smooth.worstBuildTimeMs.toStringAsFixed(2)}ms, Raster: ${smooth.worstRasterTimeMs.toStringAsFixed(2)}ms)',
    );
    buffer.writeln('Jank Frames (>16.6ms):   ${smooth.jankFrames}');
    buffer.writeln('Severe Jank (>33.3ms):   ${smooth.severeJankFrames}');
    buffer.writeln(
      'Timing Gaps Excluded:    ${smooth.suspendedFrames} (cause not inferred from FrameTiming)',
    );
    buffer.writeln(
      'Jank Denominator:        ${smooth.eligibleFrames} eligible frames',
    );
    buffer.writeln('Recent Raw Frame Timings:');
    if (smooth.recentFrameSamples.isEmpty) {
      buffer.writeln('  No frame timing samples recorded.');
    } else {
      for (final sample in smooth.recentFrameSamples) {
        buffer.writeln('  $sample');
      }
    }
    buffer.writeln('');
    buffer.writeln('--- 5. RUNTIME STABILITY & HANG DETECTIONS ---');
    buffer.writeln('Recorded Hang Events:    ${_hangEvents.length}');
    if (_hangEvents.isEmpty) {
      buffer.writeln('No watchdog event-loop gaps (>1000ms) recorded.');
    } else {
      for (final event in _hangEvents) {
        buffer.writeln('  * $event');
      }
    }
    buffer.writeln('Currently Active Ops:    ${_activeOperations.length}');
    for (final op in _activeOperations.values) {
      final elapsed = DateTime.now().difference(op.startTime);
      buffer.writeln(
        '  - [${op.tag}] ${op.name} (running for ${elapsed.inMilliseconds}ms)',
      );
    }
    buffer.writeln(
      '================================================================',
    );

    return buffer.toString();
  }

  /// Saves the complete diagnostic review report to a text file.
  Future<File> saveReviewReportToFile([String? targetPath]) async {
    final report = await generateDiagnosticReport();
    final file = File(targetPath ?? 'review.txt');
    await file.writeAsString(report, flush: true);
    logInfo(
      'DiagnosticsService',
      'Diagnostic review report saved to: ${file.absolute.path}',
    );
    return file;
  }

  void dispose() {
    _periodicSamplerTimer?.cancel();
    _watchdogHeartbeatTimer?.cancel();
    for (final op in _activeOperations.values) {
      op.timeoutWarningTimer?.cancel();
    }
    _activeOperations.clear();
    _initialized = false;
  }
}
