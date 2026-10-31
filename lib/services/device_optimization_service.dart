import 'dart:async';
import 'dart:io';
import 'package:flutter/painting.dart';
import 'diagnostics_service.dart';
import 'settings_service.dart';
import 'system_optimizer_service.dart';

class OptimizationResult {
  final bool success;
  final double workingSetBeforeMb;
  final double workingSetAfterMb;
  final double workingSetFreedMb;
  final double privateBytesBeforeMb;
  final double privateBytesAfterMb;
  final double privateBytesFreedMb;
  final List<String> actionsTaken;
  final DateTime timestamp;

  const OptimizationResult({
    required this.success,
    required this.workingSetBeforeMb,
    required this.workingSetAfterMb,
    required this.workingSetFreedMb,
    this.privateBytesBeforeMb = 0.0,
    this.privateBytesAfterMb = 0.0,
    this.privateBytesFreedMb = 0.0,
    required this.actionsTaken,
    required this.timestamp,
  });

  // Backward-compatible aliases
  double get ramFreedMb => workingSetFreedMb;
  double get beforeWorkingSetMb => workingSetBeforeMb;
  double get afterWorkingSetMb => workingSetAfterMb;

  Map<String, dynamic> toJson() => {
        'success': success,
        'workingSetBeforeMb': workingSetBeforeMb,
        'workingSetAfterMb': workingSetAfterMb,
        'workingSetFreedMb': workingSetFreedMb,
        'privateBytesBeforeMb': privateBytesBeforeMb,
        'privateBytesAfterMb': privateBytesAfterMb,
        'privateBytesFreedMb': privateBytesFreedMb,
        'ramFreedMb': workingSetFreedMb,
        'beforeWorkingSetMb': workingSetBeforeMb,
        'afterWorkingSetMb': workingSetAfterMb,
        'actionsTaken': actionsTaken,
        'timestamp': timestamp.toIso8601String(),
      };

