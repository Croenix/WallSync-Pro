import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mpv_runtime_resolver.dart';
import 'settings_service.dart';

class MpvStartupCancelledException extends StateError {
  MpvStartupCancelledException([super.message = 'MPV startup was cancelled.']);
}

class LiveWallpaperManager {
  static final LiveWallpaperManager _instance =
      LiveWallpaperManager._internal();
  factory LiveWallpaperManager([dynamic controller]) => _instance;
  LiveWallpaperManager._internal();

  static const MethodChannel channel = MethodChannel('wallsync/live_wallpaper');

  Future<void> initialize() async {
    logInfo('LiveWallpaperManager', 'Wallpaper manager initialized.');
  }

  Future<void> wallpaperLoaded() async {
    logInfo('LiveWallpaperManager', 'Wallpaper page reported loaded.');
  }

  Timer? _policyTimer;
  String _currentPath = '';
  bool _wantsPlayback = true;
  bool _policyPaused = false;
  bool _checkingPolicy = false;
  bool _pauseOnFullscreen = true;
  bool _pauseOnBatterySaver = true;
  bool? _candidatePolicyPaused;
  int _candidatePolicyCount = 0;
  bool _muted = false;
  bool _loop = true;
  double _volume = 0.5;
  double _speed = 1.0;
  String _fit = 'fill';

  /// Emits whenever an application goes fullscreen/maximized or resumes,
  /// allowing UI components to show real-time 0% GPU overhead indicators.
  final ValueNotifier<bool> policyPausedNotifier = ValueNotifier<bool>(false);

  bool get wantsPlayback => _wantsPlayback;
  bool get isPolicyPaused => _policyPaused;
  bool get isPlaying => _wantsPlayback && !_policyPaused;
  bool get isMuted => _muted;
  double get volume => _volume;
  double get speed => _speed;
  bool get isLoop => _loop;
  String get fit => _fit;
  bool get pauseOnFullscreen => _pauseOnFullscreen;
  bool get pauseOnBatterySaver => _pauseOnBatterySaver;
  String get currentPath => _currentPath;

  int? _mpvPid;
  int? get mpvPid => _mpvPid;
  int _startupGeneration = 0;
  bool _windowAttached = false;
  bool _windowVisible = false;
  bool _firstFrameReady = false;

  void _updateStartupStatus(Map<String, dynamic>? result) {
    if (result == null) return;
    final pid = result['pid'];
    if (pid is int && pid > 0) _mpvPid = pid;
    _windowAttached = result['windowAttached'] == true;
    _windowVisible = result['windowVisible'] == true;
    _firstFrameReady = result['frameDecoded'] == true;
  }

  @visibleForTesting
  static bool startupResultIsReadyForTesting(Map<String, dynamic>? result) {
    if (result == null ||
        result['success'] != true ||
        result['frameDecoded'] != true ||
        result['windowAttached'] != true ||
        result['windowVisible'] != true) {
      return false;
    }
    final width = result['width'];
    final height = result['height'];
    return width is int && width > 0 && height is int && height > 0;
  }

  @visibleForTesting
  static Future<Map<String, dynamic>?> pollStartupForTesting({
    required Map<String, dynamic>? initialResult,
    required Future<Map<String, dynamic>?> Function() poll,
    required bool Function() isCancelled,
    Duration timeout = const Duration(seconds: 15),
    Duration initialInterval = const Duration(milliseconds: 32),
  }) async {
    final stopwatch = Stopwatch()..start();
    var result = initialResult;
    var interval = initialInterval;
    while (result?['pending'] == true && stopwatch.elapsed < timeout) {
      if (isCancelled()) return null;
      await Future<void>.delayed(interval);
      if (isCancelled()) return null;
      result = await poll();
      // Window discovery and decoder initialization can take seconds. Back
      // off after the responsive initial phase so polling cannot create a
      // platform-channel storm on the UI isolate.
      if (stopwatch.elapsed > const Duration(seconds: 1)) {
        interval = const Duration(milliseconds: 100);
      }
    }
    return result;
  }

