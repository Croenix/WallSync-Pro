import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'settings_service.dart';

class NativePerformanceMetrics {
  const NativePerformanceMetrics({
    this.cpuPercent,
    this.ramLoadPercent,
    this.totalPhysMb,
    this.availPhysMb,
    this.processWorkingSetMb,
    this.processPrivateBytesMb,
    this.batteryPercent,
    this.isAcConnected,
    this.isCharging,
  });

  final double? cpuPercent;
  final double? ramLoadPercent;
  final double? totalPhysMb;
  final double? availPhysMb;
  final double? processWorkingSetMb;
  final double? processPrivateBytesMb;
  final int? batteryPercent;
  final bool? isAcConnected;
  final bool? isCharging;

  factory NativePerformanceMetrics.fromMap(Map<Object?, Object?> map) {
    return NativePerformanceMetrics(
      cpuPercent: (map['cpuPercent'] as num?)?.toDouble(),
      ramLoadPercent: (map['ramLoadPercent'] as num?)?.toDouble(),
      totalPhysMb: (map['totalPhysMb'] as num?)?.toDouble(),
      availPhysMb: (map['availPhysMb'] as num?)?.toDouble(),
      processWorkingSetMb: (map['processWorkingSetMb'] as num?)?.toDouble(),
      processPrivateBytesMb: (map['processPrivateBytesMb'] as num?)?.toDouble(),
      batteryPercent: map['batteryPercent'] as int?,
      isAcConnected: map['isAcConnected'] as bool?,
      isCharging: map['isCharging'] as bool?,
    );
  }
}

class NativeGpuAndDisplayInfo {
  const NativeGpuAndDisplayInfo({
    this.gpuName,
    this.dedicatedVramMb,
    this.sharedVramMb,
    this.screenWidth,
    this.screenHeight,
    this.workAreaWidth,
    this.workAreaHeight,
    this.refreshRateHz,
  });

  final String? gpuName;
  final double? dedicatedVramMb;
  final double? sharedVramMb;
  final int? screenWidth;
  final int? screenHeight;
  final int? workAreaWidth;
  final int? workAreaHeight;
  final int? refreshRateHz;

  factory NativeGpuAndDisplayInfo.fromMap(Map<Object?, Object?> map) {
    return NativeGpuAndDisplayInfo(
      gpuName: map['gpuName'] as String?,
      dedicatedVramMb: (map['dedicatedVramMb'] as num?)?.toDouble(),
      sharedVramMb: (map['sharedVramMb'] as num?)?.toDouble(),
      screenWidth: map['screenWidth'] as int?,
      screenHeight: map['screenHeight'] as int?,
      workAreaWidth: map['workAreaWidth'] as int?,
      workAreaHeight: map['workAreaHeight'] as int?,
      refreshRateHz: map['refreshRateHz'] as int?,
    );
  }
}

class SystemOptimizerService {
  static final SystemOptimizerService instance = SystemOptimizerService._();
  SystemOptimizerService._();

  static const MethodChannel _channel = MethodChannel('wallsync/live_wallpaper');

  Timer? _idleOptimizerTimer;
  bool _isLowPowerModeActive = false;

  bool get isLowPowerModeActive => _isLowPowerModeActive;