  factory OptimizationResult.fromJson(Map<String, dynamic> json) {
    final wsFreed = (json['workingSetFreedMb'] as num?)?.toDouble() ??
        (json['ramFreedMb'] as num?)?.toDouble() ??
        0.0;
    final beforeWs = (json['workingSetBeforeMb'] as num?)?.toDouble() ??
        (json['beforeWorkingSetMb'] as num?)?.toDouble() ??
        0.0;
    final afterWs = (json['workingSetAfterMb'] as num?)?.toDouble() ??
        (json['afterWorkingSetMb'] as num?)?.toDouble() ??
        0.0;
    return OptimizationResult(
      success: json['success'] as bool? ?? true,
      workingSetBeforeMb: beforeWs,
      workingSetAfterMb: afterWs,
      workingSetFreedMb: wsFreed,
      privateBytesBeforeMb:
          (json['privateBytesBeforeMb'] as num?)?.toDouble() ?? 0.0,
      privateBytesAfterMb:
          (json['privateBytesAfterMb'] as num?)?.toDouble() ?? 0.0,
      privateBytesFreedMb:
          (json['privateBytesFreedMb'] as num?)?.toDouble() ?? 0.0,
      actionsTaken: (json['actionsTaken'] as List?)
              ?.whereType<String>()
              .toList() ??
          const [],
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

class PerformanceProfileConfig {
  final String id;
  final String label;
  final String description;
  final int wallpaperFpsLimit;
  final int widgetRefreshIntervalMs;
  final bool pauseInactiveAnimations;
  final int imageCacheLimitMb;
  final bool lowPowerMode;
  final bool boostPriority;

  const PerformanceProfileConfig({
    required this.id,
    required this.label,
    required this.description,
    required this.wallpaperFpsLimit,
    required this.widgetRefreshIntervalMs,
    required this.pauseInactiveAnimations,
    required this.imageCacheLimitMb,
    required this.lowPowerMode,
    required this.boostPriority,
  });

  static const Map<String, PerformanceProfileConfig> profiles = {
    'balanced': PerformanceProfileConfig(
      id: 'balanced',
      label: 'Balanced',
      description:
          'Default balanced profile. 60 FPS, smart background pausing, and standard 24MB image cache for daily desktop use.',
      wallpaperFpsLimit: 60,
      widgetRefreshIntervalMs: 1000,
      pauseInactiveAnimations: true,
      imageCacheLimitMb: 24,
      lowPowerMode: false,
      boostPriority: false,
    ),
    'performance': PerformanceProfileConfig(
      id: 'performance',
      label: 'Performance',
      description:
          'Maximum responsiveness and high frame rate (120 FPS). Dynamically boosts process priority for zero UI stalls.',
      wallpaperFpsLimit: 120,
      widgetRefreshIntervalMs: 500,
      pauseInactiveAnimations: false,
      imageCacheLimitMb: 48,
      lowPowerMode: false,
      boostPriority: true,
    ),
    'power_saver': PerformanceProfileConfig(
      id: 'power_saver',
      label: 'Power Saver',
      description:
          'Toggles Windows 11 EcoQoS (Power Throttling), caps FPS to 30, and trims memory to maximize battery life.',
      wallpaperFpsLimit: 30,
      widgetRefreshIntervalMs: 2000,
      pauseInactiveAnimations: true,
      imageCacheLimitMb: 12,
      lowPowerMode: true,
      boostPriority: false,
    ),
    'high_quality': PerformanceProfileConfig(
      id: 'high_quality',
      label: 'High Quality',
      description:
          'Prioritizes supreme visual fidelity, unthrottled rendering, smooth animations, and ultra-fast 250ms widget updates.',
      wallpaperFpsLimit: 60,
      widgetRefreshIntervalMs: 250,
      pauseInactiveAnimations: false,
      imageCacheLimitMb: 64,
      lowPowerMode: false,
      boostPriority: false,
    ),
    'custom': PerformanceProfileConfig(
      id: 'custom',
      label: 'Custom',
      description:
          'Fully personalized configuration. Custom frame rates, image cache boundaries, animation triggers, and power options.',
      wallpaperFpsLimit: 60,
      widgetRefreshIntervalMs: 1000,
      pauseInactiveAnimations: true,
      imageCacheLimitMb: 32,
      lowPowerMode: false,
      boostPriority: false,
    ),
  };
}

class DeviceOptimizationService {
  static final DeviceOptimizationService instance =
      DeviceOptimizationService._();
  DeviceOptimizationService._();

  final SystemOptimizerService _optimizer = SystemOptimizerService.instance;
  Map<String, dynamic>? _lastPreOptimizationSnapshot;

  /// Applies a preset performance profile ('balanced', 'performance', 'power_saver', 'high_quality').
  Future<WidgetSettings> applyProfile({
    required String profileId,
    required WidgetSettings currentSettings,
    required SettingsService settingsService,
  }) async {
    final config = PerformanceProfileConfig.profiles[profileId];
    if (config == null) return currentSettings;

    // Apply Flutter image cache boundaries
    PaintingBinding.instance.imageCache.maximumSizeBytes =
        config.imageCacheLimitMb * 1024 * 1024;

    // Apply native power and priority modes
    if (config.lowPowerMode) {
      await _optimizer.setLowPowerMode(true);
    } else if (config.boostPriority) {
      await _optimizer.setLowPowerMode(false);
      await _optimizer.boostProcessPriority(true);
    } else {
      await _optimizer.setLowPowerMode(false);
      await _optimizer.boostProcessPriority(false);
    }

    final updated = await settingsService.updateSettings((c) => c.copyWith(
          performanceProfile: profileId,
          wallpaperFpsLimit: config.wallpaperFpsLimit,
          widgetRefreshIntervalMs: config.widgetRefreshIntervalMs,
          pauseInactiveAnimations: config.pauseInactiveAnimations,
          imageCacheLimitMb: config.imageCacheLimitMb,
        ));

    logInfo(
      'DeviceOptimizationService',
      'Applied performance profile: $profileId (FPS=${config.wallpaperFpsLimit}, Refresh=${config.widgetRefreshIntervalMs}ms, Cache=${config.imageCacheLimitMb}MB)',
    );
    return updated;
  }

  /// Executes full system optimization:
  /// 1. Flushes Flutter image caches.
  /// 2. Performs native Win32 working set trim (`EmptyWorkingSet` & `SetProcessWorkingSetSize`).
  /// 3. Compacts native heap (`HeapCompact`).
  /// 4. Trims background MPV and overlay child processes.
  /// 5. Measures exact before/after RAM consumption.
  /// 6. Records entry in optimization history.
  Future<OptimizationResult> optimizeOverallPerformance({
    required WidgetSettings currentSettings,
    required SettingsService settingsService,
  }) async {
    final actions = <String>[];

    // Snapshot before metrics
    double beforeWs = 0.0;
    double beforePrivate = 0.0;
    try {
      final diagMem = DiagnosticsService.instance.getMemorySnapshot();
      beforeWs = diagMem.processRssBytes / (1024.0 * 1024.0);
      beforePrivate = (diagMem.processPrivateBytes ?? 0) / (1024.0 * 1024.0);
      final metrics = await _optimizer.getPerformanceMetrics();
      if (metrics != null &&
          metrics.processWorkingSetMb != null &&
          metrics.processWorkingSetMb! > 0) {
        beforeWs = metrics.processWorkingSetMb! + (metrics.mpvWorkingSetMb ?? 0.0);
      }
    } catch (_) {}

    // Save pre-optimization settings state for undo
    _lastPreOptimizationSnapshot = {
      'performanceProfile': currentSettings.performanceProfile,
      'wallpaperFpsLimit': currentSettings.wallpaperFpsLimit,
      'widgetRefreshIntervalMs': currentSettings.widgetRefreshIntervalMs,
      'pauseInactiveAnimations': currentSettings.pauseInactiveAnimations,
      'imageCacheLimitMb': currentSettings.imageCacheLimitMb,
    };

    // Action 1: Clear Flutter image caches
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      actions.add('Flushed Flutter engine decoded image cache');
    } catch (_) {}

    // Action 2: Native memory trim and heap compaction
    try {
      final trimmed = await _optimizer.optimizeMemory(force: true);
      if (trimmed) {
        actions.add('Trimmed process working set and compacted native heap');
      }
    } catch (_) {}

    // Action 3: Multi-process overlay working set trim
    if (Platform.isWindows) {
      try {
        final processes = await _optimizer.getProcessList();
        int trimmedCount = 0;
        for (final p in processes) {
          if (p.isWallSync && !p.isCurrentProcess && p.pid > 0) {
            final ok = await _optimizer.trimProcessMemory(p.pid);
            if (ok) trimmedCount++;
          }
        }
        if (trimmedCount > 0) {
          actions.add(
              'Compacted working sets for $trimmedCount background overlay/MPV processes');
        }
      } catch (_) {}
    }

    // Action 4: Ensure EcoQoS if power saver profile is active
    if (currentSettings.performanceProfile == 'power_saver') {
      try {
        await _optimizer.setLowPowerMode(true);
        actions.add('Enforced Windows EcoQoS power throttling');
      } catch (_) {}
    }

    // Stabilization delay for Windows memory manager pages to settle
    await Future.delayed(const Duration(milliseconds: 300));

    // Measure post-optimization metrics
    double afterWs = 0.0;
    double afterPrivate = 0.0;
    try {
      final diagMem = DiagnosticsService.instance.getMemorySnapshot();
      afterWs = diagMem.processRssBytes / (1024.0 * 1024.0);
      afterPrivate = (diagMem.processPrivateBytes ?? 0) / (1024.0 * 1024.0);
      final metrics = await _optimizer.getPerformanceMetrics();
      if (metrics != null &&
          metrics.processWorkingSetMb != null &&
          metrics.processWorkingSetMb! > 0) {
        afterWs = metrics.processWorkingSetMb! + (metrics.mpvWorkingSetMb ?? 0.0);
      }
    } catch (_) {}

    final double wsFreed =
        beforeWs > afterWs ? (beforeWs - afterWs) : 0.0;
    final double privateFreed =
        beforePrivate > afterPrivate ? (beforePrivate - afterPrivate) : 0.0;

    final result = OptimizationResult(
      success: true,
      workingSetBeforeMb: beforeWs,
      workingSetAfterMb: afterWs > 0 ? afterWs : beforeWs,
      workingSetFreedMb: wsFreed,
      privateBytesBeforeMb: beforePrivate,
      privateBytesAfterMb: afterPrivate > 0 ? afterPrivate : beforePrivate,
      privateBytesFreedMb: privateFreed,
      actionsTaken: actions,
      timestamp: DateTime.now(),
    );

    // Record in persistent history
    final history =
        List<Map<String, dynamic>>.from(currentSettings.optimizationHistory);
    history.insert(0, result.toJson());
    if (history.length > 20) {
      history.removeRange(20, history.length);
    }
    await settingsService.updateSettings(
      (c) => c.copyWith(optimizationHistory: history),
    );

    logInfo(
      'DeviceOptimizationService',
      'Optimization complete. Freed ${result.ramFreedMb.toStringAsFixed(1)} MB RAM across ${actions.length} actions.',
    );
    return result;
  }

  /// Restores default Balanced profile settings.
  Future<WidgetSettings> restoreDefaults({
    required SettingsService settingsService,
  }) async {
    PaintingBinding.instance.imageCache.maximumSizeBytes = 24 * 1024 * 1024;
    PaintingBinding.instance.imageCache.maximumSize = 30;
    await _optimizer.setLowPowerMode(false);
    await _optimizer.boostProcessPriority(false);

    return await settingsService.updateSettings((c) => c.copyWith(
          performanceProfile: 'balanced',
          wallpaperFpsLimit: 60,
          widgetRefreshIntervalMs: 1000,
          pauseInactiveAnimations: true,
          imageCacheLimitMb: 24,
          autoSizing: true,
        ));
  }

  /// Undoes the last optimization settings configuration if a pre-optimization state is stored.
  Future<WidgetSettings?> undoLastOptimization({
    required WidgetSettings currentSettings,
    required SettingsService settingsService,
  }) async {
    final snapshot = _lastPreOptimizationSnapshot;
    if (snapshot == null) return null;

    final updated = await settingsService.updateSettings((c) => c.copyWith(
          performanceProfile: snapshot['performanceProfile'] as String?,
          wallpaperFpsLimit: snapshot['wallpaperFpsLimit'] as int?,
          widgetRefreshIntervalMs:
              snapshot['widgetRefreshIntervalMs'] as int?,
          pauseInactiveAnimations:
              snapshot['pauseInactiveAnimations'] as bool?,
          imageCacheLimitMb: snapshot['imageCacheLimitMb'] as int?,
        ));

    _lastPreOptimizationSnapshot = null;
    return updated;
  }
}