  Future<void>? _inFlightStartupOperation;
  String? _inFlightStartupPath;

  Future<void> start(
    WidgetSettings settings, {
    bool Function()? isCancelled,
    int? transitionId,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Native MPV wallpapers are supported on Windows.');
    }
    _readSettings(settings);
    final targetPath = settings.activeWallpaperPath?.trim() ?? '';
    if (targetPath.isEmpty) {
      throw ArgumentError('Video wallpaper path is empty.');
    }

    // Media validation: Ensure media file exists and is accessible before launching MPV
    if (!targetPath.startsWith('http://') && !targetPath.startsWith('https://')) {
      final file = File(targetPath);
      if (file.existsSync()) {
        final size = file.lengthSync();
        if (size < 1024) {
          throw FormatException('Video wallpaper file is incomplete or corrupt ($size bytes): $targetPath');
        }
      } else if (!Platform.environment.containsKey('FLUTTER_TEST')) {
        throw FileSystemException('Video wallpaper file not found on disk', targetPath);
      }
    }

    // Idempotent: If the same target video is already active, attached, and ready:
    if (_currentPath == targetPath &&
        _firstFrameReady &&
        _windowAttached &&
        _mpvPid != null) {
      logInfo(
        'LiveWallpaperManager',
        'Transition #${transitionId ?? '-'} target video is already active and ready: $targetPath (PID $_mpvPid).',
      );
      return;
    }

    // Deduplicate: If an identical startup is already in progress, join it
    if (_inFlightStartupPath == targetPath && _inFlightStartupOperation != null) {
      logInfo(
        'LiveWallpaperManager',
        'Transition #${transitionId ?? '-'} joining in-progress startup for: $targetPath',
      );
      return _inFlightStartupOperation!;
    }

    final startupGeneration = ++_startupGeneration;
    _inFlightStartupPath = targetPath;
    final completer = Completer<void>();
    _inFlightStartupOperation = completer.future;

    _startInternal(
      settings,
      startupGeneration: startupGeneration,
      isCancelled: isCancelled,
      transitionId: transitionId,
    ).then((_) {
      if (!completer.isCompleted) completer.complete();
    }, onError: (Object e, StackTrace st) {
      if (!completer.isCompleted) completer.completeError(e, st);
    }).whenComplete(() {
      if (_startupGeneration == startupGeneration) {
        _inFlightStartupOperation = null;
        _inFlightStartupPath = null;
      }
    });

    return completer.future;
  }