  /// Commands Windows to flush the process working set (`SetProcessWorkingSetSize` and `EmptyWorkingSet`).
  /// Reclaims unused virtual memory pages across WallSync Pro and background MPV video instances.
  Future<bool> optimizeMemory() async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('optimizeMemory');
      logInfo('SystemOptimizerService', 'Native process memory trimmed successfully.');
      return res ?? false;
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native optimizeMemory call failed: $e');
      return false;
    }
  }

  /// Sets below-normal process priority and toggles Windows 11 EcoQoS (Power Throttling).
  /// Enables maximum CPU responsiveness for foreground user applications and games.
  Future<bool> setLowPowerMode(bool enable) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('setLowPowerMode', {'enable': enable});
      _isLowPowerModeActive = enable;
      logInfo('SystemOptimizerService', 'Native power mode updated: lowPower=$enable (EcoQoS enabled).');
      return res ?? false;
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native setLowPowerMode call failed: $e');
      return false;
    }
  }

  /// Gathers real-time performance metrics directly from the Windows kernel (CPU, RAM, working set, battery)
  /// with zero Dart FFI heap allocations or garbage collection churn.
  Future<NativePerformanceMetrics?> getPerformanceMetrics() async {
    if (!Platform.isWindows) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('getPerformanceMetrics');
      if (raw == null) return null;
      return NativePerformanceMetrics.fromMap(raw);
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native getPerformanceMetrics call failed: $e');
      return null;
    }
  }

  /// Sets static desktop wallpaper directly through native C++ COM (`IDesktopWallpaper`) with `SystemParametersInfo` fallback.
  Future<bool> setStaticWallpaper(String path, {String style = 'fill'}) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('setStaticWallpaper', {
        'path': path,
        'style': style,
      });
      return res ?? false;
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native setStaticWallpaper call failed: $e');
      return false;
    }
  }

  /// Queries native DirectX / DXGI graphics hardware and primary display topology.
  Future<NativeGpuAndDisplayInfo?> getGpuAndDisplayInfo() async {
    if (!Platform.isWindows) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('getGpuAndDisplayInfo');
      if (raw == null) return null;
      return NativeGpuAndDisplayInfo.fromMap(raw);
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native getGpuAndDisplayInfo call failed: $e');
      return null;
    }
  }

  /// Queries active media session using native WinRT GSMTC.
  Future<Map<String, dynamic>?> getMediaSessionInfo() async {
    if (!Platform.isWindows) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('getMediaSessionInfo');
      if (raw == null) return null;
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native getMediaSessionInfo call failed: $e');
      return null;
    }
  }

  /// Controls active media playback via native WinRT GSMTC (play, pause, toggle, next, previous).
  Future<bool> controlMediaSession(String action) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('controlMediaSession', {'action': action});
      return res ?? false;
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native controlMediaSession call failed: $e');
      return false;
    }
  }

  /// Adjusts window styles for instant click-through transparency via native Win32 `WS_EX_TRANSPARENT`.
  Future<bool> setWindowClickThrough(bool enable) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('setWindowClickThrough', {'enable': enable});
      return res ?? false;
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native setWindowClickThrough call failed: $e');
      return false;
    }
  }

  /// Pins window to bottom of Z-order (`HWND_BOTTOM`) natively.
  Future<bool> pinWindowToBottom() async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('pinWindowToBottom');
      return res ?? false;
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native pinWindowToBottom call failed: $e');
      return false;
    }
  }

  /// Toggles desktop icons visibility natively (reducing DWM overhead when hidden).
  Future<bool> setDesktopIconsVisible(bool visible) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('setDesktopIconsVisible', {'visible': visible});
      return res ?? false;
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native setDesktopIconsVisible call failed: $e');
      return false;
    }
  }

  /// Gets whether desktop icons are currently visible.
  Future<bool> getDesktopIconsVisible() async {
    if (!Platform.isWindows) return true;
    try {
      final res = await _channel.invokeMethod<bool>('getDesktopIconsVisible');
      return res ?? true;
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native getDesktopIconsVisible call failed: $e');
      return true;
    }
  }

  /// Sets Windows Taskbar blur / transparency mode natively:
  /// 0 = Default/Opaque, 1 = Transparent, 2 = Acrylic Blur, 3 = Blur Behind.
  Future<bool> setTaskbarBlur(int mode) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('setTaskbarBlur', {'mode': mode});
      return res ?? false;
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native setTaskbarBlur call failed: $e');
      return false;
    }
  }

  /// Queries whether another application (e.g. Spotify, YouTube, game) is actively playing audio via WASAPI.
  Future<bool> isOtherAudioPlaying() async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('isOtherAudioPlaying');
      return res ?? false;
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native isOtherAudioPlaying call failed: $e');
      return false;
    }
  }

  /// Returns Windows 10/11 system accent color and opacity.
  Future<Map<String, dynamic>?> getWindowsAccentColor() async {
    if (!Platform.isWindows) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('getWindowsAccentColor');
      if (raw == null) return null;
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native getWindowsAccentColor call failed: $e');
      return null;
    }
  }

  /// Starts a periodic background memory cleanup to keep RAM overhead under 35MB.
  void startBackgroundMemoryOptimizer({Duration interval = const Duration(minutes: 5)}) {
    _idleOptimizerTimer?.cancel();
    _idleOptimizerTimer = Timer.periodic(interval, (_) async {
      await optimizeMemory();
    });
  }

  void stopBackgroundMemoryOptimizer() {
    _idleOptimizerTimer?.cancel();
    _idleOptimizerTimer = null;
  }
}
