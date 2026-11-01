import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'package:archive/archive.dart';
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

/// Per-widget memory usage breakdown for an individual active overlay process.
class WidgetOverlayMemorySnapshot {
  final String widgetId;
  final int pid;
  final int workingSetBytes;
  final int privateBytes;
  final int commitChargeBytes;

  const WidgetOverlayMemorySnapshot({
    required this.widgetId,
    required this.pid,
    required this.workingSetBytes,
    required this.privateBytes,
    this.commitChargeBytes = 0,
  });

  double get workingSetMb => workingSetBytes / (1024 * 1024);
  double get privateMb => privateBytes / (1024 * 1024);
  double get commitChargeMb => commitChargeBytes / (1024 * 1024);

  Map<String, dynamic> toMap() => {
    'widgetId': widgetId,
    'pid': pid,
    'workingSetMb': workingSetMb.toStringAsFixed(1),
    'privateMb': privateMb.toStringAsFixed(1),
    'commitChargeMb': commitChargeMb.toStringAsFixed(1),
  };
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
  final List<WidgetOverlayMemorySnapshot> overlayWidgets;
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
    this.overlayWidgets = const [],
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
    if (overlayWidgets.isNotEmpty)
      'overlayWidgets': overlayWidgets.map((w) => w.toMap()).toList(),
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
    final overlaySuffix = overlayRssBytes != null
        ? ' | Overlay (${overlayWidgets.length} active) RSS: ${(overlayRssBytes! / (1024 * 1024)).toStringAsFixed(1)} MB'
              '${overlayPrivateBytes == null ? '' : ' (Private ${(overlayPrivateBytes! / (1024 * 1024)).toStringAsFixed(1)} MB)'}'
              '${overlayWidgets.isNotEmpty ? ' [${overlayWidgets.map((w) => '${w.widgetId}(PID ${w.pid}): ${w.workingSetMb.toStringAsFixed(1)}MB RSS / ${w.privateMb.toStringAsFixed(1)}MB Priv').join(', ')}]' : ''}'
        : '';
    final trimNote = isWorkingSetTrimmed
        ? ' [Note: Windows kernel trimmed working set pages under system RAM pressure ($systemMemoryLoadPercent% load, ${systemAvailPhysMb.toStringAsFixed(0)} MB free)]'
        : '';
    return 'Sampled: ${sampledAt.toIso8601String()} | Process RSS: ${processRssMb.toStringAsFixed(1)} MB (Process Lifetime Peak RSS: ${processMaxRssMb.toStringAsFixed(1)} MB)$privateSuffix$mpvSuffix$overlaySuffix$trimNote | '
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
  final int presentationStallFrames;
  final double averageFrameTimeMs;
  final double averageTotalSpanMs;
  final double worstFrameTimeMs;
  final double averageBuildTimeMs;
  final double averageRasterTimeMs;
  final double worstBuildTimeMs;
  final double worstRasterTimeMs;
  final double worstPresentationDelayMs;
  final double averagePresentationDelayMs;
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
    this.presentationStallFrames = 0,
    required this.averageFrameTimeMs,
    this.averageTotalSpanMs = 0.0,
    required this.worstFrameTimeMs,
    this.averageBuildTimeMs = 0.0,
    this.averageRasterTimeMs = 0.0,
    this.worstBuildTimeMs = 0.0,
    this.worstRasterTimeMs = 0.0,
    this.worstPresentationDelayMs = 0.0,
    this.averagePresentationDelayMs = 0.0,
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
    'presentationStallFrames': presentationStallFrames,
    'averageFrameTimeMs': averageFrameTimeMs.toStringAsFixed(2),
    'averageTotalSpanMs': averageTotalSpanMs.toStringAsFixed(2),
    'worstFrameTimeMs': worstFrameTimeMs.toStringAsFixed(2),
    'averageBuildTimeMs': averageBuildTimeMs.toStringAsFixed(2),
    'averageRasterTimeMs': averageRasterTimeMs.toStringAsFixed(2),
    'worstBuildTimeMs': worstBuildTimeMs.toStringAsFixed(2),
    'worstRasterTimeMs': worstRasterTimeMs.toStringAsFixed(2),
    'worstPresentationDelayMs': worstPresentationDelayMs.toStringAsFixed(2),
    'averagePresentationDelayMs': averagePresentationDelayMs.toStringAsFixed(2),
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
      'DWM Stalls: $presentationStallFrames | '
      'P50: ${p50FrameTimeMs.toStringAsFixed(1)}ms | P90: ${p90FrameTimeMs.toStringAsFixed(1)}ms | P99: ${p99FrameTimeMs.toStringAsFixed(1)}ms | '
      'Avg Active: ${averageFrameTimeMs.toStringAsFixed(2)}ms (Build: ${averageBuildTimeMs.toStringAsFixed(2)}ms, Raster: ${averageRasterTimeMs.toStringAsFixed(2)}ms, Span: $averageTotalSpanSpanSafe) | '
      'Peak Active: ${worstFrameTimeMs.toStringAsFixed(2)}ms';

  String get averageTotalSpanSpanSafe => averageTotalSpanMs.toStringAsFixed(2);
}

/// Structured log entry for diagnostic telemetry history and export.
class DiagnosticLogEntry {
  final DateTime timestamp;
  final String severity; // 'INFO', 'WARN', 'ERROR', 'PERF'
  final String category; // 'General', 'Frame', 'Memory', 'Watchdog', 'Native'
  final String message;
  final double? processCpuPercent;
  final double? systemCpuPercent;
  final double? processRssMb;
  final double? processPrivateMb;
  final double? smoothnessPercent;