  Future<void> _startInternal(
    WidgetSettings settings, {
    required int startupGeneration,
    bool Function()? isCancelled,
    int? transitionId,
  }) async {
    // The native start method first tears down any previous MPV process. Do
    // not expose the old PID while the new process is pending or if launch
    // fails, since diagnostics could otherwise sample a recycled process ID.
    _mpvPid = null;
    final mpvPath = await MpvRuntimeResolver.instance.requireExecutablePath();
    final args = <String, Object>{
      ..._settingsArguments(settings.activeWallpaperPath),
      'mpvPath': mpvPath,
    };
    final startup = Stopwatch()..start();
    final initialResult = await channel.invokeMapMethod<String, dynamic>(
      'startMpv',
      args,
    );
    _updateStartupStatus(initialResult);
    var polls = 0;
    var totalPollCallMs = 0.0;
    var maxPollCallMs = 0.0;
    var totalPollIntervalMs = 0.0;
    var maxPollIntervalMs = 0.0;
    Stopwatch? previousPollIntervalStopwatch;
    final result = await pollStartupForTesting(
      initialResult: initialResult,
      isCancelled: () =>
          startupGeneration != _startupGeneration ||
          (isCancelled?.call() ?? false),
      poll: () async {
        polls++;
        final previousPollInterval = previousPollIntervalStopwatch;
        if (previousPollInterval != null) {
          final intervalMs = previousPollInterval.elapsedMicroseconds / 1000;
          totalPollIntervalMs += intervalMs;
          if (intervalMs > maxPollIntervalMs) {
            maxPollIntervalMs = intervalMs;
          }
        }
        previousPollIntervalStopwatch = Stopwatch()..start();
        final pollCallStopwatch = Stopwatch()..start();
        final polledResult = await channel.invokeMapMethod<String, dynamic>(
          'pollMpvStart',
        );
        final pollCallMs = pollCallStopwatch.elapsedMicroseconds / 1000;
        totalPollCallMs += pollCallMs;
        if (pollCallMs > maxPollCallMs) maxPollCallMs = pollCallMs;
        _updateStartupStatus(polledResult);
        return polledResult;
      },
    );
    if (startupGeneration != _startupGeneration ||
        (isCancelled?.call() ?? false)) {
      // Only stop the process if no newer startup generation has superseded us.
      if (startupGeneration == _startupGeneration) {
        await stop(transitionId: transitionId);
      }
      throw MpvStartupCancelledException(
        'Transition #${transitionId ?? '-'} MPV startup was cancelled.',
      );
    }
    final width = result?['width'];
    final height = result?['height'];
    final pidVal = result?['pid'];
    if (pidVal is int && pidVal > 0) {
      _mpvPid = pidVal;
    }
    String phase(String key) {
      final value = result?[key];
      return value is num && value >= 0
          ? '${value.toStringAsFixed(1)}ms'
          : 'unavailable';
    }

    if (!startupResultIsReadyForTesting(result) ||
        width is! int ||
        height is! int) {
      final stage = result?['stage'] != null ? '[${result!['stage']}] ' : '';
      final win32Error = result?['win32Error'];
      final win32Suffix = win32Error != null ? ' (Win32 code: $win32Error)' : '';
      final errorDetail =
          result?['error'] ??
          (result?['pending'] == true
              ? 'MPV startup timed out after ${startup.elapsedMilliseconds} ms '
                    '(window=${result?['windowAttached']}, visible=${result?['windowVisible']}, IPC=${result?['ipcConnected']}, '
                    'frame=${result?['frameDecoded']}).'
              : 'MPV did not report a decoded video frame.');
      final cmdLine = result?['cmdLine'] != null ? ' | CMD: ${result!['cmdLine']}' : '';
      throw FormatException(
        'Transition #${transitionId ?? '-'} $stage${errorDetail.toString()}$win32Suffix$cmdLine (cleanup ${phase('cleanupMs')}, '
        'lookup ${phase('lookupMs')}, launch ${phase('launchMs')}, '
        'window found elapsed ${phase('windowFoundMs')} '
        '(scan call ${phase('windowDiscoveryCallMs')}), '
        'attach elapsed ${phase('attachMs')} '
        '(native attach call ${phase('windowAttachmentCallMs')}, '
        'desktop target lookup ${phase('desktopTargetLookupMs')}), '
        'visible request ${phase('visibleRequestMs')}, DWM flush ${phase('dwmFlushMs')}, '
        'IPC ${phase('ipcMs')}, '
        'output configured elapsed ${phase('outputConfiguredMs')}, '
        'decoded frame elapsed ${phase('frameReadyMs')}, '
        'polls $polls (native call total ${totalPollCallMs.toStringAsFixed(1)}ms, '
        'max ${maxPollCallMs.toStringAsFixed(1)}ms; average interval '
        '${polls > 1 ? (totalPollIntervalMs / (polls - 1)).toStringAsFixed(1) : 'n/a'}ms, '
        'max ${maxPollIntervalMs.toStringAsFixed(1)}ms)).',
      );
    }
    final successResult = result!;
    _currentPath = settings.activeWallpaperPath ?? '';
    _windowAttached = successResult['windowAttached'] == true;
    _windowVisible = successResult['windowVisible'] == true;
    _firstFrameReady = successResult['frameDecoded'] == true;
    logPerf(
      'LiveWallpaperManager',
      'Transition #${transitionId ?? '-'} MPV ready: PID $_mpvPid, owned window attached=${successResult['windowAttached']}, '
          'visible=${successResult['windowVisible']}, first frame decoded=${successResult['frameDecoded']}, ${width}x$height; '
          'previous-player cleanup ${phase('cleanupMs')}, executable lookup ${phase('lookupMs')}, '
          'process launch ${phase('launchMs')}, '
          'window found elapsed ${phase('windowFoundMs')} '
          '(native scan ${phase('windowDiscoveryCallMs')}), '
          'window attach elapsed ${phase('attachMs')} '
          '(native attach call ${phase('windowAttachmentCallMs')}, '
          'desktop target lookup ${phase('desktopTargetLookupMs')}), '
          'visible request elapsed ${phase('visibleRequestMs')}, '
          'visible confirmed elapsed ${phase('visibleConfirmedMs')}, '
          'DWM composition flush ${phase('dwmFlushMs')}, '
          'IPC ready elapsed ${phase('ipcMs')}, '
          'output configured elapsed ${phase('outputConfiguredMs')}, '
          'decoded frame elapsed ${phase('frameReadyMs')}, '
          'total ${startup.elapsedMilliseconds}ms, polls $polls '
          '(native call total ${totalPollCallMs.toStringAsFixed(1)}ms, '
          'max ${maxPollCallMs.toStringAsFixed(1)}ms; average interval '
          '${polls > 1 ? (totalPollIntervalMs / (polls - 1)).toStringAsFixed(1) : 'n/a'}ms, '
          'max ${maxPollIntervalMs.toStringAsFixed(1)}ms).',
    );
    _policyTimer?.cancel();
    _policyTimer = Timer.periodic(
      const Duration(milliseconds: 1000),
      (_) => unawaited(_pollPlaybackPolicy()),
    );
    // Policy inspection enumerates native windows. Let the wallpaper report
    // ready first, then apply fullscreen/battery-saver policy asynchronously.
    unawaited(_pollPlaybackPolicy());
  }

