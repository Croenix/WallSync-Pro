import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'diagnostics_service.dart';
import 'settings_service.dart';

class NativePerformanceMetrics {
  const NativePerformanceMetrics({
    this.cpuPercent,
    this.ramLoadPercent,
    this.totalPhysMb,
    this.availPhysMb,
    this.processWorkingSetMb,
    this.processPrivateBytesMb,
    this.mpvWorkingSetMb,
    this.mpvPrivateBytesMb,
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
  final double? mpvWorkingSetMb;
  final double? mpvPrivateBytesMb;
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
      mpvWorkingSetMb: (map['mpvWorkingSetMb'] as num?)?.toDouble(),
      mpvPrivateBytesMb: (map['mpvPrivateBytesMb'] as num?)?.toDouble(),
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

class WindowsVersionInfo {
  const WindowsVersionInfo({
    required this.productName,
    required this.displayVersion,
    required this.build,
    required this.ubr,
    required this.isWindows11,
    required this.supportsEcoQoS,
    required this.processorCount,
  });

  final String productName;
  final String displayVersion;
  final int build;
  final int ubr;
  final bool isWindows11;
  final bool supportsEcoQoS;
  final int processorCount;

  factory WindowsVersionInfo.fromMap(Map<Object?, Object?> map) {
    return WindowsVersionInfo(
      productName: (map['productName'] as String?) ?? 'Windows',
      displayVersion: (map['displayVersion'] as String?) ?? '',
      build: (map['build'] as int?) ?? 0,
      ubr: (map['ubr'] as int?) ?? 0,
      isWindows11: (map['isWindows11'] as bool?) ?? false,
      supportsEcoQoS: (map['supportsEcoQoS'] as bool?) ?? false,
      processorCount: (map['processorCount'] as int?) ?? 4,
    );
  }
}

class WindowsProcessInfo {
  const WindowsProcessInfo({
    required this.pid,
    required this.name,
    required this.threads,
    required this.workingSetMb,
    required this.privateMb,
    required this.isWallSync,
    required this.isCurrentProcess,
  });

  final int pid;
  final String name;
  final int threads;
  final double workingSetMb;
  final double privateMb;
  final bool isWallSync;
  final bool isCurrentProcess;

  factory WindowsProcessInfo.fromMap(Map<Object?, Object?> map) {
    return WindowsProcessInfo(
      pid: (map['pid'] as int?) ?? 0,
      name: (map['name'] as String?) ?? '',
      threads: (map['threads'] as int?) ?? 0,
      workingSetMb: (map['workingSetMb'] as num?)?.toDouble() ?? 0.0,
      privateMb: (map['privateMb'] as num?)?.toDouble() ?? 0.0,
      isWallSync: (map['isWallSync'] as bool?) ?? false,
      isCurrentProcess: (map['isCurrentProcess'] as bool?) ?? false,
    );
  }
}

class SystemOptimizerService {
  static final SystemOptimizerService instance = SystemOptimizerService._();
  SystemOptimizerService._();

  static const MethodChannel _channel = MethodChannel(
    'wallsync/live_wallpaper',
  );

  Timer? _idleOptimizerTimer;
  bool _isLowPowerModeActive = false;
  int _operationCounter = 0;
  Future<bool>? _inFlightMemoryTrim;
  DateTime? _lastMemoryTrimTime;
  static const Duration _minMemoryTrimInterval = Duration(seconds: 2);

  Future<bool>? _inFlightLowPowerMode;
  bool? _inFlightLowPowerTarget;

  bool get isLowPowerModeActive => _isLowPowerModeActive;

  /// Performs an explicit memory optimization requested by the user.
  /// Automatic calls do not clear Flutter image caches or trim the working set,
  /// since both can cause image decoding and page-fault stalls during rendering.
  Future<bool> optimizeMemory({bool force = false}) async {
    if (!force) {
      return false;
    }

    final now = DateTime.now();
    if (_lastMemoryTrimTime != null &&
        now.difference(_lastMemoryTrimTime!) < _minMemoryTrimInterval) {
      return true; // Throttled duplicate trim
    }
    if (_inFlightMemoryTrim != null) {
      return _inFlightMemoryTrim!;
    }
    final opId = 'trim_${++_operationCounter}_${now.millisecondsSinceEpoch}';
    final completer = Completer<bool>();
    _inFlightMemoryTrim = completer.future;

    () async {
      try {
        try {
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
        } catch (_) {}
        if (!Platform.isWindows) {
          completer.complete(false);
          return;
        }
        final before = DiagnosticsService.instance.getMemorySnapshot();
        final res = await _channel.invokeMethod<bool>('optimizeMemory');
        _lastMemoryTrimTime = DateTime.now();
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final after = DiagnosticsService.instance.getMemorySnapshot();
        final rssDeltaMb =
            (after.processRssBytes - before.processRssBytes) / (1024 * 1024);
        final privateDeltaMb =
            before.processPrivateBytes == null ||
                after.processPrivateBytes == null
            ? null
            : (after.processPrivateBytes! - before.processPrivateBytes!) /
                  (1024 * 1024);
        logInfo(
          'SystemOptimizerService',
          '[$opId] Native trim request result=${res ?? false}; observed '
              'working-set delta=${rssDeltaMb.toStringAsFixed(1)}MB, '
              'private-memory delta=${privateDeltaMb?.toStringAsFixed(1) ?? 'unavailable'}MB '
              'after 150ms.',
        );
        completer.complete(res ?? false);
      } catch (e) {
        logWarning(
          'SystemOptimizerService',
          '[$opId] Native optimizeMemory call failed: $e',
        );
        completer.complete(false);
      } finally {
        _inFlightMemoryTrim = null;
      }
    }();

    return completer.future;
  }

  /// Creates a Windows NTFS hard link (`CreateHardLinkW`) to share read-only binaries/assets with 0 copying and 0 RAM overhead.
  Future<bool> createHardLink({
    required String target,
    required String existing,
  }) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('createHardLink', {
        'target': target,
        'existing': existing,
      });
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Sets below-normal process priority and toggles Windows 11 EcoQoS (Power Throttling).
  /// Enables maximum CPU responsiveness for foreground user applications and games.
  Future<bool> setLowPowerMode(bool enable) async {
    if (!Platform.isWindows) return false;
    if (_isLowPowerModeActive == enable && _inFlightLowPowerMode == null) {
      return true; // Already in desired mode, idempotent no-op
    }
    if (_inFlightLowPowerMode != null && _inFlightLowPowerTarget == enable) {
      return _inFlightLowPowerMode!;
    }
    final opId =
        'eco_${++_operationCounter}_${DateTime.now().millisecondsSinceEpoch}';
    final completer = Completer<bool>();
    _inFlightLowPowerMode = completer.future;
    _inFlightLowPowerTarget = enable;

    () async {
      try {
        final res = await _channel.invokeMethod<bool>('setLowPowerMode', {
          'enable': enable,
        });
        _isLowPowerModeActive = enable;
        logInfo(
          'SystemOptimizerService',
          '[$opId] Native power mode updated: lowPower=$enable (EcoQoS enabled).',
        );
        completer.complete(res ?? false);
      } catch (e) {
        logWarning(
          'SystemOptimizerService',
          '[$opId] Native setLowPowerMode call failed: $e',
        );
        completer.complete(false);
      } finally {
        _inFlightLowPowerMode = null;
        _inFlightLowPowerTarget = null;
      }
    }();

    return completer.future;
  }

  /// Gathers real-time performance metrics directly from the Windows kernel (CPU, RAM, working set, battery)
  /// with zero Dart FFI heap allocations or garbage collection churn.
  Future<NativePerformanceMetrics?> getPerformanceMetrics() async {
    if (!Platform.isWindows) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getPerformanceMetrics',
      );
      if (raw == null) return null;
      return NativePerformanceMetrics.fromMap(raw);
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native getPerformanceMetrics call failed: $e',
      );
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
      logWarning(
        'SystemOptimizerService',
        'Native setStaticWallpaper call failed: $e',
      );
      return false;
    }
  }