  const DiagnosticLogEntry({
    required this.timestamp,
    required this.severity,
    required this.category,
    required this.message,
    this.processCpuPercent,
    this.systemCpuPercent,
    this.processRssMb,
    this.processPrivateMb,
    this.smoothnessPercent,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'severity': severity,
    'category': category,
    'message': message,
    if (processCpuPercent != null) 'processCpuPercent': processCpuPercent,
    if (systemCpuPercent != null) 'systemCpuPercent': systemCpuPercent,
    if (processRssMb != null) 'processRssMb': processRssMb,
    if (processPrivateMb != null) 'processPrivateMb': processPrivateMb,
    if (smoothnessPercent != null) 'smoothnessPercent': smoothnessPercent,
  };
}

/// Active async operation tracker for detecting overloading & over-waiting.
class AsyncOperationRecord {
  final String id;
  final String tag;
  final String name;
  final DateTime startTime;
  final Stopwatch stopwatch;
  final Duration warningThreshold;
  Timer? timeoutWarningTimer;

  AsyncOperationRecord({
    required this.id,
    required this.tag,
    required this.name,
    required this.startTime,
    required this.stopwatch,
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
  int _presentationStallFrames = 0;
  double _totalFrameDurationMs = 0.0;
  double _worstFrameDurationMs = 0.0;
  double _totalBuildDurationMs = 0.0;
  double _totalRasterDurationMs = 0.0;
  double _totalFrameSpanMs = 0.0;
  double _worstBuildDurationMs = 0.0;
  double _worstRasterDurationMs = 0.0;
  double _totalPresentationDelayMs = 0.0;
  double _worstPresentationDelayMs = 0.0;
  final List<double> _recentFrameDurations = [];
  final List<String> _recentRawFrameSamples = [];
  final List<DiagnosticLogEntry> _historyEntries = [];
  bool _isWindowVisible = true;
  bool get isWindowVisible => _isWindowVisible;
  void setWindowVisible(bool visible) {
    _isWindowVisible = visible;
  }
  int? _overlayPid;
  List<int> _overlayPids = const [];
  Map<int, String> _overlayPidToWidgetId = const {};
  String _overlayProcessStatus = 'not-checked';
  DateTime? _overlayLaunchRequestedAt;

  void markOverlayLaunchRequested() {
    _overlayLaunchRequestedAt = DateTime.now();
    _overlayPid = null;
    _overlayPids = const [];
    _overlayPidToWidgetId = const {};
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

  // Watchdog hang detection (uses monotonic Stopwatch to avoid NTP / clock skew artifacts)
  final Stopwatch _watchdogStopwatch = Stopwatch();
  int _lastHeartbeatMs = 0;
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
    if (!_isWindowVisible) {
      _suspendedFrames++;
      return;
    }
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

    // Distinguish DXGI swapchain / DWM v-sync presentation throttle from active GPU rendering
    final isPresentationStall = rasterMs > 50.0 && buildMs < 3.0;
    if (isPresentationStall) {
      _presentationStallFrames++;
      _totalPresentationDelayMs += rasterMs;
      if (rasterMs > _worstPresentationDelayMs) {
        _worstPresentationDelayMs = rasterMs;
      }
    }

    _recentFrameDurations.add(activeMs);
    if (_recentFrameDurations.length > 120) _recentFrameDurations.removeAt(0);

    final isJank = activeMs > 16.66;
    final isSevereJank = activeMs > 33.33;
    if (isSevereJank) {
      _severeJankFrames++;
      _jankFrames++;
      recordHistoryEntry(
        severity: 'WARN',
        category: 'Frame',
        message: 'Severe frame active compute: ${activeMs.toStringAsFixed(1)}ms '
            '(UI: ${buildMs.toStringAsFixed(1)}ms, Raster: ${rasterMs.toStringAsFixed(1)}ms)',
        smoothness: _eligibleFrames > 0
            ? (((_eligibleFrames - _jankFrames) * 100.0) / _eligibleFrames)
            : 100.0,
      );
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
    _watchdogStopwatch.reset();
    _watchdogStopwatch.start();
    _lastHeartbeatMs = _watchdogStopwatch.elapsedMilliseconds;
    _watchdogHeartbeatTimer?.cancel();
    _watchdogHeartbeatTimer = Timer.periodic(_watchdogInterval, (_) {
      final nowMs = _watchdogStopwatch.elapsedMilliseconds;
      final elapsedMs = nowMs - _lastHeartbeatMs;
      _lastHeartbeatMs = nowMs;

      final hangMs = elapsedMs - _watchdogInterval.inMilliseconds;
      if (hangMs >= _hangThreshold.inMilliseconds) {
        final now = DateTime.now();
        final activeOperationDetails = _activeOperations.values
            .map(
              (operation) =>
                  '${operation.tag}.${operation.name}:'
                  '${operation.stopwatch.elapsedMilliseconds}ms',
            )
            .join(', ');
        final note =
            '[EVENT LOOP GAP] pid=$pid no watchdog heartbeat for '
            '$hangMs ms; this is event-loop delay / outside stages, '
            'not Flutter UI build time. OS/debugger cause is unverified. Active async ops: '
            '${_activeOperations.length}'
            '${activeOperationDetails.isEmpty ? '' : ' [$activeOperationDetails]'}';
        _hangEvents.add('[${now.toIso8601String()}] $note');
        recordHistoryEntry(
          severity: 'WARN',
          category: 'Watchdog',
          message: 'UI Event Loop Gap: ${hangMs}ms stall (${_activeOperations.length} active ops)',
        );
        logWarning('DiagnosticsService', note);
      }
    });
  }

  /// Public accessor to force immediate overlay PID and per-widget tracking refresh.
  Future<void> refreshOverlayPid() => _refreshOverlayPid();

  Future<void> _refreshOverlayPid() async {
    if (!Platform.isWindows) return;
    try {
      final appDir = await SettingsService().getAppDirectory();
      if (!await appDir.exists()) {
        _overlayPid = null;
        _overlayPids = const [];
        _overlayPidToWidgetId = const {};
        _overlayProcessStatus = 'pid-file-missing';
        return;
      }

      final pidFiles = <File>[];
      await for (final entity in appDir.list(followLinks: false)) {
        if (entity is File) {
          final name = entity.uri.pathSegments.isNotEmpty
              ? entity.uri.pathSegments.last.toLowerCase()
              : '';
          if (name.startsWith('overlay') && name.endsWith('.pid')) {
            pidFiles.add(entity);
          }
        }
      }

      if (pidFiles.isEmpty) {
        _overlayPid = null;
        _overlayPids = const [];
        _overlayPidToWidgetId = const {};
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

      final activePids = <int>[];
      final newPidToWidgetId = <int, String>{};
      for (final pidFile in pidFiles) {
        final fileName = pidFile.uri.pathSegments.isNotEmpty
            ? pidFile.uri.pathSegments.last.toLowerCase()
            : '';
        final String widgetId;
        if (fileName == 'overlay.pid') {
          widgetId = 'default';
        } else if (fileName.startsWith('overlay_') && fileName.endsWith('.pid')) {
          widgetId = fileName.substring(8, fileName.length - 4);
        } else {
          widgetId = 'unknown';
        }

        try {
          final content = (await pidFile.readAsString()).trim();
          final record = OverlayProcessRecord.tryParse(content);
          if (record != null) {
            final inspection = await inspectWindowsProcess(record.pid);
            if (inspection != null &&
                inspection.isRunning &&
                inspection.matches(record)) {
              if (record.ready) {
                activePids.add(record.pid);
                newPidToWidgetId[record.pid] = widgetId;
              }
              // Active process is alive and healthy/starting: NEVER delete PID file!
            } else {
              // The process has stopped or identity changed: clean up dead PID record
              try {
                if (await pidFile.exists()) await pidFile.delete();
              } catch (_) {}
            }
          } else {
            // Unparseable record: only remove if file is older than 10s to avoid race with writes
            try {
              final stat = await pidFile.stat();
              if (DateTime.now().difference(stat.modified) > const Duration(seconds: 10)) {
                if (await pidFile.exists()) await pidFile.delete();
              }
            } catch (_) {}
          }
        } catch (_) {}
      }

      _overlayPidToWidgetId = newPidToWidgetId;

      if (activePids.isNotEmpty) {
        _overlayLaunchRequestedAt = null;
        _overlayPids = activePids;
        _overlayPid = activePids.first;
        _overlayProcessStatus = activePids.length == 1
            ? 'running'
            : 'running (${activePids.length} active)';
      } else {
        _overlayPids = const [];
        _overlayPid = null;
        _overlayPidToWidgetId = const {};
        final launchRequestedAt = _overlayLaunchRequestedAt;
        if (launchRequestedAt != null &&
            DateTime.now().difference(launchRequestedAt) <
                const Duration(seconds: 30)) {
          _overlayProcessStatus = 'launch-requested';
        } else {
          _overlayLaunchRequestedAt = null;
          _overlayProcessStatus = 'stopped';
        }
      }
    } catch (error, stackTrace) {
      _overlayPid = null;
      _overlayPids = const [];
      _overlayPidToWidgetId = const {};
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
    final overlayWidgets = <WidgetOverlayMemorySnapshot>[];

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
      if (_overlayPids.isNotEmpty) {
        int totalOverlayRss = 0;
        int totalOverlayPrivate = 0;
        int totalOverlayCommit = 0;
        for (final p in _overlayPids) {
          final s = queryPid(p);
          if (s != null) {
            final wId = _overlayPidToWidgetId[p] ?? 'widget';
            overlayWidgets.add(
              WidgetOverlayMemorySnapshot(
                widgetId: wId,
                pid: p,
                workingSetBytes: s.workingSetBytes,
                privateBytes: s.privateBytes,
                commitChargeBytes: s.commitChargeBytes,
              ),
            );
            totalOverlayRss += s.workingSetBytes;
            totalOverlayPrivate += s.privateBytes;
            totalOverlayCommit += s.commitChargeBytes;
          }
        }
        overlayRss = totalOverlayRss > 0 ? totalOverlayRss : null;
        overlayPrivate = totalOverlayPrivate > 0 ? totalOverlayPrivate : null;
        overlayCommitCharge =
            totalOverlayCommit > 0 ? totalOverlayCommit : null;
      } else {
        final overlaySample = queryPid(overlayPid);
        if (overlaySample != null) {
          final wId = _overlayPidToWidgetId[overlayPid] ?? 'default';
          overlayWidgets.add(
            WidgetOverlayMemorySnapshot(
              widgetId: wId,
              pid: overlayPid!,
              workingSetBytes: overlaySample.workingSetBytes,
              privateBytes: overlaySample.privateBytes,
              commitChargeBytes: overlaySample.commitChargeBytes,
            ),
          );
          overlayRss = overlaySample.workingSetBytes;
          overlayPrivate = overlaySample.privateBytes;
          overlayCommitCharge = overlaySample.commitChargeBytes;
        }
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
      overlayWidgets: overlayWidgets,
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

    final double avgPres = _presentationStallFrames > 0
        ? (_totalPresentationDelayMs / _presentationStallFrames)
        : 0.0;

    return SmoothnessSnapshot(
      totalFrames: _totalFrames,
      jankFrames: _jankFrames,
      severeJankFrames: _severeJankFrames,
      suspendedFrames: _suspendedFrames,
      eligibleFrames: _eligibleFrames,
      pipelineGapFrames: _pipelineGapFrames,
      presentationStallFrames: _presentationStallFrames,
      averageFrameTimeMs: avg,
      averageTotalSpanMs: avgSpan,
      worstFrameTimeMs: _worstFrameDurationMs,
      averageBuildTimeMs: avgBuild,
      averageRasterTimeMs: avgRaster,
      worstBuildTimeMs: _worstBuildDurationMs,
      worstRasterTimeMs: _worstRasterDurationMs,
      worstPresentationDelayMs: _worstPresentationDelayMs,
      averagePresentationDelayMs: avgPres,
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
    _presentationStallFrames = 0;
    _totalFrameDurationMs = 0.0;
    _worstFrameDurationMs = 0.0;
    _totalBuildDurationMs = 0.0;
    _totalRasterDurationMs = 0.0;
    _totalFrameSpanMs = 0.0;
    _worstBuildDurationMs = 0.0;
    _worstRasterDurationMs = 0.0;
    _totalPresentationDelayMs = 0.0;
    _worstPresentationDelayMs = 0.0;
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
    final stopwatch = Stopwatch()..start();

    final record = AsyncOperationRecord(
      id: opId,
      tag: tag,
      name: name,
      startTime: startTime,
      stopwatch: stopwatch,
      warningThreshold: warningThreshold,
    );
    final timelineTask = developer.TimelineTask()
      ..start('WallSync $tag.$name', arguments: {'operationId': opId});

    // Schedule over-wait warning timer
    record.timeoutWarningTimer = Timer(warningThreshold, () {
      if (_activeOperations.containsKey(opId)) {
        final elapsedMs = stopwatch.elapsedMilliseconds;
        logWarning(
          tag,
          '[OVERWAIT WARNING] Operation "$name" is still running after $elapsedMs ms! '
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
      final durationMs = stopwatch.elapsedMilliseconds;
      record.timeoutWarningTimer?.cancel();
      _activeOperations.remove(opId);

      if (durationMs > warningThreshold.inMilliseconds) {
        logInfo(
          tag,
          '[SLOW OPERATION RESOLVED] "$name" completed in $durationMs ms',
        );
      } else {
        logDebug(
          tag,
          '[OP COMPLETED] "$name" in $durationMs ms',
        );
      }
      timelineTask.finish(
        arguments: {'durationMs': durationMs, 'success': true},
      );
      return result;
    } catch (e, st) {
      final durationMs = stopwatch.elapsedMilliseconds;
      record.timeoutWarningTimer?.cancel();
      _activeOperations.remove(opId);
      logError(
        tag,
        '[OP FAILED] "$name" failed after $durationMs ms: $e',
        e,
        st,
      );
      timelineTask.finish(
        arguments: {'durationMs': durationMs, 'success': false},
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
      recordHistoryEntry(
        severity: 'INFO',
        category: 'Telemetry',
        message:
            'RAM: ${mem.processRssMb.toStringAsFixed(1)}MB, CPU: ${cpu.processCpuPercent.toStringAsFixed(1)}%, Smooth: ${smooth.smoothnessPercentage.toStringAsFixed(1)}%',
        cpuPercent: cpu.processCpuPercent,
        sysCpuPercent: cpu.systemCpuPercent,
        rssMb: mem.processRssMb,
        privateMb: mem.processPrivateMb,
        smoothness: smooth.smoothnessPercentage,
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
      if (mem.overlayWidgets.isNotEmpty) {
        buffer.writeln('Overlay Active Instances:${mem.overlayWidgets.length} processes');
        for (final w in mem.overlayWidgets) {
          buffer.writeln(
            '  * [${w.widgetId}] PID ${w.pid}: Working Set ${w.workingSetMb.toStringAsFixed(1)} MB | Private Commit ${w.privateMb.toStringAsFixed(1)} MB',
          );
        }
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
    if (smooth.presentationStallFrames > 0) {
      buffer.writeln(
        'DWM Presentation Stalls: ${smooth.presentationStallFrames} frames '
        '(worst delay: ${smooth.worstPresentationDelayMs.toStringAsFixed(1)} ms; '
        'avg: ${smooth.averagePresentationDelayMs.toStringAsFixed(1)} ms)',
      );
    }
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

  void recordHistoryEntry({
    required String severity,
    required String category,
    required String message,
    double? cpuPercent,
    double? sysCpuPercent,
    double? rssMb,
    double? privateMb,
    double? smoothness,
  }) {
    final entry = DiagnosticLogEntry(
      timestamp: DateTime.now(),
      severity: severity,
      category: category,
      message: message,
      processCpuPercent: cpuPercent,
      systemCpuPercent: sysCpuPercent,
      processRssMb: rssMb,
      processPrivateMb: privateMb,
      smoothnessPercent: smoothness,
    );
    _historyEntries.add(entry);
    if (_historyEntries.length > 500) {
      _historyEntries.removeAt(0);
    }
  }

  /// Records a structured diagnostic event for the main application window lifecycle.
  void recordWindowEvent(
    String event, {
    String? reason,
    Map<String, dynamic>? details,
  }) {
    final detailStr = (details != null && details.isNotEmpty)
        ? ' | details=$details'
        : '';
    final reasonStr = reason != null ? ' | reason=$reason' : '';
    final message = 'MainWindow event=$event$reasonStr$detailStr';
    recordHistoryEntry(
      severity: 'INFO',
      category: 'MainWindow',
      message: message,
    );
    logInfo('MainWindow', message);
  }

  /// Records a structured diagnostic event for the system tray lifecycle.
  void recordTrayEvent(
    String event, {
    String? stage,
    String? error,
    Map<String, dynamic>? details,
  }) {
    final stageStr = stage != null ? ' | stage=$stage' : '';
    final errorStr = error != null ? ' | error=$error' : '';
    final detailStr = (details != null && details.isNotEmpty)
        ? ' | details=$details'
        : '';
    final message = 'SystemTray event=$event$stageStr$errorStr$detailStr';
    final severity = error != null ? 'WARN' : 'INFO';
    recordHistoryEntry(
      severity: severity,
      category: 'SystemTray',
      message: message,
    );
    if (error != null) {
      logWarning('SystemTray', message);
    } else {
      logInfo('SystemTray', message);
    }
  }

  /// Records a structured diagnostic event for widget and overlay process lifecycles.
  void recordWidgetLifecycleEvent(
    String widgetId,
    String stage, {
    int? pid,
    int? exitCode,
    int? hwnd,
    String? executable,
    List<String>? args,
    String? workingDirectory,
    String? pidFilePath,
    bool? pidFileCreated,
    String? ipcStatus,
    String? timeoutReason,
    String? details,
  }) {
    final pidStr = pid != null ? ' | pid=$pid' : '';
    final exitStr = exitCode != null ? ' | exitCode=$exitCode' : '';
    final hwndStr = hwnd != null ? ' | hwnd=0x${hwnd.toRadixString(16)}' : '';
    final exeStr = executable != null ? ' | exe="$executable"' : '';
    final argsStr = (args != null && args.isNotEmpty) ? ' | args=$args' : '';
    final workDirStr = workingDirectory != null ? ' | workDir="$workingDirectory"' : '';
    final pidFileStr = pidFilePath != null ? ' | pidFile="$pidFilePath"' : '';
    final pidCreatedStr = pidFileCreated != null ? ' | pidCreated=$pidFileCreated' : '';
    final ipcStr = ipcStatus != null ? ' | ipcStatus=$ipcStatus' : '';
    final timeoutStr = timeoutReason != null ? ' | timeoutReason="$timeoutReason"' : '';
    final detailStr = details != null ? ' | details=$details' : '';
    final message =
        'WidgetLifecycle widget="$widgetId" | stage=$stage$pidStr$exitStr$hwndStr$exeStr$argsStr$workDirStr$pidFileStr$pidCreatedStr$ipcStr$timeoutStr$detailStr';
    final isFailure = stage == 'failed' || stage == 'exited' || (exitCode != null && exitCode != 0);
    recordHistoryEntry(
      severity: isFailure ? 'WARN' : 'INFO',
      category: 'WidgetLifecycle',
      message: message,
    );
    if (isFailure) {
      logWarning('WidgetLifecycle', message);
    } else {
      logInfo('WidgetLifecycle', message);
    }
  }

  List<DiagnosticLogEntry> getHistoryEntries({
    Duration? timeRange,
    String? severity,
    String? category,
  }) {
    final now = DateTime.now();
    return _historyEntries.where((entry) {
      if (timeRange != null && now.difference(entry.timestamp) > timeRange) {
        return false;
      }
      if (severity != null &&
          severity.toUpperCase() != 'ALL' &&
          entry.severity.toUpperCase() != severity.toUpperCase()) {
        return false;
      }
      if (category != null &&
          category.toLowerCase() != 'all' &&
          entry.category.toLowerCase() != category.toLowerCase()) {
        return false;
      }
      return true;
    }).toList();
  }

  void clearHistoryEntries() {
    _historyEntries.clear();
  }

  /// Returns the canonical directory for all exported reports and support bundles.
  Future<Directory> getExportDirectory() async {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final appData =
        Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    final basePath = localAppData != null
        ? '$localAppData\\WallSync\\exports'
        : '$appData\\com.example\\wallsync\\exports';
    final dir = Directory(basePath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Generates the standard ASCII text diagnostic report.
  Future<String> generateTxtReport() => generateDiagnosticReport();

  /// Exports standard TXT report to the exports directory.
  Future<File> exportTxtReport([String? fileName]) async {
    final report = await generateTxtReport();
    final exportDir = await getExportDirectory();
    final name = fileName ??
        'WallSync_Report_${DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '_')}.txt';
    final file = File('${exportDir.path}\\$name');
    await file.writeAsString(report, flush: true);
    logInfo('DiagnosticsService', 'Exported TXT report: ${file.path}');
    return file;
  }

  /// Generates an extended comprehensive diagnostic trace report.
  Future<String> generateDetailedReport() async {
    final standard = await generateDiagnosticReport();
    final smooth = getSmoothnessSnapshot();

    final buffer = StringBuffer(standard);
    buffer.writeln('');
    buffer.writeln(
      '================================================================',
    );
    buffer.writeln(
      '               DETAILED DIAGNOSTIC TRACE & LOGS                 ',
    );
    buffer.writeln(
      '================================================================',
    );
    buffer.writeln(
      'Execution Mode:        ${kReleaseMode ? "Release" : (kProfileMode ? "Profile" : "Debug")}',
    );
    buffer.writeln(
      'Flutter Impeller / D3D: Active OpenGLESSDF / DXGI swapchain',
    );
    buffer.writeln('Window Visibility:     $_isWindowVisible');
    buffer.writeln(
      'Overlay Child PIDs:    ${_overlayPids.isEmpty ? "None" : _overlayPids.join(", ")}',
    );
    buffer.writeln('Overlay Status:        $_overlayProcessStatus');
    buffer.writeln(
      'DWM V-Sync Stalls:     ${smooth.presentationStallFrames} frames',
    );
    buffer.writeln(
      'Worst DWM Delay:       ${smooth.worstPresentationDelayMs.toStringAsFixed(2)} ms',
    );
    buffer.writeln(
      'Avg DWM Delay:         ${smooth.averagePresentationDelayMs.toStringAsFixed(2)} ms',
    );
    buffer.writeln(
      'Percentiles:           P50: ${smooth.p50FrameTimeMs.toStringAsFixed(1)}ms | P90: ${smooth.p90FrameTimeMs.toStringAsFixed(1)}ms | P99: ${smooth.p99FrameTimeMs.toStringAsFixed(1)}ms',
    );
    buffer.writeln('');
    buffer.writeln('--- ACTIVE ASYNC TASKS (${_activeOperations.length}) ---');
    if (_activeOperations.isEmpty) {
      buffer.writeln(
        '  No asynchronous operations currently blocking or waiting.',
      );
    } else {
      for (final op in _activeOperations.values) {
        buffer.writeln(
          '  * [${op.tag}] ${op.name} (elapsed: ${op.stopwatch.elapsedMilliseconds}ms, threshold: ${op.warningThreshold.inMilliseconds}ms)',
        );
      }
    }
    buffer.writeln('');
    buffer.writeln('--- TELEMETRY LOG ENTRIES (${_historyEntries.length}) ---');
    if (_historyEntries.isEmpty) {
      buffer.writeln(
        '  No telemetry entries recorded during current isolate session.',
      );
    } else {
      for (final e in _historyEntries) {
        buffer.writeln(
          '  [${e.timestamp.toIso8601String()}] [${e.severity}] [${e.category}] ${e.message}',
        );
      }
    }
    buffer.writeln(
      '================================================================',
    );
    return buffer.toString();
  }

  /// Exports detailed trace report to the exports directory.
  Future<File> exportDetailedReport([String? fileName]) async {
    final report = await generateDetailedReport();
    final exportDir = await getExportDirectory();
    final name = fileName ??
        'WallSync_Detailed_Trace_${DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '_')}.txt';
    final file = File('${exportDir.path}\\$name');
    await file.writeAsString(report, flush: true);
    logInfo('DiagnosticsService', 'Exported detailed trace: ${file.path}');
    return file;
  }

  /// Generates time-series CSV metrics.
  Future<String> generateCsvData() async {
    final buffer = StringBuffer();
    buffer.writeln(
      'Timestamp,ProcessCpuPercent,SystemCpuPercent,WorkingSetMb,PrivateCommitMb,SmoothnessPercent,JankFrames,AvgFrameTimeMs,ActiveOperations,Severity,Category,Message',
    );
    if (_historyEntries.isEmpty) {
      final mem = getMemorySnapshot();
      final cpu = getCpuSnapshot();
      final smooth = getSmoothnessSnapshot();
      buffer.writeln(
        '${DateTime.now().toIso8601String()},'
        '${cpu.processCpuPercent.toStringAsFixed(2)},'
        '${cpu.systemCpuPercent.toStringAsFixed(2)},'
        '${mem.processRssMb.toStringAsFixed(2)},'
        '${mem.processPrivateMb?.toStringAsFixed(2) ?? ""},'
        '${smooth.smoothnessPercentage.toStringAsFixed(1)},'
        '${smooth.jankFrames},'
        '${smooth.averageFrameTimeMs.toStringAsFixed(2)},'
        '${_activeOperations.length},'
        'INFO,Snapshot,Current system state',
      );
    } else {
      for (final e in _historyEntries) {
        final safeMsg = e.message.replaceAll('"', '""');
        buffer.writeln(
          '${e.timestamp.toIso8601String()},'
          '${e.processCpuPercent?.toStringAsFixed(2) ?? ""},'
          '${e.systemCpuPercent?.toStringAsFixed(2) ?? ""},'
          '${e.processRssMb?.toStringAsFixed(2) ?? ""},'
          '${e.processPrivateMb?.toStringAsFixed(2) ?? ""},'
          '${e.smoothnessPercent?.toStringAsFixed(1) ?? ""},'
          '$_jankFrames,'
          '${_eligibleFrames > 0 ? (_totalFrameDurationMs / _eligibleFrames).toStringAsFixed(2) : ""},'
          '${_activeOperations.length},'
          '${e.severity},'
          '${e.category},'
          '"$safeMsg"',
        );
      }
    }
    return buffer.toString();
  }

  /// Exports time-series CSV file to the exports directory.
  Future<File> exportCsvFile([String? fileName]) async {
    final csv = await generateCsvData();
    final exportDir = await getExportDirectory();
    final name = fileName ??
        'WallSync_Metrics_${DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '_')}.csv';
    final file = File('${exportDir.path}\\$name');
    await file.writeAsString(csv, flush: true);
    logInfo('DiagnosticsService', 'Exported CSV metrics: ${file.path}');
    return file;
  }

  /// Generates machine-readable structured JSON report with schema version.
  Future<String> generateJsonReport() async {
    final mem = getMemorySnapshot();
    final cpu = getCpuSnapshot();
    final smooth = getSmoothnessSnapshot();
    final storage = await getStorageSnapshot();

    final data = {
      '\$schema': 'https://wallsync.app/schemas/diagnostics-v2.json',
      'schemaVersion': '2.0.0',
      'generatedAt': DateTime.now().toIso8601String(),
      'sessionStartedAt': _diagnosticsSessionStartedAt.toIso8601String(),
      'system': {
        'platform': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'dartVersion': Platform.version,
        'logicalCores': Platform.numberOfProcessors,
        'processId': pid,
      },
      'memory': {
        'processWorkingSetMb': mem.processRssMb,
        'processPeakWorkingSetMb': mem.processMaxRssMb,
        'processPrivateCommitMb': mem.processPrivateMb,
        'processCommitChargeMb': mem.processCommitChargeMb,
        'sessionPeakWorkingSetMb': mem.processSessionPeakRssBytes == null
            ? null
            : mem.processSessionPeakRssBytes! / (1024 * 1024),
        'sessionPeakPrivateMb': mem.processSessionPeakPrivateBytes == null
            ? null
            : mem.processSessionPeakPrivateBytes! / (1024 * 1024),
        'imageCacheMb': mem.imageCacheMb,
        'imageCacheCount': mem.imageCacheCount,
        'systemTotalPhysMb': mem.systemTotalPhysMb,
        'systemAvailPhysMb': mem.systemAvailPhysMb,
        'systemMemoryLoadPercent': mem.systemMemoryLoadPercent,
        'mpvPid': mem.mpvProcessId,
        'mpvWorkingSetMb': mem.mpvProcessId == null ? null : mem.mpvRssMb,
        'mpvPrivateCommitMb': mem.mpvPrivateMb,
        'overlayPid': mem.overlayProcessId,
        'overlayWorkingSetMb': mem.overlayRssBytes == null
            ? null
            : mem.overlayRssBytes! / (1024 * 1024),
        'overlayPrivateCommitMb': mem.overlayPrivateBytes == null
            ? null
            : mem.overlayPrivateBytes! / (1024 * 1024),
        'overlayStatus': mem.overlayProcessStatus,
        'overlayWidgets': mem.overlayWidgets.map((w) => w.toMap()).toList(),
      },
      'cpu': {
        'processCpuPercent': cpu.processCpuPercent,
        'systemCpuPercent': cpu.systemCpuPercent,
        'sampleIntervalMs': cpu.sampleIntervalMs,
      },
      'rendering': {
        'totalFrames': smooth.totalFrames,
        'eligibleFrames': smooth.eligibleFrames,
        'jankFrames': smooth.jankFrames,
        'severeJankFrames': smooth.severeJankFrames,
        'suspendedFrames': smooth.suspendedFrames,
        'pipelineGapFrames': smooth.pipelineGapFrames,
        'presentationStallFrames': smooth.presentationStallFrames,
        'smoothnessPercent': smooth.smoothnessPercentage,
        'rollingSmoothnessPercent': smooth.rollingSmoothnessPercentage,
        'averageFrameTimeMs': smooth.averageFrameTimeMs,
        'averageBuildTimeMs': smooth.averageBuildTimeMs,
        'averageRasterTimeMs': smooth.averageRasterTimeMs,
        'averageTotalSpanMs': smooth.averageTotalSpanMs,
        'worstFrameTimeMs': smooth.worstFrameTimeMs,
        'worstBuildTimeMs': smooth.worstBuildTimeMs,
        'worstRasterTimeMs': smooth.worstRasterTimeMs,
        'worstPresentationDelayMs': smooth.worstPresentationDelayMs,
        'p50FrameTimeMs': smooth.p50FrameTimeMs,
        'p90FrameTimeMs': smooth.p90FrameTimeMs,
        'p99FrameTimeMs': smooth.p99FrameTimeMs,
        'recentRawSamples': smooth.recentFrameSamples,
      },
      'storage': {
        'totalMb': storage.totalMb,
        'appDataMb': storage.appDataMb,
        'localAppDataMb': storage.localAppDataMb,
        'videoCacheMb': storage.videoCacheMb,
        'thumbnailCacheMb': storage.thumbnailCacheMb,
        'logFileMb': storage.logFileMb,
      },
      'watchdog': {
        'hangEvents': _hangEvents,
        'activeOperations': _activeOperations.values
            .map(
              (op) => {
                'tag': op.tag,
                'name': op.name,
                'runningMs': op.stopwatch.elapsedMilliseconds,
              },
            )
            .toList(),
      },
      'history': _historyEntries.map((e) => e.toJson()).toList(),
    };

    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// Exports structured JSON file to the exports directory.
  Future<File> exportJsonFile([String? fileName]) async {
    final json = await generateJsonReport();
    final exportDir = await getExportDirectory();
    final name = fileName ??
        'WallSync_Diagnostics_${DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '_')}.json';
    final file = File('${exportDir.path}\\$name');
    await file.writeAsString(json, flush: true);
    logInfo('DiagnosticsService', 'Exported JSON diagnostics: ${file.path}');
    return file;
  }

  /// Returns a concise single-block summary for clipboard copy.
  String generateSummaryText() {
    final mem = getMemorySnapshot();
    final cpu = getCpuSnapshot();
    final smooth = getSmoothnessSnapshot();

    final buffer = StringBuffer();
    buffer.writeln('WallSync Pro Diagnostic Summary');
    buffer.writeln(
      '• Memory: ${mem.processRssMb.toStringAsFixed(1)} MB Working Set'
      '${mem.processPrivateMb != null ? ' | ${mem.processPrivateMb!.toStringAsFixed(1)} MB Private Commit' : ''}',
    );
    buffer.writeln(
      '• CPU: ${cpu.processCpuPercent.toStringAsFixed(1)}% App | ${cpu.systemCpuPercent.toStringAsFixed(1)}% System',
    );
    buffer.writeln(
      '• Rendering: ${smooth.smoothnessPercentage.toStringAsFixed(1)}% Smoothness '
      '(${smooth.jankFrames}/${smooth.eligibleFrames} jank frames; worst: ${smooth.worstFrameTimeMs.toStringAsFixed(1)} ms)',
    );
    if (smooth.presentationStallFrames > 0) {
      buffer.writeln(
        '• DWM / V-Sync Stalls: ${smooth.presentationStallFrames} frames (worst: ${smooth.worstPresentationDelayMs.toStringAsFixed(1)} ms)',
      );
    }
    buffer.writeln(
      '• Overlays: ${mem.overlayProcessStatus} | MPV: ${mem.mpvProcessId != null ? 'PID ${mem.mpvProcessId}' : 'Inactive'}',
    );
    buffer.writeln(
      '• Stability: ${_hangEvents.isEmpty ? 'Optimal (0 watchdog hangs)' : '${_hangEvents.length} event-loop stalls recorded'}',
    );
    buffer.writeln('• Active Operations: ${_activeOperations.length} in flight');
    return buffer.toString().trim();
  }

  /// Generates a complete ZIP support package containing TXT, CSV, JSON, and logs.
  Future<File> generateSupportPackageZip([String? fileName]) async {
    final exportDir = await getExportDirectory();
    final name = fileName ??
        'WallSync_Support_Package_${DateTime.now().toIso8601String().replaceAll(':', '-').replaceAll('.', '_')}.zip';
    final zipFile = File('${exportDir.path}\\$name');

    final txtReport = await generateDiagnosticReport();
    final detailedReport = await generateDetailedReport();
    final csvData = await generateCsvData();
    final jsonReport = await generateJsonReport();
    final summaryText = generateSummaryText();

    final archive = Archive();
    archive.addFile(ArchiveFile.string('report.txt', txtReport));
    archive.addFile(ArchiveFile.string('detailed_trace.txt', detailedReport));
    archive.addFile(ArchiveFile.string('metrics.csv', csvData));
    archive.addFile(ArchiveFile.string('diagnostics.json', jsonReport));
    archive.addFile(ArchiveFile.string('summary.txt', summaryText));

    // Include recent application log if exists and readable
    try {
      final appData =
          Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
      final logFile = File('$appData\\com.example\\wallsync\\app_debug.log');
      if (await logFile.exists()) {
        final logBytes = await logFile.readAsBytes();
        if (logBytes.length > 5 * 1024 * 1024) {
          final trimmed = logBytes.sublist(logBytes.length - 2 * 1024 * 1024);
          archive.addFile(ArchiveFile('app_debug.log', trimmed.length, trimmed));
        } else {
          archive.addFile(
            ArchiveFile('app_debug.log', logBytes.length, logBytes),
          );
        }
      }
    } catch (_) {}

    final zipBytes = ZipEncoder().encode(archive);
    await zipFile.writeAsBytes(zipBytes, flush: true);
    logInfo('DiagnosticsService', 'Support package created: ${zipFile.path}');
    return zipFile;
  }

  /// Launches Windows Explorer showing the export directory.
  Future<void> openExportFolder() async {
    final dir = await getExportDirectory();
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [dir.path]);
    }
  }

  /// Clears in-memory diagnostics metrics, history entries, and rotates log files.
  Future<void> clearDiagnostics() async {
    resetSmoothnessMetrics();
    clearHistoryEntries();
    _hangEvents.clear();
    try {
      final appData =
          Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
      final logFile = File('$appData\\com.example\\wallsync\\app_debug.log');
      if (await logFile.exists()) {
        final oldBackup = File('$appData\\com.example\\wallsync\\app_debug.old');
        if (await oldBackup.exists()) {
          try {
            await oldBackup.delete();
          } catch (_) {}
        }
        try {
          await logFile.rename(oldBackup.path);
        } catch (_) {}
        await logFile.writeAsString('', flush: true);
      }
    } catch (_) {}
    logInfo('DiagnosticsService', 'All diagnostics and metric histories cleared.');
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