  Future<void> updateSettings(WidgetSettings settings) async {
    _readSettings(settings);
    await channel.invokeMethod<void>('setMpvSettings', _settingsArguments(settings.activeWallpaperPath));
    await _applyPlaybackPolicy();
  }

  void _readSettings(WidgetSettings settings) {
    _wantsPlayback = !settings.videoWallpaperPaused;
    _pauseOnFullscreen = settings.videoWallpaperPauseOnFullscreen;
    _pauseOnBatterySaver = settings.videoWallpaperPauseOnBatterySaver;
    _muted = settings.videoWallpaperMuted;
    _loop = settings.videoWallpaperLoop;
    _volume = settings.videoWallpaperVolume.clamp(0, 1).toDouble();
    if (_volume <= 0) {
      _muted = true;
    }
    _speed = settings.videoWallpaperSpeed.clamp(0.25, 3.0);
    _fit = settings.wallpaperFit;
  }

  Map<String, Object> _settingsArguments([String? overridePath]) => {
    'path': overridePath ?? _currentPath,
    'volume': (_volume * 100).round(),
    'muted': _muted || _volume <= 0,
    'loop': _loop,
    'fit': _fit,
    'speed': _speed,
    'paused': !_wantsPlayback || _policyPaused,
  };

  Future<void> play() async {
    _wantsPlayback = true;
    await _sendSettings();
  }

  Future<void> pause() async {
    _wantsPlayback = false;
    await _sendSettings();
  }

  Future<void> setVolume(double volume) async {
    if (!volume.isFinite || volume < 0 || volume > 1) {
      throw RangeError.range(volume, 0, 1, 'volume');
    }
    _volume = volume;
    _muted = _volume <= 0;
    await _sendSettings();
  }

  Future<void> setMuted(bool muted) async {
    _muted = muted;
    if (!_muted && _volume <= 0) {
      _volume = 0.5;
    }
    await _sendSettings();
  }

  Future<void> setLoop(bool loop) async {
    _loop = loop;
    await _sendSettings();
  }