  /// Queries native DirectX / DXGI graphics hardware and primary display topology.
  Future<NativeGpuAndDisplayInfo?> getGpuAndDisplayInfo() async {
    if (!Platform.isWindows) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getGpuAndDisplayInfo',
      );
      if (raw == null) return null;
      return NativeGpuAndDisplayInfo.fromMap(raw);
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native getGpuAndDisplayInfo call failed: $e',
      );
      return null;
    }
  }

  /// Queries active media session using native WinRT GSMTC.
  Future<Map<String, dynamic>?> getMediaSessionInfo() async {
    if (!Platform.isWindows) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getMediaSessionInfo',
      );
      if (raw == null) return null;
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native getMediaSessionInfo call failed: $e',
      );
      return null;
    }
  }

  /// Controls active media playback via native WinRT GSMTC (play, pause, toggle, next, previous).
  Future<bool> controlMediaSession(String action) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('controlMediaSession', {
        'action': action,
      });
      return res ?? false;
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native controlMediaSession call failed: $e',
      );
      return false;
    }
  }

  /// Adjusts window styles for instant click-through transparency via native Win32 `WS_EX_TRANSPARENT`.
  Future<bool> setWindowClickThrough(bool enable) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('setWindowClickThrough', {
        'enable': enable,
      });
      return res ?? false;
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native setWindowClickThrough call failed: $e',
      );
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
      logWarning(
        'SystemOptimizerService',
        'Native pinWindowToBottom call failed: $e',
      );
      return false;
    }
  }

  /// Toggles desktop icons visibility natively (reducing DWM overhead when hidden).
  Future<bool> setDesktopIconsVisible(bool visible) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('setDesktopIconsVisible', {
        'visible': visible,
      });
      return res ?? false;
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native setDesktopIconsVisible call failed: $e',
      );
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
      logWarning(
        'SystemOptimizerService',
        'Native getDesktopIconsVisible call failed: $e',
      );
      return true;
    }
  }

  /// Sets Windows Taskbar blur / transparency mode natively:
  /// 0 = Default/Opaque, 1 = Transparent, 2 = Acrylic Blur, 3 = Blur Behind.
  Future<bool> setTaskbarBlur(int mode) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('setTaskbarBlur', {
        'mode': mode,
      });
      return res ?? false;
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native setTaskbarBlur call failed: $e',
      );
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
      logWarning(
        'SystemOptimizerService',
        'Native isOtherAudioPlaying call failed: $e',
      );
      return false;
    }
  }

  /// Returns Windows 10/11 system accent color and opacity.
  Future<Map<String, dynamic>?> getWindowsAccentColor() async {
    if (!Platform.isWindows) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getWindowsAccentColor',
      );
      if (raw == null) return null;
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native getWindowsAccentColor call failed: $e',
      );
      return null;
    }
  }

  /// Checks if a process is running using native Win32 toolhelp snapshot without spawning any shell process.
  Future<bool> isProcessRunning(String processName) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('isProcessRunning', {
        'name': processName,
      });
      return res ?? false;
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native isProcessRunning call failed: $e',
      );
      return false;
    }
  }

  /// Opens native Windows COM IFileOpenDialog for selecting image files with 0ms overhead and 0 PowerShell memory churn.
  Future<String?> pickImageFile({String title = 'Select Image'}) async {
    if (!Platform.isWindows) return null;
    try {
      final res = await _channel.invokeMethod<String>('pickImageFile', {
        'title': title,
      });
      return res?.isNotEmpty == true ? res : null;
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native pickImageFile call failed: $e',
      );
      return null;
    }
  }

  /// Dynamically boosts process priority to above-normal during active UI interactions for zero-lag responsiveness.
  Future<bool> boostProcessPriority(bool boost) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('boostProcessPriority', {
        'boost': boost,
      });
      return res ?? false;
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native boostProcessPriority call failed: $e',
      );
      return false;
    }
  }

  /// Cloaks the window in DWM when hidden or minimized so Windows halts all swapchain composition and frees memory.
  Future<bool> setWindowCloaked(bool cloak) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('setWindowCloaked', {
        'cloak': cloak,
      });
      return res ?? false;
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native setWindowCloaked call failed: $e',
      );
      return false;
    }
  }

  /// Retrieves native Windows version and build diagnostics.
  Future<WindowsVersionInfo?> getWindowsVersionInfo() async {
    if (!Platform.isWindows) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'getWindowsVersionInfo',
      );
      if (raw == null) return null;
      return WindowsVersionInfo.fromMap(raw);
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native getWindowsVersionInfo failed: $e',
      );
      return null;
    }
  }

  /// Enumerates running processes with PID, working set, private bytes, and WallSync identification.
  Future<List<WindowsProcessInfo>> getProcessList() async {
    if (!Platform.isWindows) return const [];
    try {
      final rawList = await _channel.invokeListMethod<dynamic>(
        'getProcessList',
      );
      if (rawList == null) return const [];
      return rawList
          .whereType<Map>()
          .map((m) => WindowsProcessInfo.fromMap(m))
          .toList();
    } catch (e) {
      logWarning('SystemOptimizerService', 'Native getProcessList failed: $e');
      return const [];
    }
  }

  /// Adjusts the priority class for a specific process (0: Below Normal / Power Saver, 1: Normal, 2: Above Normal / Performance, 3: High).
  Future<bool> setProcessPriority(int pid, int priorityLevel) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('setProcessPriority', {
        'pid': pid,
        'priority': priorityLevel,
      });
      return res ?? false;
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native setProcessPriority failed: $e',
      );
      return false;
    }
  }

  /// Trims the working set and compacts the heap for a specific PID.
  Future<bool> trimProcessMemory(int pid) async {
    if (!Platform.isWindows) return false;
    try {
      final res = await _channel.invokeMethod<bool>('trimProcessMemory', {
        'pid': pid,
      });
      return res ?? false;
    } catch (e) {
      logWarning(
        'SystemOptimizerService',
        'Native trimProcessMemory failed: $e',
      );
      return false;
    }
  }

  /// Kept for API compatibility; automatic memory trimming is disabled because
  /// it can evict resources used by active Flutter surfaces.
  void startBackgroundMemoryOptimizer({
    Duration interval = const Duration(minutes: 3),
  }) {
    _idleOptimizerTimer?.cancel();
    _idleOptimizerTimer = null;
    logInfo(
      'SystemOptimizerService',
      'Automatic working-set trimming is disabled; memory optimization '
          'remains available as an explicit user action.',
    );
  }

  void stopBackgroundMemoryOptimizer() {
    _idleOptimizerTimer?.cancel();
    _idleOptimizerTimer = null;
  }
}