  Future<void> setFit(String fit) async {
    _fit = fit;
    await _sendSettings();
  }

  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.25, 3.0);
    await _sendSettings();
  }

  Future<void> _sendSettings() async {
    if (!Platform.isWindows || _currentPath.isEmpty) return;
    try {
      await channel.invokeMethod<void>('setMpvSettings', _settingsArguments());
    } catch (e) {
      logError('LiveWallpaperManager', 'Failed to send MPV settings', e);
    }
  }

  Future<void> _pollPlaybackPolicy() async {
    if (_checkingPolicy) return;
    _checkingPolicy = true;
    try {
      await _applyPlaybackPolicy();
    } catch (_) {
    } finally {
      _checkingPolicy = false;
    }
  }

  Future<void> _applyPlaybackPolicy() async {
    if (!Platform.isWindows || _currentPath.isEmpty) return;
    try {
      final policy = await channel.invokeMapMethod<String, bool>(
        'getPlaybackPolicy',
      );
      if (policy == null ||
          !policy.containsKey('fullscreen') ||
          !policy.containsKey('batterySaver')) {
        return;
      }

      final isFullscreen = policy['fullscreen'] ?? false;
      final isBatterySaver = policy['batterySaver'] ?? false;
      final shouldPause =
          (_pauseOnFullscreen && isFullscreen) ||
          (_pauseOnBatterySaver && isBatterySaver);

      if (shouldPause != _policyPaused) {
        if (_candidatePolicyPaused == shouldPause) {
          _candidatePolicyCount++;
          if (_candidatePolicyCount >= 2) {
            _policyPaused = shouldPause;
            _candidatePolicyPaused = null;
            _candidatePolicyCount = 0;
            policyPausedNotifier.value = shouldPause;
            logInfo(
              'LiveWallpaperManager',
              'Playback policy changed: paused=$shouldPause (fullscreen=$isFullscreen, batterySaver=$isBatterySaver)',
            );
            await _sendSettings();
          }
        } else {
          _candidatePolicyPaused = shouldPause;
          _candidatePolicyCount = 1;
        }
      } else {
        _candidatePolicyPaused = null;
        _candidatePolicyCount = 0;
      }
    } catch (_) {}
  }

  Future<void>? _activeStopOperation;

  Future<void> stop({int? transitionId}) {
    if (_activeStopOperation != null) {
      logInfo(
        'LiveWallpaperManager',
        'Transition #${transitionId ?? '-'} joining in-progress MPV stop operation.',
      );
      return _activeStopOperation!;
    }
    // Idempotent: If no MPV session is active or tracked, return immediately.
    if (_mpvPid == null &&
        _currentPath.isEmpty &&
        !_windowAttached &&
        !_firstFrameReady) {
      _policyTimer?.cancel();
      _policyTimer = null;
      policyPausedNotifier.value = false;
      return Future<void>.value();
    }

    final completer = Completer<void>();
    _activeStopOperation = completer.future;

    () async {
      try {
        // Invalidate an in-flight asynchronous start before asking native code to
        // tear down the child process.
        _startupGeneration++;
        _policyTimer?.cancel();
        _policyTimer = null;
        final targetPid = _mpvPid;
        logInfo(
          'LiveWallpaperManager',
          'Transition #${transitionId ?? '-'} stopping owned MPV PID ${targetPid ?? 'unknown'} '
              '(attached=$_windowAttached, visible=$_windowVisible, firstFrame=$_firstFrameReady).',
        );
        if (Platform.isWindows) {
          final stopped = await channel.invokeMethod<bool>('stopMpv');
          if (stopped != true) {
            throw StateError('Native MPV shutdown was not confirmed.');
          }
        }
        logInfo(
          'LiveWallpaperManager',
          'Transition #${transitionId ?? '-'} native MPV shutdown confirmed for PID ${targetPid ?? 'unknown'}.',
        );
        _currentPath = '';
        _policyPaused = false;
        _mpvPid = null;
        _windowAttached = false;
        _windowVisible = false;
        _firstFrameReady = false;
        policyPausedNotifier.value = false;
        completer.complete();
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _activeStopOperation = null;
      }
    }();

    return completer.future;
  }

  void dispose() {
    _startupGeneration++;
    _inFlightStartupOperation = null;
    _inFlightStartupPath = null;
    _policyTimer?.cancel();
    _policyTimer = null;
    policyPausedNotifier.value = false;
    _activeStopOperation = null;
  }
}
