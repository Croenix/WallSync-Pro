import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ffi' hide Size;
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import '../services/settings_service.dart';
import 'animated_backgrounds.dart';
import '../services/weather_service.dart';
import '../services/media_session_service.dart';
import '../services/system_metrics_service.dart';
import '../services/system_connectivity_service.dart';
import '../services/system_optimizer_service.dart';
import '../services/discord_ipc_service.dart';
import '../services/steam_monitor_service.dart';
import '../services/device_optimization_service.dart';
import '../services/live_wallpaper_manager.dart';
import '../services/windows_taskbar_service.dart';
import '../services/taskbar_configuration_service.dart';
import 'custom_widget_renderer.dart';
import '../models/desktop_studio_template.dart';

Future<Uint8List> _decodeMediaThumbnailAsync(
  String encoded,
  String owner,
) async {
  final stopwatch = Stopwatch()..start();
  final task = developer.TimelineTask()
    ..start(
      'WallSync media artwork base64 decode',
      arguments: {'owner': owner, 'encodedCharacters': encoded.length},
    );
  try {
    return await compute(base64Decode, encoded);
  } finally {
    final durationMs = stopwatch.elapsedMilliseconds;
    task.finish(arguments: {'durationMs': durationMs});
    logPerf(
      'DesktopWidget',
      'Media artwork base64 decode for $owner completed off-thread in '
          '${durationMs}ms (${encoded.length} encoded characters).',
    );
  }
}

class DesktopWidget extends StatefulWidget {
  final WidgetSettings? initialSettings;
  final String? instanceId;
  const DesktopWidget({super.key, this.initialSettings, this.instanceId});

  @override
  State<DesktopWidget> createState() => _DesktopWidgetState();
}

class _DesktopWidgetState extends State<DesktopWidget>
    with TickerProviderStateMixin, WindowListener {
  late WidgetSettings _settings;
  late Timer _timer;
  late DateTime _dateTime;
  late final SettingsService _settingsService;
  StreamSubscription<FileSystemEvent>? _settingsWatcher;
  bool _isLoading = true;
  String? _startupError;
  late AnimationController _neonAnimationController;
  Timer? _inactivityTimer;
  bool _visualEditorModeActive = false;
  Timer? _watcherDebounce;
  Timer? _boundsSaveDebounce;
  bool _isSavingBoundsLocally = false;
  bool _isApplyingExternalResize = false;
  bool _isUserInteractingWithWindow = false;
  final TaskbarConfigurationService _taskbarConfigurationService =
      TaskbarConfigurationService();

  void _startUserWindowInteraction() {
    _isUserInteractingWithWindow = true;
    _boundsSaveDebounce?.cancel();
  }

  void _endUserWindowInteraction() {
    _isUserInteractingWithWindow = false;
    _scheduleWindowBoundsSave(immediate: true);
  }

  bool _showWeatherSearchOverlay = false;
  String _weatherSearchError = '';
  final TextEditingController _weatherQueryController = TextEditingController();
  Timer? _weatherTimer;
  bool _isFetchingWeather = false;
  bool _isRefreshingSystemMetrics = false;
  final List<DockWindowInfo> _dockWindows = [];
  bool _isRefreshingDockWindows = false;
  final Set<String> _hoveredTaskbarActions = {};
  bool get _isTaskbarReplacement =>
      _settings.widgetTemplate == 'taskbar_dock' &&
      WindowsTaskbarService.supportsFullReplacement &&
      _settings.taskbarSettings.nativeTaskbarHideEnabled;
  bool get _usesNativeTaskbarAppBar =>
      Platform.isWindows && _settings.widgetTemplate == 'taskbar_dock';

  // Media session state
  StreamSubscription<MediaInfo>? _mediaSubscription;
  StreamSubscription<SystemConnectivitySnapshot>? _connectivitySubscription;
  StreamSubscription<DiscordVoiceSnapshot>? _discordSub;
  StreamSubscription<SteamDownloadSnapshot>? _steamSub;
  SystemConnectivitySnapshot _connectivity =
      SystemConnectivityService.instance.current;
  bool _connectivityServiceActive = false;
  bool _overlayShutdownStarted = false;
  MediaInfo _mediaInfo = MediaInfo(title: '', artist: '', status: 'Closed');
  final ValueNotifier<int> _playbackPositionNotifier = ValueNotifier<int>(0);
  Uint8List? _thumbnailBytes;

  // CPU & RAM stats for Robik template
  double _cpuUsage = 0.0;
  double _ramUsage = 0.0;
  int _lastIdleTime = 0;
  int _lastKernelTime = 0;
  int _lastUserTime = 0;
  SystemMetricsSnapshot _systemMetrics = const SystemMetricsSnapshot();

  void _updateSystemStats() {
    SystemOptimizerService.instance
        .getPerformanceMetrics()
        .then((metrics) {
          if (!mounted) return;
          if (metrics != null) {
            if (metrics.cpuPercent != null) _cpuUsage = metrics.cpuPercent!;
            if (metrics.ramLoadPercent != null) {
              _ramUsage = metrics.ramLoadPercent!;
            }
            return;
          }
          _updateSystemStatsFallback();
        })
        .catchError((_) {
          _updateSystemStatsFallback();
        });
  }

  void _updateSystemStatsFallback() {
    final idleTime = calloc<FILETIME>();
    final kernelTime = calloc<FILETIME>();
    final userTime = calloc<FILETIME>();

    if (GetSystemTimes(idleTime, kernelTime, userTime).value) {
      final int idle =
          (idleTime.ref.dwHighDateTime << 32) | idleTime.ref.dwLowDateTime;
      final int kernel =
          (kernelTime.ref.dwHighDateTime << 32) | kernelTime.ref.dwLowDateTime;
      final int user =
          (userTime.ref.dwHighDateTime << 32) | userTime.ref.dwLowDateTime;

      if (_lastIdleTime != 0) {
        final int usr = user - _lastUserTime;
        final int ker = kernel - _lastKernelTime;
        final int idl = idle - _lastIdleTime;
        final int sys = usr + ker;
        if (sys > 0) {
          _cpuUsage = (((sys - idl) * 100.0) / sys).clamp(0.0, 100.0);
        }
      }
      _lastIdleTime = idle;
      _lastKernelTime = kernel;
      _lastUserTime = user;
    }
    calloc.free(idleTime);
    calloc.free(kernelTime);
    calloc.free(userTime);

    final memoryStatus = calloc<MEMORYSTATUSEX>();
    memoryStatus.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
    if (GlobalMemoryStatusEx(memoryStatus).value) {
      _ramUsage = memoryStatus.ref.dwMemoryLoad.toDouble();
    }
    calloc.free(memoryStatus);
  }

  bool get _needsSystemStats {
    switch (_settings.widgetTemplate) {
      case 'neon':
      case 'robik':
      case 'cyber_hud':
      case 'taskbar_dock':
      case 'taskbar_system':
        return true;
      case 'custom':
        return _settings.customElements.any(
          (element) => element.type == 'cpu_bar' || element.type == 'ram_bar',
        );
      default:
        return false;
    }
  }

  bool get _needsWeather {
    switch (_settings.widgetTemplate) {
      case 'sleep_weather':
      case 'station_weather':
      case 'taskbar_weather':
        return true;
      case 'taskbar_dock':
        return _settings.taskbarShowWeather;
      case 'robik':
        return _settings.showWeather;
      case 'custom':
        return _settings.showWeather ||
            _settings.customElements.any(
              (element) =>
                  element.type == 'weather_temp' ||
                  element.type == 'weather_icon' ||
                  element.type == 'weather_status',
            );
      default:
        return false;
    }
  }

  bool _settingsNeedSystemMetrics(WidgetSettings settings) =>
      (settings.widgetTemplate == 'custom' &&
          settings.customElements.any(
            (element) =>
                element.type == 'space_bar' || element.type == 'battery_bar',
          )) ||
      settings.widgetTemplate == 'taskbar_dock' ||
      settings.widgetTemplate == 'taskbar_system';

  Future<SystemMetricsSnapshot?> _readSystemMetrics(
    WidgetSettings settings,
  ) async {
    if (!_settingsNeedSystemMetrics(settings)) {
      return const SystemMetricsSnapshot();
    }
    try {
      return await SystemMetricsService.readSnapshotAsync(
        settings.taskbarDiskDrive,
      );
    } catch (error, stackTrace) {
      logWarning(
        'DesktopWidget',
        'Could not read system metrics outside the UI isolate: $error\n$stackTrace',
      );
      return null;
    }
  }

  Future<void> _refreshSystemMetrics() async {
    if (_isRefreshingSystemMetrics) return;
    _isRefreshingSystemMetrics = true;
    try {
      final metrics = await SystemMetricsService.readSnapshotAsync(
        _settings.taskbarDiskDrive,
      );
      if (!mounted ||
          !_settingsNeedSystemMetrics(_settings) ||
          metrics == _systemMetrics) {
        return;
      }
      setState(() => _systemMetrics = metrics);
    } catch (error, stackTrace) {
      logWarning(
        'DesktopWidget',
        'Could not refresh system metrics outside the UI isolate: $error\n$stackTrace',
      );
    } finally {
      _isRefreshingSystemMetrics = false;
    }
  }

  void _updatePlaybackPosition(MediaInfo info) {
    _playbackPositionNotifier.value = info.hasPosition ? info.position : 0;
  }

  final List<List<Color>> _gradientColors = [
    [const Color(0xFF8E2DE2), const Color(0xFF4A00E0)],
    [const Color(0xFF02AAB0), const Color(0xFF00CDAC)],
    [const Color(0xFFFF512F), const Color(0xFFDD2476)],
    [const Color(0xFF0F2027), const Color(0xFF203A43), const Color(0xFF2C5364)],
    [const Color(0xFFF72585), const Color(0xFF7209B7), const Color(0xFF3F37C9)],
    [const Color(0xFFFFD700), const Color(0xFF39FF14)],
    [const Color(0xFF000000), const Color(0xFF434343)],
    [const Color(0xFFF12711), const Color(0xFFF5AF19)],
    [const Color(0xFF11998E), const Color(0xFF38EF7D)],
    [const Color(0xFF0575E6), const Color(0xFF00F260)],
    [const Color(0xFF4776E6), const Color(0xFF8E54E9)],
    [const Color(0xFF1E3C72), const Color(0xFF2A5298)],
    [const Color(0xFFE91E63), const Color(0xFFFCE4EC)],
    [const Color(0xFF111111), const Color(0xFFD4AF37)],
    [const Color(0xFFFF758C), const Color(0xFFFF7EB3)],
  ];

  final List<String> _curatedWallpaperPaths = [
    'assets/cyberpunk.png',
    'assets/aurora.png',
    'assets/forest.png',
    'assets/nebula.png',
    'assets/cosmic_dust.png',
    'assets/ocean_breeze.png',
    'assets/desert_sunset.png',
    'assets/golden_hour.png',
  ];

  @override
  void initState() {
    super.initState();
    _settingsService = SettingsService(instanceId: widget.instanceId);
    _settings = widget.initialSettings ?? WidgetSettings();
    windowManager.addListener(this);
    _isLoading = widget.initialSettings == null;
    _visualEditorModeActive = _settings.editorMode;
    _dateTime = DateTime.now();
    _syncConnectivityService();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        final now = DateTime.now();
        final needsStats = _needsSystemStats;
        bool shouldUpdate =
            _settings.showSeconds ||
            now.minute != _dateTime.minute ||
            now.hour != _dateTime.hour;
        if (needsStats && timer.tick % 2 == 0) {
          shouldUpdate = true;
        }
        if (_settingsNeedSystemMetrics(_settings) && timer.tick % 15 == 0) {
          unawaited(_refreshSystemMetrics());
        }
        if (_settings.widgetTemplate == 'taskbar_dock' && timer.tick % 2 == 0) {
          unawaited(_refreshDockWindows());
        }
        if (shouldUpdate) {
          setState(() {
            _dateTime = now;
            if (needsStats && timer.tick % 2 == 0) {
              _updateSystemStats();
            }
          });
        }
      }
    });

    // Keep the media service active for any configured media element.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncMediaServiceState();
        if (_settings.autoSizing) {
          _applyAutoSizing();
        }
      }
    });
    _syncMediaSubscription();

    _neonAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    _initSettings();
  }

  void _syncMediaSubscription() {
    final needed = _needsMediaSession;
    if (needed && _mediaSubscription == null) {
      _mediaInfo = MediaSessionService().current;
      _updatePlaybackPosition(_mediaInfo);
      if (_mediaInfo.thumbnail.isNotEmpty) {
        final initialThumb = _mediaInfo.thumbnail;
        _decodeMediaThumbnailAsync(initialThumb, 'initial overlay media state')
            .then((bytes) {
              if (mounted && _mediaInfo.thumbnail == initialThumb) {
                setState(() => _thumbnailBytes = bytes);
              }
            })
            .catchError((error, stackTrace) {
              logWarning(
                'DesktopWidget',
                'Initial media artwork base64 decoding failed: $error\n$stackTrace',
              );
            });
      }
      _mediaSubscription = MediaSessionService().mediaStream.listen(
        _onMediaInfoChanged,
      );
      MediaSessionService().start(owner: 'overlay');
    } else if (!needed && _mediaSubscription != null) {
      _mediaSubscription?.cancel();
      _mediaSubscription = null;
      _thumbnailBytes = null;
      MediaSessionService().stop(owner: 'overlay');
    }
  }

  void _onMediaInfoChanged(MediaInfo info) {
    if (!mounted || !_needsMediaSession) return;
    final hasChanged =
        info.title != _mediaInfo.title ||
        info.artist != _mediaInfo.artist ||
        info.album != _mediaInfo.album ||
        info.status != _mediaInfo.status ||
        info.source != _mediaInfo.source ||
        info.sessionId != _mediaInfo.sessionId ||
        info.canPlay != _mediaInfo.canPlay ||
        info.canPause != _mediaInfo.canPause ||
        info.canGoNext != _mediaInfo.canGoNext ||
        info.canGoPrevious != _mediaInfo.canGoPrevious ||
        info.duration != _mediaInfo.duration ||
        info.hasDuration != _mediaInfo.hasDuration ||
        info.hasPosition != _mediaInfo.hasPosition;
    final thumbChanged = info.thumbnail != _mediaInfo.thumbnail;

    if (hasChanged) {
      logInfo(
        'DesktopWidget',
        'Media data bound to overlay: source=${info.source.isEmpty ? "unknown" : info.source}, status=${info.status}.',
      );
    }

    if (thumbChanged) {
      final targetThumb = info.thumbnail;
      if (targetThumb.isNotEmpty) {
        _decodeMediaThumbnailAsync(targetThumb, 'overlay media update')
            .then((bytes) {
              if (mounted && _mediaInfo.thumbnail == targetThumb) {
                setState(() => _thumbnailBytes = bytes);
              }
            })
            .catchError((error, stackTrace) {
              if (mounted) {
                setState(() => _thumbnailBytes = null);
                logWarning(
                  'DesktopWidget',
                  'Media artwork base64 decoding failed: $error\n$stackTrace',
                );
              }
            });
      } else {
        _thumbnailBytes = null;
      }
    } else if (info.thumbnail.isEmpty) {
      _thumbnailBytes = null;
    }

    _mediaInfo = info;
    _updatePlaybackPosition(info);

    if (hasChanged || thumbChanged) {
      setState(() {});
    }
  }

  Future<void> _initSettings() async {
    logInfo(
      'DesktopWidget',
      'Initializing settings and registering settings file watcher...',
    );
    late final WidgetSettings loaded;
    if (widget.initialSettings != null) {
      loaded = widget.initialSettings!;
    } else {
      try {
        loaded = await _settingsService.loadSettings();
      } catch (e, st) {
        logError(
          'DesktopWidget',
          'Failed to initialize widget settings',
          e,
          st,
        );
        if (mounted) {
          setState(() {
            _startupError = 'Widget settings could not be loaded.';
            _isLoading = false;
          });
        }
        return;
      }
    }
    if (!mounted) return;
    if (loaded.exitOverlay) {
      logInfo(
        'DesktopWidget',
        'Startup exitOverlay flag was true. Clearing on disk to prevent file-watcher re-exit.',
      );
      loaded.exitOverlay = false;
      await _settingsService.saveSettings(loaded);
    }
    if (mounted) {
      setState(() {
        _settings = loaded;
        _systemMetrics = const SystemMetricsSnapshot();
        _isLoading = false;
        _visualEditorModeActive = loaded.editorMode;
      });
      if (_settingsNeedSystemMetrics(loaded)) {
        unawaited(_refreshSystemMetrics());
      }
      if (_needsSystemStats) _updateSystemStats();
      if (_needsWeather) _startWeatherTimer();
      _syncMediaServiceState();
      if (loaded.widgetTemplate == 'taskbar_dock') {
        unawaited(_refreshDockWindows());
      }
      _syncConnectivityService();
      if (loaded.widgetTemplate == 'taskbar_discord') {
        _discordSub = DiscordIpcService.instance.stream.listen((_) {
          if (mounted) setState(() {});
        });
      }
      if (loaded.widgetTemplate == 'taskbar_steam') {
        _steamSub = SteamMonitorService.instance.stream.listen((_) {
          if (mounted) setState(() {});
        });
      }
      _syncNeonAnimation();
      _resetInactivityTimer();
      unawaited(SystemOptimizerService.instance.optimizeMemory());
      unawaited(SystemOptimizerService.instance.setLowPowerMode(true));
      if (widget.initialSettings == null) {
        try {
          await windowManager.setBackgroundColor(Colors.transparent);
          await windowManager.setHasShadow(false);
          await windowManager.setOpacity(1.0);
          await windowManager.show();
        } catch (e, st) {
          debugPrint('Swallowed Error in lib/widgets/desktop_widget.dart: $e');
          debugPrint(st.toString());
        }
      }
    }

    final file = await _settingsService.settingsFile;
    final parentDir = file.parent;
    final targetFileName = file.uri.pathSegments.last;
    logInfo(
      'DesktopWidget',
      'Watching directory for settings changes ($targetFileName): ${parentDir.path}',
    );
    _settingsWatcher = parentDir.watch().listen((event) {
      if (!event.path.endsWith(targetFileName)) return;
      _watcherDebounce?.cancel();
      _watcherDebounce = Timer(const Duration(milliseconds: 150), () async {
        if (!mounted) return;
        if (_isSavingBoundsLocally || _isUserInteractingWithWindow) {
          // Ignore settings file notifications generated by our own window resize/move saves
          // or while user is actively moving/resizing the window
          return;
        }
        final updated = await _settingsService.loadSettings();
        if (!mounted) return;

        if (updated.exitOverlay) {
          if (_overlayShutdownStarted) return;
          _overlayShutdownStarted = true;
          logInfo(
            'DesktopWidget',
            'Exit overlay request received from dashboard; stopping owned '
                'services before process exit.',
          );
          _settingsWatcher?.cancel();
          _watcherDebounce?.cancel();
          _mediaSubscription?.cancel();
          _connectivitySubscription?.cancel();
          MediaSessionService().stop(owner: 'overlay');
          SystemConnectivityService.instance.stop(owner: 'overlay');
          logInfo(
            'DesktopWidget',
            'Overlay shutdown services stopped; process exiting now (code 0).',
          );
          exit(0);
        }

        final prevEditorMode = _settings.editorMode;
        try {
          final isTaskbar = updated.widgetTemplate.startsWith('taskbar_');
          final usesNativeTaskbarAppBar =
              Platform.isWindows && updated.widgetTemplate == 'taskbar_dock';
          final isReplacementTaskbar =
              updated.widgetTemplate == 'taskbar_dock' &&
              updated.taskbarSettings.nativeTaskbarHideEnabled;
          if (!usesNativeTaskbarAppBar) {
            await windowManager.setMinimumSize(
              isTaskbar ? const Size(120, 36) : const Size(180, 60),
            );
          }
          final currentSize = await windowManager.getSize();
          final widthDelta = (updated.width - currentSize.width).abs();
          final heightDelta = (updated.height - currentSize.height).abs();
          if (!usesNativeTaskbarAppBar &&
              !isReplacementTaskbar &&
              (widthDelta >= 3.0 || heightDelta >= 3.0)) {
            logInfo(
              'DesktopWidget',
              'Resizing window overlay to: ${updated.width}x${updated.height}',
            );
            _isApplyingExternalResize = true;
            try {
              await windowManager.setSize(Size(updated.width, updated.height));
            } finally {
              Future.delayed(const Duration(milliseconds: 300), () {
                if (mounted) {
                  _isApplyingExternalResize = false;
                }
              });
            }
          }

          if (usesNativeTaskbarAppBar &&
              (updated.taskbarSettings.taskbarPosition !=
                      _settings.taskbarSettings.taskbarPosition ||
                  widthDelta >= 3.0 ||
                  heightDelta >= 3.0)) {
            try {
              final configuration = await _taskbarConfigurationService
                  .applyNativeDock(
                    edge: updated.taskbarSettings.taskbarPosition,
                    thickness: updated.height.round().clamp(24, 256).toInt(),
                    length: updated.width.round(),
                    autoHide: updated.taskbarSettings.autoHideEnabled,
                    revision: updated.taskbarSettings.configurationVersion,
                  );
              logInfo(
                'DesktopWidget',
                'Native AppBar configuration applied at revision '
                    '${configuration.revision}; bounds='
                    '${configuration.left},${configuration.top},'
                    '${configuration.right},${configuration.bottom}.',
              );
            } catch (error, stackTrace) {
              logError(
                'DesktopWidget',
                'Could not apply the updated native AppBar configuration.',
                error,
                stackTrace,
              );
            }
          } else if (isTaskbar &&
              !isReplacementTaskbar &&
              !usesNativeTaskbarAppBar &&
              (updated.taskbarSettings.taskbarPosition !=
                      _settings.taskbarSettings.taskbarPosition ||
                  widthDelta >= 3.0 ||
                  heightDelta >= 3.0)) {
            try {
              final primaryDisplay = await ScreenRetriever.instance
                  .getPrimaryDisplay();
              final screenSize = primaryDisplay.size;
              final posType = updated.taskbarSettings.taskbarPosition;
              Offset targetPos;
              if (posType == 'top') {
                targetPos = Offset((screenSize.width - updated.width) / 2, 8);
              } else if (posType == 'left') {
                targetPos = Offset(8, (screenSize.height - updated.height) / 2);
              } else if (posType == 'right') {
                targetPos = Offset(
                  screenSize.width - updated.width - 8,
                  (screenSize.height - updated.height) / 2,
                );
              } else {
                targetPos = Offset(
                  (screenSize.width - updated.width) / 2,
                  screenSize.height - updated.height - 10,
                );
              }
              await windowManager.setPosition(targetPos);
            } catch (_) {}
          }
        } catch (_) {}

        if (!_usesNativeTaskbarAppBar &&
            updated.alwaysOnTop != _settings.alwaysOnTop) {
          logInfo(
            'DesktopWidget',
            'Updating alwaysOnTop constraint to: ${updated.alwaysOnTop}',
          );
          try {
            await windowManager.setAlwaysOnTop(updated.alwaysOnTop);
          } catch (_) {}
        }

        final prevLoc = _settings.weatherLocation;
        final updatedSystemMetrics = await _readSystemMetrics(updated);
        setState(() {
          _settings = updated;
          _systemMetrics =
              updatedSystemMetrics ??
              (_settingsNeedSystemMetrics(updated)
                  ? _systemMetrics
                  : const SystemMetricsSnapshot());
          if (updated.editorMode != prevEditorMode) {
            _visualEditorModeActive = updated.editorMode;
          }
        });
        _syncMediaServiceState();
        _syncConnectivityService();
        _syncNeonAnimation();
        if (updated.weatherLocation != prevLoc &&
            updated.weatherLocation.trim().isNotEmpty) {
          _fetchWeatherAndUpdate();
        }
        if (updated.editorMode != prevEditorMode) {
          _resetInactivityTimer();
        }
      });
    });
  }

  void _syncNeonAnimation() {
    if (_settings.widgetTemplate == 'animated_neon') {
      if (!_neonAnimationController.isAnimating) {
        _neonAnimationController.repeat();
      }
    } else {
      if (_neonAnimationController.isAnimating) {
        _neonAnimationController.stop();
      }
    }
  }

  void _syncMediaServiceState() {
    _syncMediaSubscription();
  }

  Future<void> _refreshDockWindows() async {
    if (_isRefreshingDockWindows || !Platform.isWindows) return;
    _isRefreshingDockWindows = true;
    try {
      final windows = await WindowsTaskbarService.instance.getDesktopWindows();
      if (!mounted || listEquals(windows, _dockWindows)) return;
      setState(() {
        _dockWindows
          ..clear()
          ..addAll(windows);
      });
    } finally {
      _isRefreshingDockWindows = false;
    }
  }

  Future<void> _activateDockWindow(DockWindowInfo window) async {
    final activated = await WindowsTaskbarService.instance
        .activateDesktopWindow(window.handle);
    if (activated) await _refreshDockWindows();
  }

  Future<void> _runTaskbarAction(String command) async {
    await WindowsTaskbarService.instance.runTaskbarCommand(command);
  }

  Widget _buildTaskbarActionButton(
    String command,
    IconData icon,
    String tooltip,
  ) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        onEnter: (_) {
          if (_hoveredTaskbarActions.add(command)) setState(() {});
        },
        onExit: (_) {
          if (_hoveredTaskbarActions.remove(command)) setState(() {});
        },
        child: AnimatedScale(
          scale: _hoveredTaskbarActions.contains(command) ? 1.12 : 1,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          child: InkWell(
            onTap: () => unawaited(_runTaskbarAction(command)),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: Icon(
                icon,
                size: 18,
                color: _hoveredTaskbarActions.contains(command)
                    ? Color(_settings.taskbarAccentColor)
                    : Color(_settings.taskbarIconColor),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTaskbarRunningApps() {
    if (_dockWindows.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: _dockWindows.take(5).map((window) {
        return Tooltip(
          message: window.title,
          child: InkWell(
            onTap: () => _activateDockWindow(window),
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 36,
              height: 36,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    _dockWindowIcon(window),
                    size: 20,
                    color: window.isForeground
                        ? Color(_settings.taskbarAccentColor)
                        : Color(_settings.taskbarIconColor),
                  ),
                  if (window.isForeground)
                    Positioned(
                      bottom: 1,
                      child: Container(
                        width: 12,
                        height: 2,
                        decoration: BoxDecoration(
                          color: Color(_settings.taskbarAccentColor),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Future<void> _launchDockElement(DockItemElement element) async {
    if (element.actionType == 'dashboard') {
      _openDashboard(
        element.actionPayload.isNotEmpty
            ? element.actionPayload
            : 'desktop_studio',
      );
      return;
    }
    if (element.actionType == 'default' ||
        element.actionType == 'app' ||
        element.actionType == 'url') {
      if (element.actionPayload.trim().isEmpty) {
        logWarning(
          'DesktopWidget',
          'Dock item "${element.label}" has no launch target configured.',
        );
        return;
      }
      await WindowsTaskbarService.instance.launchDockItem(
        element.actionPayload,
      );
      return;
    }
    logWarning(
      'DesktopWidget',
      'Dock item "${element.label}" uses unsupported action '
          '"${element.actionType}".',
    );
  }

  IconData _dockWindowIcon(DockWindowInfo window) {
    final executable = window.executable
        .split(RegExp(r'[\\/]'))
        .last
        .toLowerCase();
    if (executable.contains('explorer')) return Icons.folder_rounded;
    if (executable.contains('chrome') ||
        executable.contains('msedge') ||
        executable.contains('firefox')) {
      return Icons.language_rounded;
    }
    if (executable.contains('code')) return Icons.code_rounded;
    if (executable.contains('terminal') ||
        executable == 'wt.exe' ||
        executable.contains('powershell') ||
        executable == 'cmd.exe') {
      return Icons.terminal_rounded;
    }
    return Icons.window_rounded;
  }

  bool get _needsMediaSession {
    if (_settings.widgetTemplate == 'sleep_weather' ||
        _settings.widgetTemplate == 'taskbar_dock' ||
        _settings.widgetTemplate == 'taskbar_media') {
      return true;
    }
    return _settings.widgetTemplate == 'custom' &&
        (_settings.showMediaControl ||
            _settings.customElements.any(
              (element) => MediaElementType.contains(element.type),
            ));
  }

  @override
  void dispose() {
    _timer.cancel();
    windowManager.removeListener(this);
    _settingsWatcher?.cancel();
    _watcherDebounce?.cancel();
    _boundsSaveDebounce?.cancel();
    _neonAnimationController.dispose();
    _inactivityTimer?.cancel();
    _weatherTimer?.cancel();
    _weatherQueryController.dispose();
    _mediaSubscription?.cancel();
    _mediaSubscription = null;
    _thumbnailBytes = null;
    _connectivitySubscription?.cancel();
    _discordSub?.cancel();
    _steamSub?.cancel();
    _playbackPositionNotifier.dispose();
    MediaSessionService().stop(owner: 'overlay');
    SystemConnectivityService.instance.stop(owner: 'overlay');
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}
    unawaited(SystemOptimizerService.instance.optimizeMemory());
    super.dispose();
  }

  @override
  void onWindowBlur() {
    if (_visualEditorModeActive) {
      logInfo(
        'DesktopWidget',
        'Window blurred. Deactivating visual editor mode.',
      );
      _exitVisualEditorMode();
    }
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    if (_settings.editorMode &&
        _visualEditorModeActive &&
        !_settings.isLocked) {
      _inactivityTimer = Timer(const Duration(seconds: 10), () {
        logInfo(
          'DesktopWidget',
          '10 seconds of inactivity. Deactivating visual editor mode.',
        );
        _exitVisualEditorMode();
      });
    }
  }

  void _handleInteraction() {
    if (_settings.editorMode && !_settings.isLocked) {
      if (!_visualEditorModeActive) {
        setState(() {
          _visualEditorModeActive = true;
        });
      }
      _resetInactivityTimer();
    }
  }

  @override
  void onWindowResized() {
    if (_isApplyingExternalResize ||
        _isTaskbarReplacement ||
        _usesNativeTaskbarAppBar) {
      return;
    }
    _handleInteraction();
    if (_isUserInteractingWithWindow) return;
    _scheduleWindowBoundsSave();
  }

  @override
  void onWindowMoved() {
    if (_isApplyingExternalResize ||
        _isTaskbarReplacement ||
        _usesNativeTaskbarAppBar) {
      return;
    }
    _handleInteraction();
    if (_isUserInteractingWithWindow) return;
    _scheduleWindowBoundsSave();
  }

  void _scheduleWindowBoundsSave({bool immediate = false}) {
    if (_isApplyingExternalResize ||
        _isUserInteractingWithWindow ||
        _isTaskbarReplacement ||
        _usesNativeTaskbarAppBar) {
      return;
    }
    _boundsSaveDebounce?.cancel();
    _boundsSaveDebounce = Timer(
      Duration(milliseconds: immediate ? 350 : 650),
      () async {
        if (!mounted ||
            _isApplyingExternalResize ||
            _isUserInteractingWithWindow) {
          return;
        }
        try {
          final size = await windowManager.getSize();
          final position = await windowManager.getPosition();

          final roundedW = size.width.roundToDouble();
          final roundedH = size.height.roundToDouble();
          final roundedX = position.dx.roundToDouble();
          final roundedY = position.dy.roundToDouble();

          final deltaW = (roundedW - _settings.width).abs();
          final deltaH = (roundedH - _settings.height).abs();
          final deltaX = (roundedX - (_settings.posX ?? roundedX)).abs();
          final deltaY = (roundedY - (_settings.posY ?? roundedY)).abs();

          if (deltaW < 2.0 && deltaH < 2.0 && deltaX < 2.0 && deltaY < 2.0) {
            return;
          }

          _isSavingBoundsLocally = true;
          try {
            final updated = await _settingsService.updateSettings(
              (current) => current.copyWith(
                width: roundedW,
                height: roundedH,
                posX: roundedX,
                posY: roundedY,
              ),
            );
            if (!mounted) return;
            setState(() => _settings = updated);
          } finally {
            Future.delayed(const Duration(milliseconds: 400), () {
              if (mounted) {
                _isSavingBoundsLocally = false;
              }
            });
          }
        } catch (e, st) {
          logError(
            'DesktopWidget',
            'Failed to save widget window bounds',
            e,
            st,
          );
        }
      },
    );
  }

  void _exitVisualEditorMode() {
    _inactivityTimer?.cancel();
    if (_visualEditorModeActive) {
      setState(() {
        _visualEditorModeActive = false;
      });
    }
  }

  Future<void> _applyAutoSizing() async {
    final isTaskbar = _settings.widgetTemplate.startsWith('taskbar_');
    if (_usesNativeTaskbarAppBar) return;
    if (_settings.widgetTemplate == 'taskbar_dock' &&
        _settings.taskbarSettings.nativeTaskbarHideEnabled) {
      return;
    }
    final defaults =
        WidgetSettings.templateDefaults[_settings.widgetTemplate] ??
        {'width': 360.0, 'height': 200.0, 'sizeFactor': 1.0};
    final baseWidth =
        _settings.widgetTemplate == 'custom' && _settings.width > 0
        ? _settings.width
        : defaults['width']!;
    final baseHeight =
        _settings.widgetTemplate == 'custom' && _settings.height > 0
        ? _settings.height
        : defaults['height']!;

    final targetWidth =
        ((isTaskbar ? baseWidth : (baseWidth + 40.0)) * _settings.sizeFactor)
            .clamp(isTaskbar ? 120.0 : 180.0, 1920.0);
    final targetHeight =
        ((isTaskbar ? baseHeight : (baseHeight + 32.0)) * _settings.sizeFactor)
            .clamp(isTaskbar ? 36.0 : 60.0, 1080.0);

    setState(() {
      _settings.width = targetWidth;
      _settings.height = targetHeight;
    });
    try {
      await windowManager.setSize(Size(targetWidth, targetHeight));
    } catch (_) {}
    _scheduleWindowBoundsSave(immediate: true);
  }

  void _openDashboard([String? tab]) {
    try {
      final args = (tab != null && tab.isNotEmpty)
          ? ['--open-tab=$tab']
          : <String>[];
      Process.start(Platform.resolvedExecutable, args);
    } catch (e) {
      logWarning(
        'DesktopWidget',
        'Could not launch main application window: $e',
      );
    }
  }

  Future<void> _cyclePerformanceProfile() async {
    const order = ['balanced', 'performance', 'power_saver', 'high_quality'];
    final current = _settings.performanceProfile;
    final idx = order.indexOf(current);
    final next = order[(idx + 1) % order.length];
    final updated = await DeviceOptimizationService.instance.applyProfile(
      profileId: next,
      currentSettings: _settings,
      settingsService: _settingsService,
    );
    if (mounted) {
      setState(() => _settings = updated);
    }
  }

  void _openWidgetCustomization() => _openDashboard('widgets');

  Future<void> _showContextMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final RenderBox? overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final isLocked = _settings.isLocked;
    final isEdit = _visualEditorModeActive && !isLocked;
    final isAutoSizing = _settings.autoSizing;

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      color: const Color(0xFF141724),
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: const Color(0xFF38BDF8).withValues(alpha: 0.25),
          width: 1.2,
        ),
      ),
      items: [
        const PopupMenuItem<String>(
          value: 'customize',
          height: 40,
          child: Row(
            children: [
              Icon(Icons.tune_rounded, size: 17, color: Color(0xFF38BDF8)),
              SizedBox(width: 10),
              Text(
                'Customize Widget',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'lock',
          height: 40,
          child: Row(
            children: [
              Icon(
                isLocked ? Icons.lock_rounded : Icons.lock_open_rounded,
                size: 17,
                color: isLocked
                    ? const Color(0xFFF43F5E)
                    : const Color(0xFF10B981),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isLocked ? 'Lock Position (ON)' : 'Lock Position (OFF)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (isLocked)
                const Icon(
                  Icons.check_rounded,
                  size: 15,
                  color: Color(0xFFF43F5E),
                ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'edit',
          height: 40,
          enabled: !isLocked,
          child: Row(
            children: [
              Icon(
                isEdit
                    ? Icons.check_circle_outline_rounded
                    : Icons.crop_free_rounded,
                size: 17,
                color: isLocked ? Colors.white24 : const Color(0xFF38BDF8),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isEdit
                      ? 'Exit Edit Mode'
                      : 'Edit Widget (Reposition / Resize)',
                  style: TextStyle(
                    color: isLocked ? Colors.white38 : Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (isEdit)
                const Icon(
                  Icons.check_rounded,
                  size: 15,
                  color: Color(0xFF38BDF8),
                ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'auto_size',
          height: 40,
          child: Row(
            children: [
              Icon(
                Icons.aspect_ratio_rounded,
                size: 17,
                color: isAutoSizing ? const Color(0xFF10B981) : Colors.white60,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isAutoSizing ? 'Auto Sizing (ON)' : 'Auto Sizing (OFF)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (isAutoSizing)
                const Icon(
                  Icons.check_rounded,
                  size: 15,
                  color: Color(0xFF10B981),
                ),
            ],
          ),
        ),
        const PopupMenuItem<String>(
          value: 'reset_position',
          height: 40,
          child: Row(
            children: [
              Icon(
                Icons.restart_alt_rounded,
                size: 17,
                color: Colors.amberAccent,
              ),
              SizedBox(width: 10),
              Text(
                'Reset Position',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(height: 1),
        const PopupMenuItem<String>(
          value: 'close',
          height: 40,
          child: Row(
            children: [
              Icon(Icons.close_rounded, size: 17, color: Color(0xFFF43F5E)),
              SizedBox(width: 10),
              Text(
                'Close Widget',
                style: TextStyle(
                  color: Color(0xFFF43F5E),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (selected == null) return;
    switch (selected) {
      case 'customize':
        _openWidgetCustomization();
        break;
      case 'lock':
        final newLocked = !_settings.isLocked;
        setState(() {
          _settings.isLocked = newLocked;
          if (newLocked) {
            _visualEditorModeActive = false;
          }
        });
        unawaited(
          _settingsService.updateSettings(
            (c) => c.copyWith(isLocked: newLocked),
          ),
        );
        _scheduleWindowBoundsSave(immediate: true);
        break;
      case 'edit':
        if (_settings.isLocked) return;
        setState(() {
          _visualEditorModeActive = !_visualEditorModeActive;
          _settings.editorMode = _visualEditorModeActive;
        });
        unawaited(
          _settingsService.updateSettings(
            (c) => c.copyWith(editorMode: _visualEditorModeActive),
          ),
        );
        _resetInactivityTimer();
        _scheduleWindowBoundsSave(immediate: true);
        break;
      case 'auto_size':
        final newAutoSizing = !_settings.autoSizing;
        setState(() {
          _settings.autoSizing = newAutoSizing;
        });
        unawaited(
          _settingsService.updateSettings(
            (c) => c.copyWith(autoSizing: newAutoSizing),
          ),
        );
        if (newAutoSizing) {
          _applyAutoSizing();
        }
        _scheduleWindowBoundsSave(immediate: true);
        break;
      case 'reset_position':
        try {
          await windowManager.center();
          final pos = await windowManager.getPosition();
          setState(() {
            _settings.posX = pos.dx;
            _settings.posY = pos.dy;
          });
          unawaited(
            _settingsService.updateSettings(
              (c) => c.copyWith(posX: pos.dx, posY: pos.dy),
            ),
          );
          _scheduleWindowBoundsSave(immediate: true);
        } catch (_) {}
        break;
      case 'close':
        try {
          await windowManager.close();
        } catch (_) {
          exit(0);
        }
        break;
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  TextStyle _styleFor(
    String key, {
    required double baseSize,
    required FontWeight weight,
  }) {
    final textColor = Color(_settings.colorFor(key));
    return TextStyle(
      fontFamily: _settings.fontFor(key),
      fontSize: _settings.sizeFor(key, baseSize) * _settings.fontSizeMultiplier,
      fontWeight: weight,
      color: textColor,
      shadows: null,
    );
  }

  // ── Time parts ────────────────────────────────────────────────────────────

  String get _hours {
    if (_settings.use24HourFormat) {
      return _dateTime.hour.toString().padLeft(2, '0');
    }
    final h = _dateTime.hour % 12;
    return (h == 0 ? 12 : h).toString().padLeft(2, '0');
  }

  String get _minutes => _dateTime.minute.toString().padLeft(2, '0');
  String get _seconds => _dateTime.second.toString().padLeft(2, '0');
  String get _ampm => _dateTime.hour < 12 ? 'AM' : 'PM';
  String get _dayOfWeek => DateFormat('EEEE').format(_dateTime).toUpperCase();
  String get _month => DateFormat('MMMM d').format(_dateTime).toUpperCase();
  String get _year => _dateTime.year.toString();

  // ── Background ────────────────────────────────────────────────────────────

  Widget _buildBackground(BuildContext context) {
    if (_settings.widgetTemplate.startsWith('taskbar_')) {
      return const SizedBox.shrink();
    }
    final br = BorderRadius.circular(24);

    if (_settings.backgroundType == 'animated' &&
        _settings.animatedBg.isNotEmpty) {
      return buildAnimatedBackground(_settings.animatedBg, borderRadius: br);
    }

    switch (_settings.backgroundType) {
      case 'none':
        return const SizedBox.shrink();

      case 'solid':
        return Container(
          decoration: BoxDecoration(
            color: Color(_settings.solidColor),
            borderRadius: br,
          ),
        );

      case 'custom_gradient':
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _settings.customGradientColors
                  .map((c) => Color(c))
                  .toList(),
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: br,
          ),
        );

      case 'gradient':
        final idx = _settings.curatedIndex.clamp(0, _gradientColors.length - 1);
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _gradientColors[idx],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: br,
            boxShadow: null,
          ),
        );

      case 'curated':
        final idx = _settings.curatedIndex.clamp(
          0,
          _curatedWallpaperPaths.length - 1,
        );
        return ClipRRect(
          borderRadius: br,
          child: Container(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: ResizeImage(
                  AssetImage(_curatedWallpaperPaths[idx]),
                  width: 1200,
                  allowUpscaling: false,
                ),
                fit: _getBoxFit(_settings.wallpaperFit),
                repeat: _getImageRepeat(_settings.wallpaperFit),
                filterQuality: FilterQuality.medium,
                colorFilter: _settings.colorBoost
                    ? const ColorFilter.matrix([
                        1.20,
                        -0.15,
                        -0.05,
                        0.0,
                        10.0,
                        -0.10,
                        1.25,
                        -0.15,
                        0.0,
                        10.0,
                        -0.05,
                        -0.15,
                        1.20,
                        0.0,
                        10.0,
                        0.0,
                        0.0,
                        0.0,
                        1.0,
                        0.0,
                      ])
                    : null,
                onError: (error, stackTrace) {
                  logError(
                    'DesktopWidget',
                    'Failed to load curated wallpaper asset: ${_curatedWallpaperPaths[idx]}',
                    error,
                    stackTrace,
                  );
                },
              ),
              borderRadius: br,
            ),
          ),
        );

      case 'custom':
        if (_settings.customImagePath != null &&
            _settings.customImagePath!.isNotEmpty) {
          return ClipRRect(
            borderRadius: br,
            child: Container(
              decoration: BoxDecoration(
                image: DecorationImage(
                  image: ResizeImage(
                    FileImage(File(_settings.customImagePath!)),
                    width: 1200,
                    allowUpscaling: false,
                  ),
                  fit: _getBoxFit(_settings.wallpaperFit),
                  repeat: _getImageRepeat(_settings.wallpaperFit),
                  filterQuality: FilterQuality.high,
                  colorFilter: _settings.colorBoost
                      ? const ColorFilter.matrix([
                          1.20,
                          -0.15,
                          -0.05,
                          0.0,
                          10.0,
                          -0.10,
                          1.25,
                          -0.15,
                          0.0,
                          10.0,
                          -0.05,
                          -0.15,
                          1.20,
                          0.0,
                          10.0,
                          0.0,
                          0.0,
                          0.0,
                          1.0,
                          0.0,
                        ])
                      : null,
                  onError: (error, stackTrace) {
                    logError(
                      'DesktopWidget',
                      'Failed to load custom wallpaper image: ${_settings.customImagePath}',
                      error,
                      stackTrace,
                    );
                  },
                ),
                borderRadius: br,
              ),
            ),
          );
        }
        return Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF200122), Color(0xFF6f0000)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: br,
          ),
        );

      default:
        return const SizedBox.shrink();
    }
  }

  BoxFit _getBoxFit(String fitStr) {
    switch (fitStr) {
      case 'fit':
        return BoxFit.contain;
      case 'stretch':
        return BoxFit.fill;
      case 'center':
      case 'tile':
        return BoxFit.none;
      case 'span':
      case 'fill':
      default:
        return BoxFit.cover;
    }
  }

  ImageRepeat _getImageRepeat(String fitStr) {
    return fitStr == 'tile' ? ImageRepeat.repeat : ImageRepeat.noRepeat;
  }

  // ── 3D Transformations ─────────────────────────────────────────────────────

  Widget _apply3D(String key, Widget child) {
    final grad = _settings.gradientFor(key);
    if (grad != null && grad.length >= 2) {
      child = ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) => LinearGradient(
          colors: grad.map((c) => Color(c)).toList(),
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(bounds),
        child: child,
      );
    }

    final tx = _settings.translateXFor(key);
    final ty = _settings.translateYFor(key);
    final tz = _settings.translateZFor(key);
    final rx = _settings.rotateXFor(key) * (3.141592653589793 / 180.0);
    final ry = _settings.rotateYFor(key) * (3.141592653589793 / 180.0);
    final rz = _settings.rotateZFor(key) * (3.141592653589793 / 180.0);

    if (tx == 0.0 &&
        ty == 0.0 &&
        tz == 0.0 &&
        rx == 0.0 &&
        ry == 0.0 &&
        rz == 0.0) {
      return child;
    }

    final transform = Matrix4.identity()
      ..setEntry(3, 2, 0.001) // perspective
      ..translateByDouble(tx, ty, tz, 1.0)
      ..rotateX(rx)
      ..rotateY(ry)
      ..rotateZ(rz);

    return Transform(
      transform: transform,
      alignment: Alignment.center,
      child: child,
    );
  }

  // ── Clock parts ────────────────────────────────────────────────────────────

  Widget _buildHours({double baseSize = 42}) => _apply3D(
    ElementKey.hours,
    Text(
      _hours,
      style: _styleFor(
        ElementKey.hours,
        baseSize: baseSize,
        weight: FontWeight.bold,
      ),
    ),
  );

  Widget _buildMinutes({double baseSize = 42}) => _apply3D(
    ElementKey.minutes,
    Text(
      _minutes,
      style: _styleFor(
        ElementKey.minutes,
        baseSize: baseSize,
        weight: FontWeight.bold,
      ),
    ),
  );

  Widget _buildSeconds({double baseSize = 42}) => _apply3D(
    ElementKey.seconds,
    Text(
      _seconds,
      style: _styleFor(
        ElementKey.seconds,
        baseSize: baseSize,
        weight: FontWeight.bold,
      ),
    ),
  );

  Widget _buildAmPm({double baseSize = 13}) => _apply3D(
    ElementKey.ampm,
    Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        const SizedBox(height: 8),
        Text(
          _ampm,
          style: _styleFor(
            ElementKey.ampm,
            baseSize: baseSize,
            weight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  Widget _buildSeparator({double baseSize = 38}) {
    final sep = _styleFor(
      ElementKey.separator,
      baseSize: baseSize,
      weight: FontWeight.w300,
    );
    return _apply3D(ElementKey.separator, Text(':', style: sep));
  }

  Widget _buildDay({double baseSize = 11}) => _apply3D(
    ElementKey.day,
    Text(
      _dayOfWeek,
      style: _styleFor(
        ElementKey.day,
        baseSize: baseSize,
        weight: FontWeight.w600,
      ).copyWith(letterSpacing: 1.5),
    ),
  );

  Widget _buildDate({double baseSize = 11}) => _apply3D(
    ElementKey.date,
    Text(
      _month,
      style: _styleFor(
        ElementKey.date,
        baseSize: baseSize,
        weight: FontWeight.w500,
      ).copyWith(letterSpacing: 1.5),
    ),
  );

  Widget _buildYear({double baseSize = 11}) => _apply3D(
    ElementKey.year,
    Text(
      _year,
      style: _styleFor(
        ElementKey.year,
        baseSize: baseSize,
        weight: FontWeight.w500,
      ).copyWith(letterSpacing: 1.5),
    ),
  );

  // ── Clock & Date rows ──────────────────────────────────────────────────────

  Widget _buildClockRow({double baseSize = 42}) {
    final parts = <Widget>[
      _buildHours(baseSize: baseSize),
      _buildSeparator(baseSize: baseSize - 4),
      _buildMinutes(baseSize: baseSize),
    ];

    if (_settings.showSeconds) {
      parts.add(_buildSeparator(baseSize: baseSize - 4));
      parts.add(_buildSeconds(baseSize: baseSize));
    }

    if (!_settings.use24HourFormat) {
      parts.add(const SizedBox(width: 5));
      parts.add(_buildAmPm(baseSize: baseSize * 0.3));
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: parts,
    );
  }

  Widget _buildDateRow({double baseSize = 11}) {
    final bullet = TextStyle(
      color: Color(_settings.colorFor(ElementKey.date)).withValues(alpha: 0.4),
      fontSize: baseSize * _settings.fontSizeMultiplier,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDay(baseSize: baseSize),
        Text('  ·  ', style: bullet),
        _buildDate(baseSize: baseSize),
        Text('  ·  ', style: bullet),
        _buildYear(baseSize: baseSize),
      ],
    );
  }

  // ── Layout Templates ───────────────────────────────────────────────────────

  Widget _buildClassicLayout() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FittedBox(fit: BoxFit.scaleDown, child: _buildClockRow()),
        const SizedBox(height: 6),
        _apply3D(
          ElementKey.separator,
          Container(
            width: _settings.effectiveSeparatorWidth,
            height: _settings.effectiveSeparatorHeight,
            color: Color(_settings.colorFor(ElementKey.separator)),
          ),
        ),
        const SizedBox(height: 8),
        FittedBox(fit: BoxFit.scaleDown, child: _buildDateRow()),
      ],
    );
  }

  Widget _buildMinimalLayout() {
    final pipeColor = Color(_settings.colorFor(ElementKey.separator));
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildClockRow(baseSize: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: _apply3D(
              ElementKey.separator,
              Container(
                width: _settings.effectiveSeparatorWidth,
                height: _settings.effectiveSeparatorHeight,
                color: pipeColor,
              ),
            ),
          ),
          _buildDay(baseSize: 11),
          const SizedBox(width: 6),
          _buildDate(baseSize: 11),
        ],
      ),
    );
  }

  Widget _buildCyberLayout() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHours(baseSize: 42),
              const SizedBox(height: 2),
              _buildMinutes(baseSize: 42),
            ],
          ),
        ),
        if (_settings.showSeconds) ...[
          const SizedBox(height: 2),
          FittedBox(fit: BoxFit.scaleDown, child: _buildSeconds(baseSize: 16)),
        ],
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDay(baseSize: 8),
              const SizedBox(width: 6),
              _buildDate(baseSize: 8),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSplitLayout() {
    final barColor = Color(_settings.colorFor(ElementKey.separator));
    final monthAbbr = DateFormat('MMM').format(_dateTime).toUpperCase();
    final dayNum = _dateTime.day.toString();
    final weekdayAbbr = DateFormat('EEE').format(_dateTime).toUpperCase();

    final hoursStyle = _styleFor(
      ElementKey.hours,
      baseSize: 44,
      weight: FontWeight.w900,
    ).copyWith(height: 1.0);

    final minutesStyle = _styleFor(
      ElementKey.minutes,
      baseSize: 44,
      weight: FontWeight.w900,
    ).copyWith(height: 1.0);

    final monthStyle = _styleFor(
      ElementKey.day,
      baseSize: 19,
      weight: FontWeight.w900,
    ).copyWith(height: 1.05, letterSpacing: 0.5);

    final dayNumStyle = _styleFor(
      ElementKey.date,
      baseSize: 28,
      weight: FontWeight.w900,
    ).copyWith(height: 1.05);

    final weekStyle = _styleFor(
      ElementKey.year,
      baseSize: 14,
      weight: FontWeight.bold,
    ).copyWith(height: 1.05, letterSpacing: 0.5);

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Left Column: Stacked Hours & Minutes (Right-aligned)
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _apply3D(ElementKey.hours, Text(_hours, style: hoursStyle)),
              _apply3D(ElementKey.minutes, Text(_minutes, style: minutesStyle)),
              if (_settings.showSeconds) ...[
                const SizedBox(height: 2),
                _apply3D(
                  ElementKey.seconds,
                  Text(
                    _seconds,
                    style: _styleFor(
                      ElementKey.seconds,
                      baseSize: 14,
                      weight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(width: 14),

          // Glowing Vertical Gradient Divider Bar
          _apply3D(
            ElementKey.separator,
            Container(
              width: _settings.effectiveSeparatorWidth > 20
                  ? 4
                  : (_settings.effectiveSeparatorWidth < 2
                        ? 3.5
                        : _settings.effectiveSeparatorWidth),
              height: 76,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [barColor, const Color(0xFF8B5CF6)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(2),
                boxShadow: [
                  BoxShadow(
                    color: barColor.withValues(alpha: 0.5),
                    blurRadius: 10,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 14),

          // Right Column: Month, Day Number, Weekday (Left-aligned)
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _apply3D(ElementKey.day, Text(monthAbbr, style: monthStyle)),
              _apply3D(ElementKey.date, Text(dayNum, style: dayNumStyle)),
              _apply3D(ElementKey.year, Text(weekdayAbbr, style: weekStyle)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNeonLayout() {
    final boxColor = Color(_settings.colorFor(ElementKey.neonBox));
    final timeColor = Color(_settings.colorFor(ElementKey.hours));
    final dateColor = Color(_settings.colorFor(ElementKey.date));
    final sepColor = Color(_settings.colorFor(ElementKey.separator));
    final badgeColor = Color(_settings.colorFor(ElementKey.neonBadge));
    final dividerColor = Color(_settings.colorFor(ElementKey.neonDivider));
    final cpuColor = Color(_settings.colorFor(ElementKey.cpu));
    final ramColor = Color(_settings.colorFor(ElementKey.ram));

    return _apply3D(
      ElementKey.neonBox,
      Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            // Wide atmospheric neon aura
            BoxShadow(
              color: boxColor.withValues(alpha: 0.35),
              blurRadius: 40,
              spreadRadius: 2,
            ),
            // Core bright neon glow
            BoxShadow(
              color: boxColor.withValues(alpha: 0.55),
              blurRadius: 20,
              spreadRadius: 0,
            ),
            // Deep spatial shadow
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: 0.14),
                boxColor.withValues(alpha: 0.16),
                boxColor.withValues(alpha: 0.05),
                Colors.black.withValues(alpha: 0.35),
              ],
              stops: const [0.0, 0.25, 0.7, 1.0],
            ),
            border: Border.all(
              color: boxColor.withValues(alpha: 0.85),
              width: 1.8,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. Top Header Row: Day Capsule Badge + Neon Status
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _apply3D(
                    ElementKey.day,
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3.5,
                      ),
                      decoration: BoxDecoration(
                        color: dateColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: dateColor.withValues(alpha: 0.45),
                          width: 1.0,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: dateColor.withValues(alpha: 0.25),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.calendar_today_rounded,
                            size: 10 * _settings.fontSizeMultiplier,
                            color: dateColor,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            DateFormat('EEEE').format(_dateTime).toUpperCase(),
                            style:
                                _styleFor(
                                  ElementKey.day,
                                  baseSize: 10,
                                  weight: FontWeight.w800,
                                ).copyWith(
                                  color: dateColor,
                                  letterSpacing: 1.8,
                                  shadows: [
                                    Shadow(
                                      color: dateColor.withValues(alpha: 0.6),
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_settings.showNeonBadge)
                    _apply3D(
                      ElementKey.neonBadge,
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: badgeColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: badgeColor.withValues(alpha: 0.45),
                            width: 0.8,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: badgeColor.withValues(alpha: 0.25),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: badgeColor,
                                boxShadow: [
                                  BoxShadow(
                                    color: badgeColor.withValues(alpha: 0.8),
                                    blurRadius: 6,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              'GLASS NEON',
                              style:
                                  _styleFor(
                                    ElementKey.neonBadge,
                                    baseSize: 8.5,
                                    weight: FontWeight.w900,
                                  ).copyWith(
                                    color: badgeColor,
                                    letterSpacing: 1.5,
                                    shadows: [
                                      Shadow(
                                        color: badgeColor.withValues(
                                          alpha: 0.6,
                                        ),
                                        blurRadius: 6,
                                      ),
                                    ],
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),

              // 2. Hero Center Clock Row
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    _apply3D(
                      ElementKey.hours,
                      Text(
                        _hours,
                        style:
                            _styleFor(
                              ElementKey.hours,
                              baseSize: 54,
                              weight: FontWeight.w900,
                            ).copyWith(
                              color: timeColor,
                              letterSpacing: -1.0,
                              shadows: [
                                Shadow(
                                  color: timeColor.withValues(alpha: 0.75),
                                  blurRadius: 16,
                                ),
                                Shadow(
                                  color: timeColor.withValues(alpha: 0.35),
                                  blurRadius: 32,
                                ),
                              ],
                            ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    _apply3D(
                      ElementKey.separator,
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Text(
                          ':',
                          style:
                              _styleFor(
                                ElementKey.separator,
                                baseSize: 48,
                                weight: FontWeight.w300,
                              ).copyWith(
                                color: sepColor,
                                shadows: [
                                  Shadow(
                                    color: sepColor.withValues(alpha: 0.8),
                                    blurRadius: 14,
                                  ),
                                  Shadow(
                                    color: sepColor.withValues(alpha: 0.4),
                                    blurRadius: 28,
                                  ),
                                ],
                              ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    _apply3D(
                      ElementKey.minutes,
                      Text(
                        _minutes,
                        style:
                            _styleFor(
                              ElementKey.minutes,
                              baseSize: 54,
                              weight: FontWeight.w900,
                            ).copyWith(
                              color: timeColor,
                              letterSpacing: -1.0,
                              shadows: [
                                Shadow(
                                  color: timeColor.withValues(alpha: 0.75),
                                  blurRadius: 16,
                                ),
                                Shadow(
                                  color: timeColor.withValues(alpha: 0.35),
                                  blurRadius: 32,
                                ),
                              ],
                            ),
                      ),
                    ),
                    if (_settings.showSeconds ||
                        !_settings.use24HourFormat) ...[
                      const SizedBox(width: 10),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!_settings.use24HourFormat)
                            _apply3D(
                              ElementKey.ampm,
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: timeColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: timeColor.withValues(alpha: 0.5),
                                    width: 0.8,
                                  ),
                                ),
                                child: Text(
                                  _ampm,
                                  style:
                                      _styleFor(
                                        ElementKey.ampm,
                                        baseSize: 10,
                                        weight: FontWeight.w800,
                                      ).copyWith(
                                        color: timeColor,
                                        letterSpacing: 1.0,
                                        shadows: [
                                          Shadow(
                                            color: timeColor.withValues(
                                              alpha: 0.6,
                                            ),
                                            blurRadius: 8,
                                          ),
                                        ],
                                      ),
                                ),
                              ),
                            ),
                          if (_settings.showSeconds) ...[
                            if (!_settings.use24HourFormat)
                              const SizedBox(height: 4),
                            _apply3D(
                              ElementKey.seconds,
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: sepColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: sepColor.withValues(alpha: 0.5),
                                    width: 0.8,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      _seconds,
                                      style:
                                          _styleFor(
                                            ElementKey.seconds,
                                            baseSize: 11,
                                            weight: FontWeight.w900,
                                          ).copyWith(
                                            color: sepColor,
                                            shadows: [
                                              Shadow(
                                                color: sepColor.withValues(
                                                  alpha: 0.7,
                                                ),
                                                blurRadius: 8,
                                              ),
                                            ],
                                          ),
                                    ),
                                    const SizedBox(width: 2),
                                    Text(
                                      'S',
                                      style: TextStyle(
                                        fontSize: 7,
                                        fontWeight: FontWeight.bold,
                                        color: sepColor.withValues(alpha: 0.7),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // 3. Glowing Laser Divider Line
              _apply3D(
                ElementKey.neonDivider,
                Container(
                  height: 1.5,
                  margin: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        dividerColor.withValues(alpha: 0.2),
                        dividerColor.withValues(alpha: 0.8),
                        boxColor.withValues(alpha: 0.8),
                        boxColor.withValues(alpha: 0.2),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.2, 0.45, 0.55, 0.8, 1.0],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: dividerColor.withValues(alpha: 0.5),
                        blurRadius: 6,
                        spreadRadius: 0.5,
                      ),
                    ],
                  ),
                ),
              ),

              // 4. Hardware Telemetry Deck (CPU & RAM Monitors)
              if (_settings.showCpu || _settings.showRam) ...[
                Row(
                  children: [
                    if (_settings.showCpu)
                      Expanded(
                        child: _apply3D(
                          ElementKey.cpu,
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: cpuColor.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: cpuColor.withValues(alpha: 0.3),
                                width: 0.8,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.memory_rounded,
                                          size:
                                              10 * _settings.fontSizeMultiplier,
                                          color: cpuColor,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          'CPU',
                                          style:
                                              _styleFor(
                                                ElementKey.cpu,
                                                baseSize: 8.5,
                                                weight: FontWeight.w800,
                                              ).copyWith(
                                                color: cpuColor,
                                                letterSpacing: 0.8,
                                              ),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      '${_cpuUsage.toStringAsFixed(0)}%',
                                      style:
                                          _styleFor(
                                            ElementKey.cpu,
                                            baseSize: 8.5,
                                            weight: FontWeight.w900,
                                          ).copyWith(
                                            color: cpuColor,
                                            shadows: [
                                              Shadow(
                                                color: cpuColor.withValues(
                                                  alpha: 0.7,
                                                ),
                                                blurRadius: 6,
                                              ),
                                            ],
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Container(
                                  width: double.infinity,
                                  height: 3.5,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                  child: FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: (_cpuUsage / 100.0).clamp(
                                      0.02,
                                      1.0,
                                    ),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: cpuColor,
                                        borderRadius: BorderRadius.circular(2),
                                        boxShadow: [
                                          BoxShadow(
                                            color: cpuColor.withValues(
                                              alpha: 0.8,
                                            ),
                                            blurRadius: 4,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (_settings.showCpu && _settings.showRam)
                      const SizedBox(width: 8),
                    if (_settings.showRam)
                      Expanded(
                        child: _apply3D(
                          ElementKey.ram,
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: ramColor.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: ramColor.withValues(alpha: 0.3),
                                width: 0.8,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.developer_board_rounded,
                                          size:
                                              10 * _settings.fontSizeMultiplier,
                                          color: ramColor,
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          'RAM',
                                          style:
                                              _styleFor(
                                                ElementKey.ram,
                                                baseSize: 8.5,
                                                weight: FontWeight.w800,
                                              ).copyWith(
                                                color: ramColor,
                                                letterSpacing: 0.8,
                                              ),
                                        ),
                                      ],
                                    ),
                                    Text(
                                      '${_ramUsage.toStringAsFixed(0)}%',
                                      style:
                                          _styleFor(
                                            ElementKey.ram,
                                            baseSize: 8.5,
                                            weight: FontWeight.w900,
                                          ).copyWith(
                                            color: ramColor,
                                            shadows: [
                                              Shadow(
                                                color: ramColor.withValues(
                                                  alpha: 0.7,
                                                ),
                                                blurRadius: 6,
                                              ),
                                            ],
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Container(
                                  width: double.infinity,
                                  height: 3.5,
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                  child: FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: (_ramUsage / 100.0).clamp(
                                      0.02,
                                      1.0,
                                    ),
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: ramColor,
                                        borderRadius: BorderRadius.circular(2),
                                        boxShadow: [
                                          BoxShadow(
                                            color: ramColor.withValues(
                                              alpha: 0.8,
                                            ),
                                            blurRadius: 4,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
              ],

              // 5. Bottom Deck: Date & Year
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _apply3D(
                    ElementKey.date,
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.access_time_rounded,
                          size: 11 * _settings.fontSizeMultiplier,
                          color: dateColor.withValues(alpha: 0.8),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          DateFormat('d MMMM').format(_dateTime).toUpperCase(),
                          style:
                              _styleFor(
                                ElementKey.date,
                                baseSize: 11,
                                weight: FontWeight.w700,
                              ).copyWith(
                                color: dateColor,
                                letterSpacing: 1.5,
                                shadows: [
                                  Shadow(
                                    color: dateColor.withValues(alpha: 0.6),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dateColor.withValues(alpha: 0.6),
                      boxShadow: [
                        BoxShadow(
                          color: dateColor.withValues(alpha: 0.8),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                  _apply3D(
                    ElementKey.year,
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: dateColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: dateColor.withValues(alpha: 0.3),
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        _year,
                        style:
                            _styleFor(
                              ElementKey.year,
                              baseSize: 10,
                              weight: FontWeight.w800,
                            ).copyWith(
                              color: dateColor,
                              letterSpacing: 1.4,
                              shadows: [
                                Shadow(
                                  color: dateColor.withValues(alpha: 0.6),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAnimatedNeonLayout() {
    final Color outerColor = Color(_settings.colorFor(ElementKey.glowOuter));
    final Color innerColor = Color(_settings.colorFor(ElementKey.glowInner));

    return AnimatedBuilder(
      animation: _neonAnimationController,
      builder: (context, child) {
        final double progress =
            (1.0 - math.cos(_neonAnimationController.value * 2 * math.pi)) /
            2.0;

        final double outerHeight = 120.0 + 220.0 * progress;
        final double outerTop = 110.0 - 110.0 * progress;

        final double innerHeight = 80.0 + 180.0 * progress;
        final double innerTop = 130.0 - 90.0 * progress;

        final double textTop = 145.0 - 15.0 * progress;
        final double textScaleY = 0.4 + 0.6 * progress;

        final isTransparent =
            _settings.backgroundType == 'none' || _settings.opacity == 0.0;

        return FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: 340,
            height: 340,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Outer Ring
                Positioned(
                  top: outerTop,
                  left: 0,
                  width: 340,
                  height: outerHeight,
                  child: _apply3D(
                    ElementKey.glowOuter,
                    Container(
                      key: const Key('glow-outer'),
                      decoration: BoxDecoration(
                        gradient: isTransparent
                            ? null
                            : const LinearGradient(
                                colors: [Color(0xFF050528), Color(0xFF0A0A55)],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                        color: isTransparent ? Colors.transparent : null,
                        border: Border.all(color: outerColor, width: 10),
                        borderRadius: BorderRadius.all(
                          Radius.elliptical(170, outerHeight / 2),
                        ),
                        boxShadow: null,
                      ),
                    ),
                  ),
                ),

                // Inner Ring
                Positioned(
                  top: innerTop,
                  left: 40,
                  width: 260,
                  height: innerHeight,
                  child: _apply3D(
                    ElementKey.glowInner,
                    Container(
                      key: const Key('glow-inner'),
                      decoration: BoxDecoration(
                        gradient: isTransparent
                            ? null
                            : const LinearGradient(
                                colors: [Color(0xFF0A0A3C), Color(0xFF000000)],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                        color: isTransparent ? Colors.transparent : null,
                        border: Border.all(color: innerColor, width: 6),
                        borderRadius: BorderRadius.all(
                          Radius.elliptical(130, innerHeight / 2),
                        ),
                        boxShadow: null,
                      ),
                    ),
                  ),
                ),

                // Inner Background
                Positioned(
                  top: innerTop + 6,
                  left: 46,
                  width: 248,
                  height: innerHeight - 12,
                  child: _apply3D(
                    ElementKey.innerBackground,
                    Container(
                      key: const Key('glow-bg'),
                      decoration: BoxDecoration(
                        color: Color(
                          _settings.colorFor(ElementKey.innerBackground),
                        ),
                        borderRadius: BorderRadius.all(
                          Radius.elliptical(124, (innerHeight - 12) / 2),
                        ),
                      ),
                    ),
                  ),
                ),

                // Clock Text Wrapper
                Positioned(
                  top: textTop,
                  left: 0,
                  right: 0,
                  child: Transform(
                    transform: Matrix4.identity()
                      ..scaleByDouble(1.0, textScaleY, 1.0, 1.0),
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Time display
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              _buildHours(baseSize: 28),
                              _buildSeparator(baseSize: 24),
                              _buildMinutes(baseSize: 28),
                              if (_settings.showSeconds) ...[
                                _buildSeparator(baseSize: 24),
                                _buildSeconds(baseSize: 24),
                              ],
                              if (!_settings.use24HourFormat) ...[
                                const SizedBox(width: 4),
                                _buildAmPm(baseSize: 20),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        // Date display
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildDay(baseSize: 13),
                              Text(
                                ' | ',
                                style: TextStyle(
                                  color: Color(
                                    _settings.colorFor(ElementKey.separator),
                                  ),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              _buildDate(baseSize: 13),
                              const SizedBox(width: 4),
                              _buildYear(baseSize: 13),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRobikLayout() {
    // 1. Weather Icon & Text
    IconData weatherIcon = Icons.wb_cloudy_rounded;
    if (_settings.weatherStatus.isNotEmpty) {
      final statusLower = _settings.weatherStatus.toLowerCase();
      if (statusLower.contains('clear') || statusLower.contains('sunny')) {
        weatherIcon = Icons.wb_sunny_rounded;
      } else if (statusLower.contains('drizzle') ||
          statusLower.contains('rain')) {
        weatherIcon = Icons.water_drop_rounded;
      } else if (statusLower.contains('fog')) {
        weatherIcon = Icons.filter_drama_rounded;
      } else if (statusLower.contains('snow')) {
        weatherIcon = Icons.ac_unit_rounded;
      } else if (statusLower.contains('thunderstorm')) {
        weatherIcon = Icons.thunderstorm_rounded;
      }
    }
    final tempText = _settings.weatherTemp.isNotEmpty
        ? '${_settings.weatherTemp}°C'
        : '--°C';
    final condText = _settings.weatherStatus.isNotEmpty
        ? _settings.weatherStatus.toUpperCase()
        : 'UNKNOWN';

    // 2. Date string (Format: DD MONTH YYYY)
    final dayNum = DateFormat('d').format(_dateTime);
    final monthName = DateFormat('MMMM').format(_dateTime).toUpperCase();
    final yearNum = DateFormat('yyyy').format(_dateTime);
    final dateString = '$dayNum $monthName $yearNum';

    // 4. Accent Color & Text Color
    final accentColor = Color(_settings.colorFor(ElementKey.day));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Left Column: Clock & Date
          Expanded(
            flex: 58,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Day Header (Robik signature)
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _apply3D(
                    ElementKey.day,
                    Text(
                      DateFormat('EEEE').format(_dateTime).toUpperCase(),
                      style: _styleFor(
                        ElementKey.day,
                        baseSize: 13,
                        weight: FontWeight.w800,
                      ).copyWith(color: accentColor, letterSpacing: 2.0),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // Montserrat Time Row: Hours . Minutes [optional Seconds]
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      _apply3D(
                        ElementKey.hours,
                        Text(
                          _hours,
                          style: _styleFor(
                            ElementKey.hours,
                            baseSize: 68,
                            weight: FontWeight.w700,
                          ).copyWith(letterSpacing: -1.0, height: 1.0),
                        ),
                      ),
                      _apply3D(
                        ElementKey.separator,
                        Text(
                          '.',
                          style: _styleFor(
                            ElementKey.separator,
                            baseSize: 68,
                            weight: FontWeight.w700,
                          ).copyWith(letterSpacing: -1.0, height: 1.0),
                        ),
                      ),
                      _apply3D(
                        ElementKey.minutes,
                        Text(
                          _minutes,
                          style: _styleFor(
                            ElementKey.minutes,
                            baseSize: 68,
                            weight: FontWeight.w700,
                          ).copyWith(letterSpacing: -1.0, height: 1.0),
                        ),
                      ),
                      if (_settings.showSeconds) ...[
                        const SizedBox(width: 4),
                        _apply3D(
                          ElementKey.seconds,
                          Text(
                            _seconds,
                            style: _styleFor(
                              ElementKey.seconds,
                              baseSize: 22,
                              weight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                // Custom line / Separator (Orange pill)
                _apply3D(
                  ElementKey.separator,
                  Container(
                    width: _settings.effectiveSeparatorWidth > 150
                        ? 72
                        : _settings.effectiveSeparatorWidth,
                    height: _settings.effectiveSeparatorHeight > 20
                        ? 4
                        : _settings.effectiveSeparatorHeight,
                    decoration: BoxDecoration(
                      color: Color(_settings.colorFor(ElementKey.separator)),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // Date (Product Sans)
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _apply3D(
                    ElementKey.date,
                    Text(
                      dateString,
                      style: _styleFor(
                        ElementKey.date,
                        baseSize: 13,
                        weight: FontWeight.w600,
                      ).copyWith(letterSpacing: 1.0),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Divider between columns
          Container(
            width: 1,
            height: 160,
            color: Colors.white.withValues(alpha: 0.08),
          ),
          const SizedBox(width: 12),

          // Right Column: Weather & System Resource Indicators (inspired by Robik)
          Expanded(
            flex: 42,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Weather indicator row
                if (_settings.showWeather) ...[
                  Row(
                    children: [
                      _apply3D(
                        ElementKey.weatherIcon,
                        Icon(
                          weatherIcon,
                          color: Color(
                            _settings.colorFor(ElementKey.weatherIcon),
                          ),
                          size: _settings.sizeFor(ElementKey.weatherIcon, 24),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _apply3D(
                              ElementKey.weatherStatus,
                              Text(
                                condText,
                                style: _styleFor(
                                  ElementKey.weatherStatus,
                                  baseSize: 10,
                                  weight: FontWeight.bold,
                                ).copyWith(letterSpacing: 0.5),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(height: 2),
                            _apply3D(
                              ElementKey.weatherTemp,
                              Text(
                                tempText,
                                style: _styleFor(
                                  ElementKey.weatherTemp,
                                  baseSize: 10,
                                  weight: FontWeight.bold,
                                ).copyWith(letterSpacing: 0.5),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],

                // CPU usage indicator
                if (_settings.showCpu) ...[
                  _apply3D(
                    ElementKey.cpu,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'CPU: ${_cpuUsage.toStringAsFixed(0)}%',
                          style:
                              _styleFor(
                                ElementKey.cpu,
                                baseSize: 10,
                                weight: FontWeight.bold,
                              ).copyWith(
                                letterSpacing: 0.5,
                                fontFamily: _settings.fontFor(ElementKey.cpu),
                              ),
                        ),
                        const SizedBox(height: 4),
                        // CPU progress bar
                        Container(
                          width: double.infinity,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(2.5),
                          ),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: (_cpuUsage / 100.0).clamp(0.02, 1.0),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Color(
                                  _settings.colorFor(ElementKey.cpu),
                                ),
                                borderRadius: BorderRadius.circular(2.5),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // RAM usage indicator
                if (_settings.showRam) ...[
                  _apply3D(
                    ElementKey.ram,
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'RAM: ${_ramUsage.toStringAsFixed(0)}%',
                          style:
                              _styleFor(
                                ElementKey.ram,
                                baseSize: 10,
                                weight: FontWeight.bold,
                              ).copyWith(
                                letterSpacing: 0.5,
                                fontFamily: _settings.fontFor(ElementKey.ram),
                              ),
                        ),
                        const SizedBox(height: 4),
                        // RAM progress bar
                        Container(
                          width: double.infinity,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(2.5),
                          ),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: (_ramUsage / 100.0).clamp(0.02, 1.0),
                            child: Container(
                              decoration: BoxDecoration(
                                color: Color(
                                  _settings.colorFor(ElementKey.ram),
                                ),
                                borderRadius: BorderRadius.circular(2.5),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAtomicClockLayout() {
    final dayStr = DateFormat('EEEE').format(_dateTime).toUpperCase();
    final monthName = DateFormat('MMMM').format(_dateTime).toUpperCase();
    final dateStr = '${_dateTime.day} $monthName, ${_dateTime.year}.';

    String timeStr;
    if (_settings.use24HourFormat) {
      timeStr = _settings.showSeconds
          ? '- $_hours:$_minutes:$_seconds -'
          : '- $_hours:$_minutes -';
    } else {
      timeStr = _settings.showSeconds
          ? '- $_hours:$_minutes:$_seconds $_ampm -'
          : '- $_hours:$_minutes $_ampm -';
    }

    Widget buildAtomicText({
      required String text,
      required String elementKey,
      required double baseSize,
      required double letterSpacing,
      required FontWeight weight,
    }) {
      final size =
          _settings.sizeFor(elementKey, baseSize) *
          _settings.fontSizeMultiplier;
      final font = _settings.fontFor(elementKey);
      final hasOverride = _settings.elementColors.containsKey(elementKey);
      final col = Color(_settings.colorFor(elementKey));

      final textWidget = Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: font == 'Segoe UI' ? 'Anurati' : font,
          fontSize: size,
          fontWeight: weight,
          letterSpacing: letterSpacing,
          color: hasOverride || _settings.customGradientColors.length < 2
              ? col
              : Colors.white,
          shadows: [
            Shadow(
              color: Colors.black.withValues(alpha: 0.75),
              blurRadius: 6,
              offset: const Offset(1, 2),
            ),
          ],
        ),
      );

      if (!hasOverride && _settings.customGradientColors.length >= 2) {
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: _settings.customGradientColors
                .map((c) => Color(c))
                .toList(),
          ).createShader(bounds),
          child: textWidget,
        );
      }

      return textWidget;
    }

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _apply3D(
              ElementKey.day,
              buildAtomicText(
                text: dayStr,
                elementKey: ElementKey.day,
                baseSize: 46,
                letterSpacing: 4.5,
                weight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            _apply3D(
              ElementKey.date,
              buildAtomicText(
                text: dateStr,
                elementKey: ElementKey.date,
                baseSize: 21,
                letterSpacing: 2.2,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            _apply3D(
              ElementKey.hours,
              buildAtomicText(
                text: timeStr,
                elementKey: ElementKey.hours,
                baseSize: 16,
                letterSpacing: 2.0,
                weight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomLayout() {
    return CustomWidgetRenderer(
      elements: _settings.customElements,
      dateTime: _dateTime,
      cpuUsage: _cpuUsage,
      ramUsage: _ramUsage,
      weatherTemp: _settings.weatherTemp,
      weatherStatus: _settings.weatherStatus,
      mediaInfo: _mediaInfo,
      mediaThumbnailBytes: _thumbnailBytes,
      mediaPosition: _playbackPositionNotifier,
      batteryInfo: _systemMetrics.battery,
      diskInfo: _systemMetrics.disk,
      enableMediaControls: true,
      wifiEnabled: _connectivity.wifiEnabled,
      bluetoothEnabled: _connectivity.bluetoothEnabled,
      onWifiToggle: _toggleWifi,
      onBluetoothToggle: _toggleBluetooth,
      isInteractive: false,
      canvasWidth: _settings.width,
      canvasHeight: _settings.height,
    );
  }

  // ── Taskbar Widgets (Inspired by pfcdev/TaskbarWidgets) ──────────────────────

  Widget _buildTaskbarGlassContainer({
    required Widget child,
    double? width,
    double? height,
    EdgeInsetsGeometry? padding,
    BorderRadiusGeometry? borderRadius,
  }) {
    return Container(
      width: width,
      height: height,
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Color(_settings.taskbarBgColor),
        borderRadius: borderRadius ?? BorderRadius.circular(10),
        border: Border.all(
          color: Color(_settings.taskbarBorderColor),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildTaskbarDivider() {
    return Container(
      width: 1.0,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: Colors.white.withValues(alpha: 0.12),
    );
  }

  Widget _buildTaskbarEqualizer({
    int barCount = 5,
    Color? color,
    double maxHeight = 16,
  }) {
    final barColor = color ?? const Color(0xFF38BDF8);
    final sec = _dateTime.second + _dateTime.millisecond / 1000.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(barCount, (i) {
        final phase = (i * 1.3) + sec * 3.5;
        final factor = 0.25 + 0.75 * ((math.sin(phase) + 1.0) / 2.0);
        final height = (maxHeight * factor).clamp(3.0, maxHeight);
        return Container(
          width: 2.5,
          height: height,
          margin: const EdgeInsets.symmetric(horizontal: 1.2),
          decoration: BoxDecoration(
            color: barColor,
            borderRadius: BorderRadius.circular(1.5),
            boxShadow: [
              BoxShadow(color: barColor.withValues(alpha: 0.4), blurRadius: 3),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildStudioTemplateDockLayout(DesktopStudioTemplate template) {
    final appearance = template.appearance;
    final layout = template.layout;

    return Container(
      height: layout.thickness,
      padding: EdgeInsets.symmetric(
        horizontal: layout.paddingHorizontal,
        vertical: layout.paddingVertical,
      ),
      decoration: BoxDecoration(
        color: Color(appearance.backgroundColor),
        borderRadius: BorderRadius.circular(appearance.borderRadius),
        border: Border.all(
          color: Color(appearance.borderColor),
          width: appearance.borderWidth,
        ),
        boxShadow: [
          BoxShadow(
            color: Color(appearance.shadowColor),
            blurRadius: appearance.shadowBlur,
            spreadRadius: appearance.shadowSpread,
          ),
        ],
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (int i = 0; i < template.elements.length; i++) ...[
              _buildStudioElement(template.elements[i], appearance),
              if (i < template.elements.length - 1 &&
                  template.elements[i].type != DockElementType.spacer)
                SizedBox(width: layout.itemSpacing),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStudioElement(
    DockItemElement elem,
    DockAppearanceConfig appearance,
  ) {
    final iconSize = appearance.iconSize;
    final activeColor = Color(appearance.activeIndicatorColor);

    switch (elem.type) {
      case DockElementType.appLauncher:
        return Tooltip(
          message: 'WallSync Dashboard — Click to open',
          child: InkWell(
            onTap: () => _openDashboard('desktop_studio'),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    activeColor.withValues(alpha: 0.3),
                    const Color(0xFF818CF8).withValues(alpha: 0.2),
                  ],
                ),
                shape: BoxShape.circle,
                border: Border.all(
                  color: activeColor.withValues(alpha: 0.5),
                  width: 1.0,
                ),
              ),
              child: Icon(
                Icons.widgets_rounded,
                size: iconSize,
                color: activeColor,
              ),
            ),
          ),
        );

      case DockElementType.pinnedApp:
      case DockElementType.customAction:
        return Tooltip(
          message: elem.actionPayload.isNotEmpty
              ? '${elem.label}: ${elem.actionPayload}'
              : elem.label.isNotEmpty
              ? elem.label
              : 'Configure dock launch target in Desktop Studio',
          child: InkWell(
            onTap: () => _launchDockElement(elem),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Icon(
                IconData(
                  // ignore: non_const_argument_for_const_parameter
                  elem.iconCodePoint,
                  // ignore: non_const_argument_for_const_parameter
                  fontFamily: elem.iconFontFamily ?? 'MaterialIcons',
                ),
                size: iconSize,
                color: elem.customColor != null
                    ? Color(elem.customColor!)
                    : Colors.white.withValues(alpha: 0.88),
              ),
            ),
          ),
        );

      case DockElementType.runningTasks:
        if (_dockWindows.isEmpty) {
          return Tooltip(
            message: 'No open applications',
            child: Icon(
              Icons.apps_rounded,
              size: iconSize,
              color: Colors.white38,
            ),
          );
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: _dockWindows.take(8).map((window) {
            return Tooltip(
              message: window.title,
              child: InkWell(
                onTap: () => _activateDockWindow(window),
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: iconSize + 8,
                  height: iconSize + 10,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _dockWindowIcon(window),
                        size: iconSize,
                        color: window.isForeground
                            ? activeColor
                            : Colors.white.withValues(alpha: 0.78),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        width: 4,
                        height: 2,
                        decoration: BoxDecoration(
                          color: window.isForeground
                              ? activeColor
                              : Colors.white38,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        );

      case DockElementType.clock:
        return Tooltip(
          message: 'WallSync Clock',
          child: InkWell(
            onTap: () => _openDashboard('widgets'),
            child: Text(
              '$_hours:$_minutes',
              style: TextStyle(
                fontSize: iconSize * 0.65,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: 0.6,
                fontFamily: 'Segoe UI',
              ),
            ),
          ),
        );

      case DockElementType.date:
        final now = DateTime.now();
        final monthNames = [
          'Jan',
          'Feb',
          'Mar',
          'Apr',
          'May',
          'Jun',
          'Jul',
          'Aug',
          'Sep',
          'Oct',
          'Nov',
          'Dec',
        ];
        return Text(
          '${monthNames[now.month - 1]} ${now.day}',
          style: TextStyle(
            fontSize: iconSize * 0.55,
            fontWeight: FontWeight.w600,
            color: Colors.white70,
            fontFamily: 'Segoe UI',
          ),
        );

      case DockElementType.weatherSlot:
        final tempStr = _settings.weatherTemp.isNotEmpty
            ? '${_settings.weatherTemp}°'
            : '22°';
        return Tooltip(
          message: 'Local Weather',
          child: InkWell(
            onTap: () => _openDashboard('widgets'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.wb_sunny_rounded,
                  size: iconSize * 0.8,
                  color: const Color(0xFFFBBF24),
                ),
                const SizedBox(width: 4),
                Text(
                  tempStr,
                  style: TextStyle(
                    fontSize: iconSize * 0.55,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    fontFamily: 'Segoe UI',
                  ),
                ),
              ],
            ),
          ),
        );

      case DockElementType.mediaControls:
        final isPlaying = _mediaInfo.isPlaying;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              onTap: () => MediaSessionService().previous(),
              child: Icon(
                Icons.skip_previous_rounded,
                size: iconSize * 0.75,
                color: Colors.white70,
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: () {
                if (isPlaying) {
                  MediaSessionService().pause();
                } else {
                  MediaSessionService().play();
                }
              },
              child: Icon(
                isPlaying
                    ? Icons.pause_circle_filled_rounded
                    : Icons.play_circle_fill_rounded,
                size: iconSize * 0.95,
                color: activeColor,
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: () => MediaSessionService().next(),
              child: Icon(
                Icons.skip_next_rounded,
                size: iconSize * 0.75,
                color: Colors.white70,
              ),
            ),
          ],
        );

      case DockElementType.volumeSlider:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.volume_up_rounded,
              size: iconSize * 0.8,
              color: Colors.white70,
            ),
            const SizedBox(width: 4),
            Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: 0.7,
                child: Container(
                  decoration: BoxDecoration(
                    color: activeColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ],
        );

      case DockElementType.networkStatus:
        return Icon(
          Icons.wifi_rounded,
          size: iconSize * 0.8,
          color: Colors.white70,
        );

      case DockElementType.batteryStatus:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.battery_charging_full_rounded,
              size: iconSize * 0.8,
              color: const Color(0xFF10B981),
            ),
            const SizedBox(width: 3),
            Text(
              '95%',
              style: TextStyle(
                fontSize: iconSize * 0.5,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
                fontFamily: 'Segoe UI',
              ),
            ),
          ],
        );

      case DockElementType.cpuSparkline:
        final cpuCol = _cpuUsage > 85
            ? const Color(0xFFF43F5E)
            : (_cpuUsage > 60
                  ? const Color(0xFFF59E0B)
                  : const Color(0xFF38BDF8));
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.memory_rounded, size: iconSize * 0.75, color: cpuCol),
            const SizedBox(width: 4),
            Text(
              'CPU ${_cpuUsage.toStringAsFixed(0)}%',
              style: TextStyle(
                fontSize: iconSize * 0.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                fontFamily: 'Segoe UI',
              ),
            ),
          ],
        );

      case DockElementType.ramSparkline:
        final ramCol = _ramUsage > 85
            ? const Color(0xFFF43F5E)
            : (_ramUsage > 70
                  ? const Color(0xFFF59E0B)
                  : const Color(0xFFA855F7));
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.storage_rounded, size: iconSize * 0.75, color: ramCol),
            const SizedBox(width: 4),
            Text(
              'RAM ${_ramUsage.toStringAsFixed(0)}%',
              style: TextStyle(
                fontSize: iconSize * 0.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                fontFamily: 'Segoe UI',
              ),
            ),
          ],
        );

      case DockElementType.separator:
        return Container(
          width: 1.2,
          height: 18,
          color: Colors.white.withValues(alpha: 0.18),
        );

      case DockElementType.spacer:
        return const SizedBox(width: 18);

      case DockElementType.quickSettings:
        return Tooltip(
          message: 'Device Optimization',
          child: InkWell(
            onTap: () => _openDashboard('device_optimization'),
            child: Icon(
              Icons.tune_rounded,
              size: iconSize * 0.8,
              color: Colors.white70,
            ),
          ),
        );

      default:
        return Icon(
          Icons.widgets_rounded,
          size: iconSize,
          color: Colors.white70,
        );
    }
  }

  Widget _buildTaskbarDockLayout() {
    final isReplacementMode =
        _settings.taskbarSettings.nativeTaskbarHideEnabled;
    if (_settings.activeDockTemplateJson != null &&
        _settings.activeDockTemplateJson!.isNotEmpty) {
      try {
        final decoded =
            jsonDecode(_settings.activeDockTemplateJson!)
                as Map<String, dynamic>;
        final template = DesktopStudioTemplate.fromJson(decoded);
        final templateLayout = _buildStudioTemplateDockLayout(template);
        if (!isReplacementMode) return templateLayout;
        return _buildTaskbarGlassContainer(
          width: double.infinity,
          height: double.infinity,
          borderRadius: BorderRadius.zero,
          child: Row(
            children: [
              _buildTaskbarActionButton(
                'search',
                Icons.search_rounded,
                'Windows Search',
              ),
              _buildTaskbarActionButton(
                'task-view',
                Icons.view_carousel_rounded,
                'Task View and virtual desktops',
              ),
              _buildTaskbarActionButton(
                'file-explorer',
                Icons.folder_rounded,
                'File Explorer',
              ),
              _buildTaskbarActionButton(
                'copilot',
                Icons.auto_awesome_rounded,
                'Copilot',
              ),
              _buildTaskbarRunningApps(),
              Expanded(child: Center(child: templateLayout)),
              _buildTaskbarActionButton(
                'wifi-settings',
                Icons.wifi_rounded,
                'Wi-Fi settings',
              ),
              _buildTaskbarActionButton(
                'quick-settings',
                Icons.tune_rounded,
                'Quick settings',
              ),
              _buildTaskbarActionButton(
                'sound-settings',
                Icons.volume_up_rounded,
                'Audio settings',
              ),
              _buildTaskbarActionButton(
                'battery-settings',
                Icons.battery_charging_full_rounded,
                'Battery and power settings',
              ),
              _buildTaskbarActionButton(
                'notifications',
                Icons.notifications_rounded,
                'Notifications',
              ),
              _buildTaskbarActionButton(
                'show-desktop',
                Icons.desktop_windows_rounded,
                'Show desktop',
              ),
            ],
          ),
        );
      } catch (_) {}
    }
    final tempStr = _settings.weatherTemp.isNotEmpty
        ? '${_settings.weatherTemp}°'
        : '22°';
    final locStr = _settings.weatherLocation.isNotEmpty
        ? _settings.weatherLocation
        : 'Local';
    final hasMedia = _mediaInfo.title.isNotEmpty || _mediaInfo.isPlaying;
    final isVideoWallpaper = _settings.activeWallpaperType == 'video';
    final isPaused = !LiveWallpaperManager().isPlaying;

    // CPU color-coded threshold
    final cpuColor = _cpuUsage > 85
        ? const Color(0xFFF43F5E)
        : (_cpuUsage > 60
              ? const Color(0xFFF59E0B)
              : Color(_settings.taskbarAccentColor));

    // RAM color-coded threshold
    final ramColor = _ramUsage > 85
        ? const Color(0xFFF43F5E)
        : (_ramUsage > 70 ? const Color(0xFFF59E0B) : const Color(0xFFA855F7));

    final taskbarContents = Row(
      mainAxisSize: isReplacementMode ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: isReplacementMode
          ? MainAxisAlignment.spaceBetween
          : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 1. Home / WallSync Logo Button (opens Dashboard)
        Tooltip(
          message: 'WallSync Dashboard — Click to open',
          child: InkWell(
            onTap: () => _openDashboard('wallpapers'),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF38BDF8), Color(0xFF818CF8)],
                      ),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(
                            0xFF38BDF8,
                          ).withValues(alpha: 0.35),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.widgets_rounded,
                      size: 14,
                      color: Color(0xFF070B12),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'WallSync',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                      fontFamily: 'Segoe UI',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        _buildTaskbarDivider(),
        if (isReplacementMode) ...[
          _buildTaskbarActionButton(
            'search',
            Icons.search_rounded,
            'Windows Search',
          ),
          _buildTaskbarActionButton(
            'task-view',
            Icons.view_carousel_rounded,
            'Task View and virtual desktops',
          ),
          _buildTaskbarActionButton(
            'file-explorer',
            Icons.folder_rounded,
            'File Explorer',
          ),
          _buildTaskbarActionButton(
            'copilot',
            Icons.auto_awesome_rounded,
            'Copilot',
          ),
          _buildTaskbarRunningApps(),
          _buildTaskbarDivider(),
        ],

        // 2. Wallpaper Mode & Playback Pill
        Tooltip(
          message: isVideoWallpaper
              ? 'Video Wallpaper Active (Click to ${isPaused ? "Play" : "Pause"})'
              : 'Static Wallpaper Active',
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color:
                  (isVideoWallpaper
                          ? const Color(0xFF38BDF8)
                          : const Color(0xFF818CF8))
                      .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color:
                    (isVideoWallpaper
                            ? const Color(0xFF38BDF8)
                            : const Color(0xFF818CF8))
                        .withValues(alpha: 0.30),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isVideoWallpaper
                      ? Icons.movie_filter_rounded
                      : Icons.image_rounded,
                  size: (_settings.taskbarIconSize - 4).clamp(10.0, 16.0),
                  color: isVideoWallpaper
                      ? const Color(0xFF38BDF8)
                      : const Color(0xFF818CF8),
                ),
                const SizedBox(width: 4),
                Text(
                  isVideoWallpaper ? 'VIDEO' : 'STATIC',
                  style: TextStyle(
                    color: isVideoWallpaper
                        ? const Color(0xFF38BDF8)
                        : const Color(0xFF818CF8),
                    fontSize: (_settings.taskbarFontSize - 2).clamp(8.0, 12.0),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
                if (isVideoWallpaper) ...[
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () {
                      if (isPaused) {
                        LiveWallpaperManager().play();
                      } else {
                        LiveWallpaperManager().pause();
                      }
                      setState(() {});
                    },
                    child: Icon(
                      isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      size: 14,
                      color: const Color(0xFF38BDF8),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        _buildTaskbarDivider(),

        // 3. Hardware Monitoring Chips (CPU, RAM, GPU, Profile)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // CPU Pill
            if (_settings.taskbarShowCpu) ...[
              Tooltip(
                message:
                    'CPU Usage: ${_cpuUsage.toStringAsFixed(1)}% (${Platform.numberOfProcessors} Cores)\nClick to open Device Optimization',
                child: InkWell(
                  onTap: () => _openDashboard('device_optimization'),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: cpuColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: cpuColor.withValues(alpha: 0.28),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.memory_rounded,
                          size: (_settings.taskbarIconSize - 5).clamp(
                            9.0,
                            16.0,
                          ),
                          color: cpuColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${_cpuUsage.toStringAsFixed(0)}%',
                          style: TextStyle(
                            color: cpuColor,
                            fontSize: (_settings.taskbarFontSize - 1).clamp(
                              8.0,
                              14.0,
                            ),
                            fontWeight: FontWeight.w700,
                            fontFamily: 'Segoe UI',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],

            // RAM Pill
            if (_settings.taskbarShowRam) ...[
              Tooltip(
                message:
                    'System RAM: ${_ramUsage.toStringAsFixed(0)}% used\nClick to open Device Optimization',
                child: InkWell(
                  onTap: () => _openDashboard('device_optimization'),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: ramColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: ramColor.withValues(alpha: 0.28),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.developer_board_rounded,
                          size: (_settings.taskbarIconSize - 5).clamp(
                            9.0,
                            16.0,
                          ),
                          color: ramColor,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${_ramUsage.toStringAsFixed(0)}%',
                          style: TextStyle(
                            color: ramColor,
                            fontSize: (_settings.taskbarFontSize - 1).clamp(
                              8.0,
                              14.0,
                            ),
                            fontWeight: FontWeight.w700,
                            fontFamily: 'Segoe UI',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],

            // GPU / Target FPS Pill
            Tooltip(
              message:
                  'GPU Graphics Engine: Impeller DXGI\nTarget: ${_settings.wallpaperFpsLimit} FPS\nClick to open Device Optimization',
              child: InkWell(
                onTap: () => _openDashboard('device_optimization'),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: const Color(0xFF10B981).withValues(alpha: 0.28),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.speed_rounded,
                        size: (_settings.taskbarIconSize - 5).clamp(9.0, 16.0),
                        color: const Color(0xFF10B981),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${_settings.wallpaperFpsLimit} FPS',
                        style: TextStyle(
                          color: const Color(0xFF10B981),
                          fontSize: (_settings.taskbarFontSize - 1).clamp(
                            8.0,
                            14.0,
                          ),
                          fontWeight: FontWeight.w700,
                          fontFamily: 'Segoe UI',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),

            // Performance Profile Pill (Click to cycle profile)
            Tooltip(
              message:
                  'Performance Profile: ${_settings.performanceProfile.toUpperCase()}\nClick to cycle profile',
              child: InkWell(
                onTap: _cyclePerformanceProfile,
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.tune_rounded,
                        size: (_settings.taskbarIconSize - 6).clamp(9.0, 14.0),
                        color: const Color(0xFF38BDF8),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _settings.performanceProfile.toUpperCase(),
                        style: TextStyle(
                          color: const Color(0xFF38BDF8),
                          fontSize: (_settings.taskbarFontSize - 2).clamp(
                            8.0,
                            12.0,
                          ),
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        _buildTaskbarDivider(),

        // 4. Time & Date Pill
        if (_settings.taskbarShowTime) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.access_time_rounded,
                size: _settings.taskbarIconSize,
                color: Color(_settings.taskbarIconColor),
              ),
              const SizedBox(width: 6),
              Text(
                '$_hours:$_minutes',
                style: TextStyle(
                  color: Color(_settings.taskbarTextColor),
                  fontSize: _settings.taskbarFontSize + 2,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'Segoe UI',
                ),
              ),
              const SizedBox(width: 6),
              Text(
                DateFormat('E d').format(_dateTime).toUpperCase(),
                style: TextStyle(
                  color: Color(
                    _settings.taskbarTextColor,
                  ).withValues(alpha: 0.6),
                  fontSize: (_settings.taskbarFontSize - 1).clamp(8.0, 16.0),
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Segoe UI',
                ),
              ),
            ],
          ),
          _buildTaskbarDivider(),
        ],

        // 5. Weather Pill
        if (_settings.taskbarShowWeather) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.wb_sunny_rounded,
                size: (_settings.taskbarIconSize - 2).clamp(10.0, 24.0),
                color: const Color(0xFFFBBF24),
              ),
              const SizedBox(width: 5),
              Text(
                tempStr,
                style: TextStyle(
                  color: Color(_settings.taskbarTextColor),
                  fontSize: _settings.taskbarFontSize,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'Segoe UI',
                ),
              ),
              const SizedBox(width: 4),
              Text(
                locStr,
                style: TextStyle(
                  color: Color(
                    _settings.taskbarTextColor,
                  ).withValues(alpha: 0.5),
                  fontSize: (_settings.taskbarFontSize - 2).clamp(8.0, 16.0),
                  fontFamily: 'Segoe UI',
                ),
              ),
            ],
          ),
          _buildTaskbarDivider(),
        ],

        // 6. Mini Media Visualizer
        if (_settings.taskbarShowMedia) ...[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () {
                    if (_mediaInfo.isPlaying) {
                      MediaSessionService().pause();
                    } else {
                      MediaSessionService().play();
                    }
                  },
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: Color(
                        _settings.taskbarAccentColor,
                      ).withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _mediaInfo.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: (_settings.taskbarIconSize - 1).clamp(12.0, 20.0),
                      color: Color(_settings.taskbarAccentColor),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasMedia ? _mediaInfo.title : 'TaskbarWidgets Audio',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Color(_settings.taskbarTextColor),
                          fontSize: _settings.taskbarFontSize,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'Segoe UI',
                        ),
                      ),
                      Text(
                        hasMedia ? _mediaInfo.artist : 'WASAPI Spectrum Sync',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Color(
                            _settings.taskbarTextColor,
                          ).withValues(alpha: 0.5),
                          fontSize: (_settings.taskbarFontSize - 2).clamp(
                            8.0,
                            14.0,
                          ),
                          fontFamily: 'Segoe UI',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildTaskbarEqualizer(
                  barCount: 5,
                  color: Color(_settings.taskbarAccentColor),
                  maxHeight: 15,
                ),
              ],
            ),
          ),
          _buildTaskbarDivider(),
        ],

        if (isReplacementMode) ...[
          _buildTaskbarActionButton(
            'wifi-settings',
            Icons.wifi_rounded,
            'Wi-Fi settings',
          ),
          _buildTaskbarActionButton(
            'quick-settings',
            Icons.tune_rounded,
            'Quick settings',
          ),
          _buildTaskbarActionButton(
            'sound-settings',
            Icons.volume_up_rounded,
            'Audio settings',
          ),
          _buildTaskbarActionButton(
            'battery-settings',
            Icons.battery_charging_full_rounded,
            'Battery and power settings',
          ),
          _buildTaskbarActionButton(
            'notifications',
            Icons.notifications_rounded,
            'Notifications',
          ),
          _buildTaskbarActionButton(
            'show-desktop',
            Icons.desktop_windows_rounded,
            'Show desktop',
          ),
          _buildTaskbarDivider(),
        ],

        // 7. Widget Controls & Navigation Toolbar
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Lock/Unlock Toggle
            Tooltip(
              message: _settings.isLocked
                  ? 'Position Locked (Click to Unlock)'
                  : 'Position Unlocked (Click to Lock)',
              child: InkWell(
                onTap: () {
                  final newLocked = !_settings.isLocked;
                  setState(() {
                    _settings.isLocked = newLocked;
                    if (newLocked) _visualEditorModeActive = false;
                  });
                  unawaited(
                    _settingsService.updateSettings(
                      (c) => c.copyWith(isLocked: newLocked),
                    ),
                  );
                },
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Icon(
                    _settings.isLocked
                        ? Icons.lock_rounded
                        : Icons.lock_open_rounded,
                    size: 16,
                    color: _settings.isLocked
                        ? const Color(0xFFF43F5E)
                        : const Color(0xFF10B981),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),

            // Edit Mode Toggle
            Tooltip(
              message: _visualEditorModeActive
                  ? 'Exit Layout Editor'
                  : 'Edit Widget Layout',
              child: InkWell(
                onTap: () {
                  if (_settings.isLocked) return;
                  setState(() {
                    _visualEditorModeActive = !_visualEditorModeActive;
                    _settings.editorMode = _visualEditorModeActive;
                  });
                  unawaited(
                    _settingsService.updateSettings(
                      (c) => c.copyWith(editorMode: _visualEditorModeActive),
                    ),
                  );
                },
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Icon(
                    _visualEditorModeActive
                        ? Icons.check_circle_outline_rounded
                        : Icons.crop_free_rounded,
                    size: 16,
                    color: _settings.isLocked
                        ? Colors.white24
                        : (_visualEditorModeActive
                              ? const Color(0xFF38BDF8)
                              : Colors.white60),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),

            // Add Widget Shortcut
            Tooltip(
              message: 'Add / Preset Widgets',
              child: InkWell(
                onTap: () => _openDashboard('widgets'),
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(
                    Icons.add_circle_outline_rounded,
                    size: 16,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),

            // Diagnostics Shortcut
            Tooltip(
              message: 'Performance & Diagnostics Monitor',
              child: InkWell(
                onTap: () => _openDashboard('diagnostics'),
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(
                    Icons.monitor_heart_rounded,
                    size: 16,
                    color: Color(0xFF38BDF8),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),

            // Device Optimization Shortcut
            Tooltip(
              message: 'Device Optimization System',
              child: InkWell(
                onTap: () => _openDashboard('device_optimization'),
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(
                    Icons.speed_rounded,
                    size: 16,
                    color: Color(0xFF10B981),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),

            // Settings Shortcut
            Tooltip(
              message: 'WallSync Settings',
              child: InkWell(
                onTap: () => _openDashboard('settings'),
                borderRadius: BorderRadius.circular(6),
                child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: Icon(
                    Icons.settings_rounded,
                    size: 16,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );

    return _buildTaskbarGlassContainer(
      width: isReplacementMode ? double.infinity : null,
      height: isReplacementMode ? double.infinity : 48,
      borderRadius: isReplacementMode ? BorderRadius.zero : null,
      child: isReplacementMode
          ? taskbarContents
          : FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: taskbarContents,
            ),
    );
  }

  Widget _buildTaskbarMediaLayout() {
    final title = _mediaInfo.title.isNotEmpty
        ? _mediaInfo.title
        : 'Taskbar Media Player';
    final artist = _mediaInfo.artist.isNotEmpty
        ? _mediaInfo.artist
        : 'WASAPI Real-time FFT';

    return _buildTaskbarGlassContainer(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        children: [
          // Album thumbnail / music icon
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            clipBehavior: Clip.antiAlias,
            child: _thumbnailBytes != null
                ? Image.memory(_thumbnailBytes!, fit: BoxFit.cover)
                : const Icon(
                    Icons.music_note_rounded,
                    size: 18,
                    color: Color(0xFF38BDF8),
                  ),
          ),
          const SizedBox(width: 10),

          // Track & Artist Info
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Segoe UI',
                  ),
                ),
                Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 9,
                    fontFamily: 'Segoe UI',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // Equalizer Spectrum
          _buildTaskbarEqualizer(
            barCount: 7,
            color: const Color(0xFFEC4899),
            maxHeight: 18,
          ),
          const SizedBox(width: 10),

          // Transport controls
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => MediaSessionService().previous(),
                child: Icon(
                  Icons.skip_previous_rounded,
                  size: 16,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () {
                  if (_mediaInfo.isPlaying) {
                    MediaSessionService().pause();
                  } else {
                    MediaSessionService().play();
                  }
                },
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEC4899).withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFEC4899).withValues(alpha: 0.4),
                    ),
                  ),
                  child: Icon(
                    _mediaInfo.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => MediaSessionService().next(),
                child: Icon(
                  Icons.skip_next_rounded,
                  size: 16,
                  color: Colors.white.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTaskbarSystemLayout() {
    final disk = _systemMetrics.disk;
    final diskUsage = disk?.usedPercentage ?? 45.0;
    final diskName = (disk != null && disk.drive.isNotEmpty)
        ? (disk.label.isNotEmpty ? '${disk.drive} ${disk.label}' : disk.drive)
        : 'SSD';

    final iconSz = _settings.taskbarIconSize.clamp(8.0, 24.0);
    final fontSz = _settings.taskbarFontSize.clamp(7.0, 16.0);
    final primaryColor = Color(_settings.taskbarAccentColor);
    final textColor = Color(_settings.taskbarTextColor);

    Widget buildStatCell({
      required IconData icon,
      required String label,
      required double percent,
      required Color color,
    }) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.2)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: iconSz * 0.75, color: color),
                        const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: color,
                              fontSize: fontSz * 0.8,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'Segoe UI',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${percent.toStringAsFixed(0)}%',
                    style: TextStyle(
                      color: textColor,
                      fontSize: fontSz * 0.8,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'Segoe UI',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              ClipRRect(
                borderRadius: BorderRadius.circular(1.5),
                child: Container(
                  height: 3,
                  color: Colors.white12,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: (percent / 100.0).clamp(0.04, 1.0),
                      child: Container(color: color),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final cells = <Widget>[];
    if (_settings.taskbarShowCpu) {
      cells.add(
        buildStatCell(
          icon: Icons.memory_rounded,
          label: 'CPU',
          percent: _cpuUsage,
          color: const Color(0xFF00FFCC),
        ),
      );
    }
    if (_settings.taskbarShowRam) {
      if (cells.isNotEmpty) cells.add(const SizedBox(width: 6));
      cells.add(
        buildStatCell(
          icon: Icons.developer_board_rounded,
          label: 'RAM',
          percent: _ramUsage,
          color: const Color(0xFFA855F7),
        ),
      );
    }
    if (_settings.taskbarShowDisk) {
      if (cells.isNotEmpty) cells.add(const SizedBox(width: 6));
      cells.add(
        buildStatCell(
          icon: Icons.storage_rounded,
          label: diskName,
          percent: diskUsage,
          color: primaryColor,
        ),
      );
    }

    if (cells.isEmpty) {
      cells.add(
        buildStatCell(
          icon: Icons.storage_rounded,
          label: diskName,
          percent: diskUsage,
          color: primaryColor,
        ),
      );
    }

    return _buildTaskbarGlassContainer(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Row(children: cells),
    );
  }

  Widget _buildTaskbarSteamLayout() {
    final steam = SteamMonitorService.instance.current;
    final isDownloading = steam.isDownloading;
    final title = isDownloading
        ? '${steam.gameTitle} Update'
        : (steam.activePlayingGame != null
              ? 'Playing ${steam.activePlayingGame}'
              : (steam.isSteamRunning
                    ? 'Steam Ready · Up to date'
                    : 'Steam Offline'));
    final speed = isDownloading
        ? '${steam.downloadSpeedMBs.toStringAsFixed(1)} MB/s'
        : (steam.isSteamRunning ? 'Synced' : 'Offline');
    final progress = isDownloading
        ? steam.progressPercent
        : (steam.isSteamRunning ? 1.0 : 0.0);

    return _buildTaskbarGlassContainer(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        children: [
          // Steam Icon
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF171A21), Color(0xFF1B2838)],
              ),
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFF66C0F4).withValues(alpha: 0.5),
              ),
            ),
            child: const Icon(
              Icons.sports_esports_rounded,
              size: 15,
              color: Color(0xFF66C0F4),
            ),
          ),
          const SizedBox(width: 10),

          // Download Status Info
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'Segoe UI',
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      speed,
                      style: const TextStyle(
                        color: Color(0xFF66C0F4),
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'Segoe UI',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                // Progress Bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: Container(
                    height: 4,
                    color: Colors.white12,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: progress.clamp(0.04, 1.0),
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Color(0xFF2A475E), Color(0xFF66C0F4)],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),

          // Action Icon
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              isDownloading
                  ? Icons.pause_rounded
                  : Icons.check_circle_outline_rounded,
              size: 14,
              color: isDownloading ? Colors.white70 : const Color(0xFF66C0F4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskbarDiscordLayout() {
    final discord = DiscordIpcService.instance.current;
    final isConnected = discord.isConnectedToVoice;
    final isMuted = discord.isMuted;
    final isSpeaking = discord.isSpeaking;
    final haloColor = isSpeaking
        ? const Color(0xFF23A55A)
        : (isMuted ? Colors.redAccent : const Color(0xFF5865F2));

    return _buildTaskbarGlassContainer(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        children: [
          // Voice avatar with glowing green halo ring
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: haloColor, width: 2.0),
                  boxShadow: isSpeaking
                      ? [
                          BoxShadow(
                            color: haloColor.withValues(alpha: 0.6),
                            blurRadius: 6,
                          ),
                        ]
                      : null,
                ),
              ),
              Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  color: Color(0xFF5865F2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.headset_mic_rounded,
                  size: 13,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(width: 10),

          // Channel & Latency Info
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isConnected
                      ? '🔊 ${discord.channelName}'
                      : (discord.isRunning
                            ? 'Discord Online'
                            : 'Discord Offline'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Segoe UI',
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: isConnected
                            ? const Color(0xFF23A55A)
                            : Colors.white30,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        isConnected
                            ? 'Voice Connected · ${discord.pingMs}ms'
                            : (discord.isRunning
                                  ? 'Not connected to voice'
                                  : 'Launch Discord to connect'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 8.5,
                          fontFamily: 'Segoe UI',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // Mute / Deafen Toggles
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () {
                  DiscordIpcService.instance.toggleMute();
                  setState(() {});
                },
                child: Icon(
                  isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                  size: 14,
                  color: isMuted
                      ? Colors.redAccent
                      : Colors.white.withValues(alpha: 0.8),
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                discord.isDeafened
                    ? Icons.headset_off_rounded
                    : Icons.headphones_rounded,
                size: 14,
                color: discord.isDeafened
                    ? Colors.redAccent
                    : Colors.white.withValues(alpha: 0.8),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTaskbarWeatherLayout() {
    final tempStr = _settings.weatherTemp.isNotEmpty
        ? '${_settings.weatherTemp}°'
        : '22°';
    final condStr = _settings.weatherStatus.isNotEmpty
        ? _settings.weatherStatus
        : 'Partly Cloudy';
    final locStr = _settings.weatherLocation.isNotEmpty
        ? _settings.weatherLocation
        : 'Local City';

    return _buildTaskbarGlassContainer(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_queue_rounded,
            size: 18,
            color: Color(0xFF38BDF8),
          ),
          const SizedBox(width: 8),
          Text(
            tempStr,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              fontFamily: 'Segoe UI',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  condStr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'Segoe UI',
                  ),
                ),
                Text(
                  locStr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 8.5,
                    fontFamily: 'Segoe UI',
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF38BDF8).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              '💧 64%',
              style: TextStyle(
                color: Color(0xFF38BDF8),
                fontSize: 8.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskbarParkingLotLayout() {
    return _buildTaskbarGlassContainer(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(
              Icons.inventory_2_outlined,
              size: 15,
              color: Color(0xFFF59E0B),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Parking Lot Stash',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'Segoe UI',
                        ),
                      ),
                    ),
                    SizedBox(width: 4),
                    Text(
                      '· 3 items',
                      style: TextStyle(
                        color: Color(0xFFF59E0B),
                        fontSize: 8.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                Text(
                  'Quick Drop: files, snippets & URLs',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 8.5,
                    fontFamily: 'Segoe UI',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
            ),
            child: const Icon(
              Icons.add_rounded,
              size: 12,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLayout() {
    switch (_settings.widgetTemplate) {
      case 'custom':
        return _buildCustomLayout();
      case 'minimal':
        return _buildMinimalLayout();
      case 'cyber':
        return _buildCyberLayout();
      case 'split':
        return _buildSplitLayout();
      case 'neon':
        return _buildNeonLayout();
      case 'animated_neon':
        return _buildAnimatedNeonLayout();
      case 'sleep_weather':
        return _buildSleepWeatherLayout();
      case 'robik':
        return _buildRobikLayout();
      case 'atomic_clock':
        return _buildAtomicClockLayout();
      case 'cyber_hud':
        return _buildCyberHudLayout();
      case 'atomic_clean':
        return _buildAtomicCleanLayout();
      case 'arc_clock':
        return _buildArcClockLayout();
      case 'flip_clock':
        return _buildFlipClockLayout();
      case 'station_weather':
        return _buildStationWeatherLayout();
      case 'taskbar_dock':
        return _buildTaskbarDockLayout();
      case 'taskbar_media':
        return _buildTaskbarMediaLayout();
      case 'taskbar_system':
        return _buildTaskbarSystemLayout();
      case 'taskbar_steam':
        return _buildTaskbarSteamLayout();
      case 'taskbar_discord':
        return _buildTaskbarDiscordLayout();
      case 'taskbar_weather':
        return _buildTaskbarWeatherLayout();
      case 'taskbar_parking_lot':
        return _buildTaskbarParkingLotLayout();
      case 'classic':
      default:
        return _buildClassicLayout();
    }
  }

  String _formatWithOrdinal(DateTime dt) {
    final day = dt.day;
    String suffix = 'th';
    if (day >= 11 && day <= 13) {
      suffix = 'th';
    } else {
      switch (day % 10) {
        case 1:
          suffix = 'st';
          break;
        case 2:
          suffix = 'nd';
          break;
        case 3:
          suffix = 'rd';
          break;
        default:
          suffix = 'th';
          break;
      }
    }
    return '${DateFormat('MMMM').format(dt)} $day$suffix';
  }

  // ── 1. Cyber HUD Terminal (Image 1) ──────────────────────────────────────────
  Widget _buildCyberHudLayout() {
    final boxColor = Color(_settings.colorFor(ElementKey.neonBox));
    final sepColor = Color(_settings.colorFor(ElementKey.separator));
    final dateColor = Color(_settings.colorFor(ElementKey.date));
    final dayColor = Color(_settings.colorFor(ElementKey.day));
    final badgeColor = Color(_settings.colorFor(ElementKey.neonBadge));

    final sepSize =
        _settings.sizeFor(ElementKey.separator, 10.0) *
        _settings.fontSizeMultiplier;
    final dateSize =
        _settings.sizeFor(ElementKey.date, 10.0) * _settings.fontSizeMultiplier;
    final daySize =
        _settings.sizeFor(ElementKey.day, 9.5) * _settings.fontSizeMultiplier;
    final badgeSize =
        _settings.sizeFor(ElementKey.neonBadge, 9.0) *
        _settings.fontSizeMultiplier;

    final dateStr =
        '${_dateTime.day.toString().padLeft(2, '0')} ${DateFormat('MMM').format(_dateTime).toUpperCase()} ${_dateTime.year}';

    return _apply3D(
      ElementKey.neonBox,
      Container(
        padding: EdgeInsets.symmetric(
          horizontal: 20 * _settings.fontSizeMultiplier,
          vertical: 16 * _settings.fontSizeMultiplier,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF070B12).withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: boxColor, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: boxColor.withValues(alpha: 0.28),
              blurRadius: 24,
              spreadRadius: 1,
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Top: // CYBER  27 OCT 2026
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _apply3D(
                  ElementKey.separator,
                  Text(
                    '// CYBER',
                    style: TextStyle(
                      color: sepColor,
                      fontSize: sepSize,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.4,
                      fontFamily: _settings.fontFor(ElementKey.separator),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _apply3D(
                  ElementKey.date,
                  Text(
                    dateStr,
                    style: TextStyle(
                      color: dateColor,
                      fontSize: dateSize,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                      fontFamily: _settings.fontFor(ElementKey.date),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: 10 * _settings.fontSizeMultiplier),

            // Middle: Hero Bold Time
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _apply3D(
                    ElementKey.hours,
                    Text(
                      _hours,
                      style: _styleFor(
                        ElementKey.hours,
                        baseSize: 44,
                        weight: FontWeight.w900,
                      ).copyWith(letterSpacing: -1.0, height: 1.0),
                    ),
                  ),
                  _apply3D(
                    ElementKey.separator,
                    Text(
                      ':',
                      style: _styleFor(
                        ElementKey.separator,
                        baseSize: 40,
                        weight: FontWeight.w700,
                      ).copyWith(height: 1.0),
                    ),
                  ),
                  _apply3D(
                    ElementKey.minutes,
                    Text(
                      _minutes,
                      style: _styleFor(
                        ElementKey.minutes,
                        baseSize: 44,
                        weight: FontWeight.w900,
                      ).copyWith(letterSpacing: -1.0, height: 1.0),
                    ),
                  ),
                  if (_settings.showSeconds) ...[
                    const SizedBox(width: 3),
                    _apply3D(
                      ElementKey.seconds,
                      Text(
                        _seconds,
                        style: _styleFor(
                          ElementKey.seconds,
                          baseSize: 18,
                          weight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(height: 12 * _settings.fontSizeMultiplier),

            // Bottom: TUESDAY  •  SYS_ACTIVE 100%
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _apply3D(
                  ElementKey.day,
                  Text(
                    _dayOfWeek,
                    style: TextStyle(
                      color: dayColor,
                      fontSize: daySize,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      fontFamily: _settings.fontFor(ElementKey.day),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '•',
                    style: TextStyle(
                      color: dayColor.withValues(alpha: 0.6),
                      fontSize: daySize,
                    ),
                  ),
                ),
                _apply3D(
                  ElementKey.neonBadge,
                  Text(
                    'SYS_ACTIVE ${_ramUsage > 0 ? "${_ramUsage.toInt()}%" : "100%"}',
                    style: TextStyle(
                      color: badgeColor,
                      fontSize: badgeSize,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                      fontFamily: _settings.fontFor(ElementKey.neonBadge),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── 2. Atomic Anurati Minimal (Image 2) ──────────────────────────────────────
  Widget _buildAtomicCleanLayout() {
    final subColor = Color(_settings.colorFor(ElementKey.day));
    final dateColor = Color(_settings.colorFor(ElementKey.date));
    final subSize =
        _settings.sizeFor(ElementKey.day, 10.5) * _settings.fontSizeMultiplier;

    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _apply3D(
                ElementKey.hours,
                Text(
                  _hours,
                  style: _styleFor(
                    ElementKey.hours,
                    baseSize: 52,
                    weight: FontWeight.w900,
                  ).copyWith(letterSpacing: -1.2, height: 1.0),
                ),
              ),
              _apply3D(
                ElementKey.separator,
                Text(
                  ':',
                  style: _styleFor(
                    ElementKey.separator,
                    baseSize: 46,
                    weight: FontWeight.w700,
                  ).copyWith(height: 1.0),
                ),
              ),
              _apply3D(
                ElementKey.minutes,
                Text(
                  _minutes,
                  style: _styleFor(
                    ElementKey.minutes,
                    baseSize: 52,
                    weight: FontWeight.w900,
                  ).copyWith(letterSpacing: -1.2, height: 1.0),
                ),
              ),
              if (_settings.showSeconds) ...[
                const SizedBox(width: 4),
                _apply3D(
                  ElementKey.seconds,
                  Text(
                    _seconds,
                    style: _styleFor(
                      ElementKey.seconds,
                      baseSize: 18,
                      weight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        SizedBox(height: 8 * _settings.fontSizeMultiplier),
        // Day of Week & Date Row with Anurati Styling
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _apply3D(
              ElementKey.day,
              Text(
                _dayOfWeek,
                style: TextStyle(
                  color: subColor,
                  fontSize: subSize,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2.8,
                  fontFamily: _settings.fontFor(ElementKey.day),
                  shadows: [
                    Shadow(
                      color: Colors.black.withValues(alpha: 0.6),
                      blurRadius: 4,
                      offset: const Offset(0.5, 1),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '•',
              style: TextStyle(
                color: subColor.withValues(alpha: 0.4),
                fontSize: subSize,
              ),
            ),
            const SizedBox(width: 6),
            _apply3D(
              ElementKey.date,
              Text(
                DateFormat('d MMM').format(_dateTime).toUpperCase(),
                style: TextStyle(
                  color: dateColor,
                  fontSize: subSize,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2.0,
                  fontFamily: _settings.fontFor(ElementKey.date),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── 3. Radial Arc Clock & Gauge (Image 3) ───────────────────────────────────
  Widget _buildArcClockLayout() {
    final arcStart = Color(_settings.colorFor(ElementKey.glowOuter));
    final arcEnd = Color(_settings.colorFor(ElementKey.glowInner));
    final hourHandCol = Color(_settings.colorFor(ElementKey.hours));
    final minuteHandCol = Color(_settings.colorFor(ElementKey.minutes));
    final secondHandCol = Color(_settings.colorFor(ElementKey.seconds));
    final tickCol = Color(_settings.colorFor(ElementKey.separator));
    final dialBg = Color(_settings.colorFor(ElementKey.innerBackground));

    final dialSize = (165.0 * _settings.fontSizeMultiplier).clamp(90.0, 260.0);

    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Analog Arc Dial Face with fully customizable colors
        _apply3D(
          ElementKey.hours,
          SizedBox(
            width: dialSize,
            height: dialSize,
            child: CustomPaint(
              painter: ArcClockDialPainter(
                dateTime: _dateTime,
                arcStartColor: arcStart,
                arcEndColor: arcEnd,
                hourHandColor: hourHandCol,
                minuteHandColor: minuteHandCol,
                secondHandColor: secondHandCol,
                tickColor: tickCol,
                dialBgColor: dialBg,
              ),
            ),
          ),
        ),
        SizedBox(height: 10 * _settings.fontSizeMultiplier),

        // Digital Time (Electric Cyan)
        _apply3D(
          ElementKey.minutes,
          Text(
            _settings.showSeconds
                ? '$_hours:$_minutes:$_seconds'
                : '$_hours:$_minutes',
            style: _styleFor(
              ElementKey.minutes,
              baseSize: 22,
              weight: FontWeight.w300,
            ).copyWith(letterSpacing: 1.0),
          ),
        ),
        SizedBox(height: 3 * _settings.fontSizeMultiplier),

        // Date Line (Saturday 15 September)
        _apply3D(
          ElementKey.day,
          Text(
            DateFormat('EEEE d MMMM').format(_dateTime),
            style: _styleFor(
              ElementKey.day,
              baseSize: 11,
              weight: FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }

  // ── 4. Mechanical Split-Flap Clock (Image 4) ─────────────────────────────────
  Widget _buildFlipClockLayout() {
    final frameColor = Color(_settings.colorFor(ElementKey.neonBox));
    final h1 = _hours.isNotEmpty ? _hours[0] : '1';
    final h2 = _hours.length > 1 ? _hours[1] : '2';
    final m1 = _minutes.isNotEmpty ? _minutes[0] : '4';
    final m2 = _minutes.length > 1 ? _minutes[1] : '5';

    final dayStr = DateFormat('EEE').format(_dateTime).toUpperCase();
    final dateStr = _dateTime.day.toString().padLeft(2, '0');
    final monthStr = DateFormat('MMM').format(_dateTime).toUpperCase();

    final cardW = 54.0 * _settings.fontSizeMultiplier;
    final cardH = 74.0 * _settings.fontSizeMultiplier;
    final numSize = 34.0 * _settings.fontSizeMultiplier;

    final dateCardW = 68.0 * _settings.fontSizeMultiplier;
    final dateCardH = 38.0 * _settings.fontSizeMultiplier;
    final dateNumSize = 15.0 * _settings.fontSizeMultiplier;

    final gap = 6.0 * _settings.fontSizeMultiplier;
    final midGap = 10.0 * _settings.fontSizeMultiplier;

    final cardBg = Color(_settings.colorFor(ElementKey.innerBackground));

    return _apply3D(
      ElementKey.neonBox,
      Container(
        padding: EdgeInsets.all(12 * _settings.fontSizeMultiplier),
        decoration: BoxDecoration(
          color: Colors.transparent, // Default transparent background
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: frameColor, width: 2.0),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Top Row: 4 Live Mechanical Time Flip Cards
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _apply3D(
                  ElementKey.hours,
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MechanicalFlipTile(
                        text: h1,
                        subTag: _settings.use24HourFormat ? null : _ampm,
                        width: cardW,
                        height: cardH,
                        fontSize: numSize,
                        fontKey: ElementKey.hours,
                        textColor: Color(_settings.colorFor(ElementKey.hours)),
                        cardBg: cardBg,
                        fontFamily: _settings.fontFor(ElementKey.hours),
                      ),
                      SizedBox(width: gap),
                      MechanicalFlipTile(
                        text: h2,
                        width: cardW,
                        height: cardH,
                        fontSize: numSize,
                        fontKey: ElementKey.hours,
                        textColor: Color(_settings.colorFor(ElementKey.hours)),
                        cardBg: cardBg,
                        fontFamily: _settings.fontFor(ElementKey.hours),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: midGap),
                _apply3D(
                  ElementKey.minutes,
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MechanicalFlipTile(
                        text: m1,
                        width: cardW,
                        height: cardH,
                        fontSize: numSize,
                        fontKey: ElementKey.minutes,
                        textColor: Color(
                          _settings.colorFor(ElementKey.minutes),
                        ),
                        cardBg: cardBg,
                        fontFamily: _settings.fontFor(ElementKey.minutes),
                      ),
                      SizedBox(width: gap),
                      MechanicalFlipTile(
                        text: m2,
                        width: cardW,
                        height: cardH,
                        fontSize: numSize,
                        fontKey: ElementKey.minutes,
                        textColor: Color(
                          _settings.colorFor(ElementKey.minutes),
                        ),
                        cardBg: cardBg,
                        fontFamily: _settings.fontFor(ElementKey.minutes),
                      ),
                    ],
                  ),
                ),
                if (_settings.showSeconds) ...[
                  SizedBox(width: midGap),
                  _apply3D(
                    ElementKey.seconds,
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MechanicalFlipTile(
                          text: _seconds.isNotEmpty ? _seconds[0] : '0',
                          width: cardW * 0.7,
                          height: cardH * 0.7,
                          fontSize: numSize * 0.7,
                          fontKey: ElementKey.seconds,
                          textColor: Color(
                            _settings.colorFor(ElementKey.seconds),
                          ),
                          cardBg: cardBg,
                          fontFamily: _settings.fontFor(ElementKey.seconds),
                        ),
                        SizedBox(width: gap * 0.7),
                        MechanicalFlipTile(
                          text: _seconds.length > 1 ? _seconds[1] : '0',
                          width: cardW * 0.7,
                          height: cardH * 0.7,
                          fontSize: numSize * 0.7,
                          fontKey: ElementKey.seconds,
                          textColor: Color(
                            _settings.colorFor(ElementKey.seconds),
                          ),
                          cardBg: cardBg,
                          fontFamily: _settings.fontFor(ElementKey.seconds),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
            SizedBox(height: 8 * _settings.fontSizeMultiplier),

            // Bottom Row: 3 Live Mechanical Date Flip Cards
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _apply3D(
                  ElementKey.day,
                  MechanicalFlipTile(
                    text: dayStr,
                    width: dateCardW,
                    height: dateCardH,
                    fontSize: dateNumSize,
                    fontKey: ElementKey.day,
                    textColor: Color(_settings.colorFor(ElementKey.day)),
                    cardBg: cardBg,
                    fontFamily: _settings.fontFor(ElementKey.day),
                  ),
                ),
                SizedBox(width: gap),
                _apply3D(
                  ElementKey.date,
                  MechanicalFlipTile(
                    text: dateStr,
                    width: dateCardW * 0.9,
                    height: dateCardH,
                    fontSize: dateNumSize,
                    fontKey: ElementKey.date,
                    textColor: Color(_settings.colorFor(ElementKey.date)),
                    cardBg: cardBg,
                    fontFamily: _settings.fontFor(ElementKey.date),
                  ),
                ),
                SizedBox(width: gap),
                _apply3D(
                  ElementKey.year,
                  MechanicalFlipTile(
                    text: monthStr,
                    width: dateCardW,
                    height: dateCardH,
                    fontSize: dateNumSize,
                    fontKey: ElementKey.year,
                    textColor: Color(_settings.colorFor(ElementKey.year)),
                    cardBg: cardBg,
                    fontFamily: _settings.fontFor(ElementKey.year),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── 5. Swiss Station Clock & 3-Step Weather Pill (Image 5) ───────────────────
  Widget _buildStationWeatherLayout() {
    final pillBg = Color(_settings.colorFor(ElementKey.neonBox));
    final rimCol = Color(_settings.colorFor(ElementKey.glowOuter));
    final dialBg = Color(_settings.colorFor(ElementKey.innerBackground));
    final hourCol = Color(_settings.colorFor(ElementKey.hours));
    final minuteCol = Color(_settings.colorFor(ElementKey.minutes));
    final secCol = Color(_settings.colorFor(ElementKey.seconds));
    final tickCol = Color(_settings.colorFor(ElementKey.separator));

    final weekdayStr = DateFormat('EEEE').format(_dateTime);
    final monthDayStr = _formatWithOrdinal(_dateTime);
    final currentTemp = _settings.weatherTemp.isNotEmpty
        ? '${_settings.weatherTemp}°C'
        : '--°C';
    final currentIcon = WeatherService.getIconForStatus(
      _settings.weatherStatus,
    );

    List<Map<String, dynamic>> forecastList = [];
    try {
      if (_settings.weatherForecastJson.isNotEmpty) {
        final decoded = jsonDecode(_settings.weatherForecastJson);
        if (decoded is List) {
          forecastList = decoded
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
      }
    } catch (_) {}

    final col2Time = forecastList.isNotEmpty
        ? (forecastList[0]['time']?.toString() ?? '+1h')
        : '+1h';
    final col2Temp = forecastList.isNotEmpty
        ? '${forecastList[0]['temp']}°C'
        : currentTemp;
    final col2Icon = forecastList.isNotEmpty
        ? WeatherService.getIconForCode(forecastList[0]['code'] as int? ?? 0)
        : currentIcon;

    final col3Time = forecastList.length > 1
        ? (forecastList[1]['time']?.toString() ?? '+2h')
        : '+2h';
    final col3Temp = forecastList.length > 1
        ? '${forecastList[1]['temp']}°C'
        : currentTemp;
    final col3Icon = forecastList.length > 1
        ? WeatherService.getIconForCode(forecastList[1]['code'] as int? ?? 0)
        : currentIcon;

    final clockSize = (116.0 * _settings.fontSizeMultiplier).clamp(65.0, 180.0);

    return _apply3D(
      ElementKey.neonBox,
      Container(
        padding: EdgeInsets.symmetric(
          horizontal: 18 * _settings.fontSizeMultiplier,
          vertical: 14 * _settings.fontSizeMultiplier,
        ),
        decoration: BoxDecoration(
          color: pillBg,
          borderRadius: BorderRadius.circular(
            44 * _settings.fontSizeMultiplier,
          ),
          boxShadow: [
            BoxShadow(
              color: pillBg.withValues(alpha: 0.4),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Left: Analog Swiss Station Clock with editable colors & background
            _apply3D(
              ElementKey.hours,
              Container(
                width: clockSize,
                height: clockSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dialBg,
                  border: Border.all(color: rimCol, width: 5.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: ClipOval(
                  child: CustomPaint(
                    painter: StationClockDialPainter(
                      dateTime: _dateTime,
                      dialColor: dialBg,
                      handColor: hourCol,
                      minuteHandColor: minuteCol,
                      secondColor: secCol,
                      tickColor: tickCol,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(width: 18 * _settings.fontSizeMultiplier),

            // Right: Date & 3-Step Weather Forecast with Interactive Location
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _apply3D(
                  ElementKey.day,
                  Text(
                    weekdayStr,
                    style: _styleFor(
                      ElementKey.day,
                      baseSize: 12,
                      weight: FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                _apply3D(
                  ElementKey.date,
                  Text(
                    monthDayStr,
                    style: _styleFor(
                      ElementKey.date,
                      baseSize: 21,
                      weight: FontWeight.w700,
                    ).copyWith(letterSpacing: -0.2),
                  ),
                ),
                SizedBox(height: 5 * _settings.fontSizeMultiplier),
                Container(
                  width: 165 * _settings.fontSizeMultiplier,
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.25),
                ),
                SizedBox(height: 7 * _settings.fontSizeMultiplier),

                // 3-step forecast columns with quick tap-to-refresh
                GestureDetector(
                  onTap: () {
                    _fetchWeatherAndUpdate();
                  },
                  child: _apply3D(
                    ElementKey.weatherTemp,
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildForecastCol(currentIcon, currentTemp, 'Now'),
                        SizedBox(width: 16 * _settings.fontSizeMultiplier),
                        _buildForecastCol(col2Icon, col2Temp, col2Time),
                        SizedBox(width: 16 * _settings.fontSizeMultiplier),
                        _buildForecastCol(col3Icon, col3Temp, col3Time),
                      ],
                    ),
                  ),
                ),
                if (_settings.weatherLocationResolved.isNotEmpty) ...[
                  SizedBox(height: 5 * _settings.fontSizeMultiplier),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.location_on_rounded,
                        size: 9 * _settings.fontSizeMultiplier,
                        color: Colors.white70,
                      ),
                      const SizedBox(width: 3),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: 160 * _settings.fontSizeMultiplier,
                        ),
                        child: Text(
                          _settings.weatherLocationResolved,
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 8.5 * _settings.fontSizeMultiplier,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForecastCol(IconData icon, String temp, String time) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 18 * _settings.fontSizeMultiplier,
          color: Colors.white,
        ),
        const SizedBox(height: 3),
        Text(
          temp,
          style: TextStyle(
            color: Colors.white,
            fontSize: 11 * _settings.fontSizeMultiplier,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          time,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 9 * _settings.fontSizeMultiplier,
          ),
        ),
      ],
    );
  }

  // ── Main build ────────────────────────────────────────────────────────────

  List<Widget> _buildResizeHandles(BuildContext context) {
    if (_settings.isLocked) return const [];
    final isTaskbar = _settings.widgetTemplate.startsWith('taskbar_');
    final handleSize = isTaskbar ? 4.0 : 8.0;
    final cornerSize = isTaskbar ? 8.0 : 16.0;

    void onResizeStart(ResizeEdge edge) {
      if (_settings.isLocked) return;
      if (_settings.autoSizing) {
        _settings.autoSizing = false;
        unawaited(
          _settingsService.updateSettings((c) => c.copyWith(autoSizing: false)),
        );
      }
      _startUserWindowInteraction();
      windowManager.startResizing(edge);
    }

    return [
      // Top edge
      Positioned(
        top: 0,
        left: cornerSize,
        right: cornerSize,
        height: handleSize,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeUp,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => onResizeStart(ResizeEdge.top),
            onPanEnd: (_) => _endUserWindowInteraction(),
            onPanCancel: () => _endUserWindowInteraction(),
            child: const SizedBox.expand(),
          ),
        ),
      ),
      // Bottom edge
      Positioned(
        bottom: 0,
        left: cornerSize,
        right: cornerSize,
        height: handleSize,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeDown,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => onResizeStart(ResizeEdge.bottom),
            onPanEnd: (_) => _endUserWindowInteraction(),
            onPanCancel: () => _endUserWindowInteraction(),
            child: const SizedBox.expand(),
          ),
        ),
      ),
      // Left edge
      Positioned(
        left: 0,
        top: cornerSize,
        bottom: cornerSize,
        width: handleSize,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeLeft,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => onResizeStart(ResizeEdge.left),
            onPanEnd: (_) => _endUserWindowInteraction(),
            onPanCancel: () => _endUserWindowInteraction(),
            child: const SizedBox.expand(),
          ),
        ),
      ),
      // Right edge
      Positioned(
        right: 0,
        top: cornerSize,
        bottom: cornerSize,
        width: handleSize,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeRight,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => onResizeStart(ResizeEdge.right),
            onPanEnd: (_) => _endUserWindowInteraction(),
            onPanCancel: () => _endUserWindowInteraction(),
            child: const SizedBox.expand(),
          ),
        ),
      ),
      // Top Left corner
      Positioned(
        left: 0,
        top: 0,
        width: cornerSize,
        height: cornerSize,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeUpLeft,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => onResizeStart(ResizeEdge.topLeft),
            onPanEnd: (_) => _endUserWindowInteraction(),
            onPanCancel: () => _endUserWindowInteraction(),
            child: const SizedBox.expand(),
          ),
        ),
      ),
      // Top Right corner
      Positioned(
        right: 0,
        top: 0,
        width: cornerSize,
        height: cornerSize,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeUpRight,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => onResizeStart(ResizeEdge.topRight),
            onPanEnd: (_) => _endUserWindowInteraction(),
            onPanCancel: () => _endUserWindowInteraction(),
            child: const SizedBox.expand(),
          ),
        ),
      ),
      // Bottom Left corner
      Positioned(
        left: 0,
        bottom: 0,
        width: cornerSize,
        height: cornerSize,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeDownLeft,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => onResizeStart(ResizeEdge.bottomLeft),
            onPanEnd: (_) => _endUserWindowInteraction(),
            onPanCancel: () => _endUserWindowInteraction(),
            child: const SizedBox.expand(),
          ),
        ),
      ),
      // Bottom Right corner
      Positioned(
        right: 0,
        bottom: 0,
        width: cornerSize,
        height: cornerSize,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeDownRight,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => onResizeStart(ResizeEdge.bottomRight),
            onPanEnd: (_) => _endUserWindowInteraction(),
            onPanCancel: () => _endUserWindowInteraction(),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    ];
  }

  Future<bool> _toggleWifi(bool enable) async {
    try {
      await SystemConnectivityService.instance.setWifiEnabled(enable);
      await _persistConnectivityState();
      return true;
    } catch (e, st) {
      logError('DesktopWidget', 'Failed to change Wi-Fi state', e, st);
      _showConnectivityError('Wi-Fi', e);
      return false;
    }
  }

  Future<bool> _toggleBluetooth(bool enable) async {
    try {
      await SystemConnectivityService.instance.setBluetoothEnabled(enable);
      await _persistConnectivityState();
      return true;
    } catch (e, st) {
      logError('DesktopWidget', 'Failed to change Bluetooth state', e, st);
      _showConnectivityError('Bluetooth', e);
      return false;
    }
  }

  void _syncConnectivityService() {
    final needsConnectivity =
        (_settings.widgetTemplate == 'custom' &&
            _settings.customElements.any(
              (element) =>
                  element.type == 'wifi_icon' ||
                  element.type == 'bluetooth_icon',
            )) ||
        (_settings.widgetTemplate != 'custom' &&
            (_settings.showWifi || _settings.showBluetooth));
    final service = SystemConnectivityService.instance;
    if (needsConnectivity && !_connectivityServiceActive) {
      _connectivityServiceActive = true;
      _connectivity = service.current;
      _connectivitySubscription = service.stream.listen((snapshot) {
        if (!mounted || snapshot == _connectivity) return;
        setState(() => _connectivity = snapshot);
      });
      service.start(owner: 'overlay');
    } else if (!needsConnectivity && _connectivityServiceActive) {
      _connectivityServiceActive = false;
      _connectivitySubscription?.cancel();
      _connectivitySubscription = null;
      service.stop(owner: 'overlay');
    }
  }

  Future<void> _persistConnectivityState() async {
    await SystemConnectivityService.instance.refresh();
    if (!mounted) return;
    final snapshot = SystemConnectivityService.instance.current;
    final updated = _settings.copyWith(
      wifiEnabled: snapshot.wifiEnabled ?? _settings.wifiEnabled,
      bluetoothEnabled: snapshot.bluetoothEnabled ?? _settings.bluetoothEnabled,
    );
    setState(() {
      _connectivity = snapshot;
      _settings = updated;
    });
    await _settingsService.saveSettings(updated);
  }

  void _showConnectivityError(String adapterName, Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not change $adapterName: $error')),
    );
  }

  Widget _buildSleepWeatherLayout() {
    final tempText = _settings.weatherTemp.isNotEmpty
        ? '${_settings.weatherTemp} °C'
        : '-- °C';
    final resolvedLoc = _settings.weatherLocationResolved.isNotEmpty
        ? _settings.weatherLocationResolved
        : 'Auto-detecting...';
    final mediaSubtitle = [
      _mediaInfo.artist,
      _mediaInfo.album,
      _mediaInfo.source,
      _mediaInfo.status == 'Closed' ? '' : _mediaInfo.status,
    ].where((value) => value.isNotEmpty).join(' • ');

    IconData weatherIcon = Icons.wb_cloudy_rounded;
    if (_settings.weatherStatus.isNotEmpty) {
      final statusLower = _settings.weatherStatus.toLowerCase();
      if (statusLower.contains('clear') || statusLower.contains('sunny')) {
        weatherIcon = Icons.wb_sunny_rounded;
      } else if (statusLower.contains('drizzle') ||
          statusLower.contains('rain')) {
        weatherIcon = Icons.water_drop_rounded;
      } else if (statusLower.contains('fog')) {
        weatherIcon = Icons.filter_drama_rounded;
      } else if (statusLower.contains('snow')) {
        weatherIcon = Icons.ac_unit_rounded;
      } else if (statusLower.contains('thunderstorm')) {
        weatherIcon = Icons.thunderstorm_rounded;
      }
    }

    String formatTime(int secs) {
      final h = secs ~/ 3600;
      final m = (secs % 3600) ~/ 60;
      final s = secs % 60;
      if (h > 0) {
        return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      } else {
        return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      }
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Left side: Date & Time, pushed down to Y = 44.0 (below folder tab notch Y = 36)
        Positioned(
          top: 44,
          left: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _apply3D(
                    ElementKey.day,
                    Text(
                      DateFormat('EEEE').format(_dateTime),
                      style: _styleFor(
                        ElementKey.day,
                        baseSize: 16,
                        weight: FontWeight.w600,
                      ).copyWith(letterSpacing: -0.5),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: _apply3D(
                      ElementKey.date,
                      Text(
                        DateFormat('d').format(_dateTime),
                        style: _styleFor(
                          ElementKey.date,
                          baseSize: 10,
                          weight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _apply3D(
                    ElementKey.hours,
                    Text(
                      _hours,
                      style: _styleFor(
                        ElementKey.hours,
                        baseSize: 54,
                        weight: FontWeight.w700,
                      ).copyWith(height: 0.9, letterSpacing: -2.0),
                    ),
                  ),
                  _apply3D(
                    ElementKey.separator,
                    Text(
                      ':',
                      style: _styleFor(
                        ElementKey.separator,
                        baseSize: 50,
                        weight: FontWeight.w300,
                      ).copyWith(height: 0.9),
                    ),
                  ),
                  _apply3D(
                    ElementKey.minutes,
                    Text(
                      _minutes,
                      style: _styleFor(
                        ElementKey.minutes,
                        baseSize: 54,
                        weight: FontWeight.w700,
                      ).copyWith(height: 0.9, letterSpacing: -2.0),
                    ),
                  ),
                  if (_settings.showSeconds) ...[
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _apply3D(
                        ElementKey.seconds,
                        Text(
                          _seconds,
                          style: _styleFor(
                            ElementKey.seconds,
                            baseSize: 18,
                            weight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (!_settings.use24HourFormat) ...[
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _apply3D(
                        ElementKey.ampm,
                        Text(
                          _ampm,
                          style: _styleFor(
                            ElementKey.ampm,
                            baseSize: 12,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),

        // Right side: WiFi & Bluetooth, positioned on the raised tab (top: 12)
        if (_settings.showWifi || _settings.showBluetooth)
          Positioned(
            top: 12,
            right: 16,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_settings.showWifi)
                  GestureDetector(
                    onTap: () async {
                      final targetState =
                          !(_connectivity.wifiEnabled ?? _settings.wifiEnabled);
                      if (!await _toggleWifi(targetState)) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Could not change Wi-Fi state.'),
                            ),
                          );
                        }
                        return;
                      }
                      if (!mounted) return;
                      final updated = _settings.copyWith(
                        wifiEnabled: targetState,
                      );
                      setState(() {
                        _settings = updated;
                      });
                      await _settingsService.saveSettings(updated);
                    },
                    child: _apply3D(
                      ElementKey.wifiIcon,
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color:
                              (_connectivity.wifiEnabled ??
                                  _settings.wifiEnabled)
                              ? Color(
                                  _settings.colorFor(ElementKey.wifiIcon),
                                ).withValues(alpha: 0.08)
                              : Colors.white.withValues(alpha: 0.03),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color:
                                (_connectivity.wifiEnabled ??
                                    _settings.wifiEnabled)
                                ? Color(
                                    _settings.colorFor(ElementKey.wifiIcon),
                                  ).withValues(alpha: 0.15)
                                : Colors.white.withValues(alpha: 0.05),
                          ),
                        ),
                        child: Icon(
                          Icons.wifi_rounded,
                          size: _settings.sizeFor(ElementKey.wifiIcon, 16),
                          color:
                              (_connectivity.wifiEnabled ??
                                  _settings.wifiEnabled)
                              ? Color(_settings.colorFor(ElementKey.wifiIcon))
                              : Color(
                                  _settings.colorFor(ElementKey.wifiIcon),
                                ).withValues(alpha: 0.24),
                        ),
                      ),
                    ),
                  ),
                if (_settings.showWifi && _settings.showBluetooth)
                  const SizedBox(width: 8),
                if (_settings.showBluetooth)
                  GestureDetector(
                    onTap: () async {
                      final targetState =
                          !(_connectivity.bluetoothEnabled ??
                              _settings.bluetoothEnabled);
                      if (!await _toggleBluetooth(targetState)) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Could not change Bluetooth state.',
                              ),
                            ),
                          );
                        }
                        return;
                      }
                      if (!mounted) return;
                      final updated = _settings.copyWith(
                        bluetoothEnabled: targetState,
                      );
                      setState(() {
                        _settings = updated;
                      });
                      await _settingsService.saveSettings(updated);
                    },
                    child: _apply3D(
                      ElementKey.bluetoothIcon,
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color:
                              (_connectivity.bluetoothEnabled ??
                                  _settings.bluetoothEnabled)
                              ? Color(
                                  _settings.colorFor(ElementKey.bluetoothIcon),
                                ).withValues(alpha: 0.12)
                              : Colors.white.withValues(alpha: 0.03),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color:
                                (_connectivity.bluetoothEnabled ??
                                    _settings.bluetoothEnabled)
                                ? Color(
                                    _settings.colorFor(
                                      ElementKey.bluetoothIcon,
                                    ),
                                  ).withValues(alpha: 0.4)
                                : Colors.white.withValues(alpha: 0.05),
                          ),
                          boxShadow:
                              (_connectivity.bluetoothEnabled ??
                                  _settings.bluetoothEnabled)
                              ? [
                                  BoxShadow(
                                    color: Color(
                                      _settings.colorFor(
                                        ElementKey.bluetoothIcon,
                                      ),
                                    ).withValues(alpha: 0.15),
                                    blurRadius: 6,
                                    spreadRadius: 1,
                                  ),
                                ]
                              : null,
                        ),
                        child: Icon(
                          Icons.bluetooth_rounded,
                          size: _settings.sizeFor(ElementKey.bluetoothIcon, 16),
                          color:
                              (_connectivity.bluetoothEnabled ??
                                  _settings.bluetoothEnabled)
                              ? Color(
                                  _settings.colorFor(ElementKey.bluetoothIcon),
                                )
                              : Color(
                                  _settings.colorFor(ElementKey.bluetoothIcon),
                                ).withValues(alpha: 0.24),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

        // Large Media Cover Image on the right of the clock (green box space)
        if (_settings.showMediaControl)
          Positioned(
            top: 56,
            right: 16,
            child: _apply3D(
              ElementKey.mediaIcon,
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: _thumbnailBytes == null
                    ? Icon(
                        _mediaInfo.title.isEmpty
                            ? Icons.music_off_rounded
                            : Icons.album_rounded,
                        color: Colors.white38,
                        size: 42,
                      )
                    : Image.memory(
                        _thumbnailBytes!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (context, error, stackTrace) =>
                            const Icon(
                              Icons.album_rounded,
                              color: Colors.white38,
                              size: 42,
                            ),
                      ),
              ),
            ),
          ),

        // Middle: Media controls (replacing Sleep timeline) inside the custom background shape
        if (_settings.showMediaControl)
          Positioned(
            left: 16,
            right: 16,
            bottom: 52,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'MEDIA CONTROL',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                    fontFamily: 'Segoe UI',
                  ),
                ),
                const SizedBox(height: 6),
                _apply3D(
                  ElementKey.mediaBg,
                  CustomPaint(
                    painter: SleepTrackerPainter(
                      color: Color(_settings.colorFor(ElementKey.mediaBg)),
                    ),
                    child: Container(
                      width: double.infinity,
                      height: 48,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          _apply3D(
                            ElementKey.mediaIcon,
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(width: 6),
                                IconButton(
                                  tooltip: 'Previous track',
                                  onPressed: _mediaInfo.canGoPrevious
                                      ? () async {
                                          await MediaSessionService()
                                              .previous();
                                        }
                                      : null,
                                  icon: const Icon(Icons.skip_previous_rounded),
                                  color: Color(
                                    _settings.colorFor(ElementKey.mediaIcon),
                                  ),
                                  disabledColor: Colors.white24,
                                  iconSize: _settings.sizeFor(
                                    ElementKey.mediaIcon,
                                    20,
                                  ),
                                  padding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                  constraints: const BoxConstraints(
                                    minWidth: 24,
                                    minHeight: 24,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  tooltip: _mediaInfo.isPlaying
                                      ? 'Pause'
                                      : 'Play',
                                  onPressed: _mediaInfo.isPlaying
                                      ? _mediaInfo.canPause
                                            ? () async {
                                                await MediaSessionService()
                                                    .pause();
                                              }
                                            : null
                                      : _mediaInfo.canPlay
                                      ? () async {
                                          await MediaSessionService().play();
                                        }
                                      : null,
                                  icon: Icon(
                                    _mediaInfo.isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                  ),
                                  color: Color(
                                    _settings.colorFor(ElementKey.mediaIcon),
                                  ),
                                  disabledColor: Colors.white24,
                                  iconSize: _settings.sizeFor(
                                    ElementKey.mediaIcon,
                                    22,
                                  ),
                                  padding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                  constraints: const BoxConstraints(
                                    minWidth: 24,
                                    minHeight: 24,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  tooltip: 'Next track',
                                  onPressed: _mediaInfo.canGoNext
                                      ? () async {
                                          await MediaSessionService().next();
                                        }
                                      : null,
                                  icon: const Icon(Icons.skip_next_rounded),
                                  color: Color(
                                    _settings.colorFor(ElementKey.mediaIcon),
                                  ),
                                  disabledColor: Colors.white24,
                                  iconSize: _settings.sizeFor(
                                    ElementKey.mediaIcon,
                                    20,
                                  ),
                                  padding: EdgeInsets.zero,
                                  visualDensity: VisualDensity.compact,
                                  constraints: const BoxConstraints(
                                    minWidth: 24,
                                    minHeight: 24,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          // Controls & song info
                          Expanded(
                            flex: 72,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (_mediaInfo.source.isEmpty &&
                                    _mediaInfo.title.isEmpty)
                                  _apply3D(
                                    ElementKey.mediaTitle,
                                    Text(
                                      'No media playing',
                                      style: _styleFor(
                                        ElementKey.mediaTitle,
                                        baseSize: 10,
                                        weight: FontWeight.w900,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  )
                                else ...[
                                  _apply3D(
                                    ElementKey.mediaTitle,
                                    Text(
                                      _mediaInfo.title.isNotEmpty
                                          ? _mediaInfo.title
                                          : _mediaInfo.source,
                                      style: _styleFor(
                                        ElementKey.mediaTitle,
                                        baseSize: 10,
                                        weight: FontWeight.w900,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  _apply3D(
                                    ElementKey.mediaArtist,
                                    Text(
                                      mediaSubtitle,
                                      style: _styleFor(
                                        ElementKey.mediaArtist,
                                        baseSize: 8,
                                        weight: FontWeight.w500,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          // Time progress in the raised tab on the right
                          Expanded(
                            flex: 28,
                            child: Center(
                              child: _apply3D(
                                ElementKey.mediaTime,
                                ValueListenableBuilder<int>(
                                  valueListenable: _playbackPositionNotifier,
                                  builder: (context, pos, _) {
                                    final duration = _mediaInfo.duration;
                                    final text = duration <= 0
                                        ? _mediaInfo.status.toUpperCase()
                                        : '${formatTime(pos)} / ${formatTime(duration)}';
                                    return Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        if (duration > 0) ...[
                                          SizedBox(
                                            width: 76,
                                            child: LinearProgressIndicator(
                                              value: (pos / duration).clamp(
                                                0.0,
                                                1.0,
                                              ),
                                              minHeight: 3,
                                              backgroundColor: Colors.white12,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                    Color(
                                                      _settings.colorFor(
                                                        ElementKey.mediaTime,
                                                      ),
                                                    ),
                                                  ),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                        ],
                                        Text(
                                          text,
                                          style: _styleFor(
                                            ElementKey.mediaTime,
                                            baseSize: 9,
                                            weight: FontWeight.w900,
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

        // Bottom: Weather
        if (_settings.showWeather)
          Positioned(
            left: 16,
            right: 16,
            bottom: 12,
            child: Tooltip(
              message: resolvedLoc,
              child: GestureDetector(
                onTap: () {
                  setState(() {
                    _showWeatherSearchOverlay = true;
                  });
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _apply3D(
                        ElementKey.weatherIcon,
                        Icon(
                          weatherIcon,
                          color: Color(
                            _settings.colorFor(ElementKey.weatherIcon),
                          ),
                          size: _settings.sizeFor(ElementKey.weatherIcon, 14),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _apply3D(
                        ElementKey.weatherTemp,
                        Text(
                          tempText,
                          style: _styleFor(
                            ElementKey.weatherTemp,
                            baseSize: 13,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (_settings.weatherStatus.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _apply3D(
                          ElementKey.weatherStatus,
                          Text(
                            _settings.weatherStatus,
                            style: _styleFor(
                              ElementKey.weatherStatus,
                              baseSize: 11,
                              weight: FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 4),
                      Icon(
                        Icons.search_rounded,
                        color: Colors.white.withValues(alpha: 0.2),
                        size: 10,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildWeatherSearchOverlay() {
    return Container(
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.92)),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'WEATHER LOCATION',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.close_rounded,
                  color: Colors.white70,
                  size: 16,
                ),
                onPressed: () {
                  setState(() {
                    _showWeatherSearchOverlay = false;
                    _weatherSearchError = '';
                  });
                },
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 34,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: TextField(
                    controller: _weatherQueryController,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    cursorColor: const Color(0xFF00FF55),
                    decoration: const InputDecoration(
                      hintText: 'Enter city or pincode...',
                      hintStyle: TextStyle(color: Colors.white30, fontSize: 12),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      isDense: true,
                    ),
                    onSubmitted: (val) => _handleManualWeatherSearch(val),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(
                  Icons.gps_fixed_rounded,
                  color: Color(0xFF00FF55),
                  size: 16,
                ),
                tooltip: 'Auto-detect location',
                onPressed: () {
                  _weatherQueryController.clear();
                  _handleAutoDetectWeather();
                },
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.06),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  minimumSize: const Size(34, 34),
                ),
              ),
            ],
          ),
          if (_weatherSearchError.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              _weatherSearchError,
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () =>
                _handleManualWeatherSearch(_weatherQueryController.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00FF55),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
              minimumSize: const Size(0, 34),
            ),
            child: const Text(
              'Search & Update',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  void _startWeatherTimer() {
    _weatherTimer?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fetchWeatherAndUpdate();
    });
    _weatherTimer = Timer.periodic(const Duration(minutes: 15), (timer) {
      _fetchWeatherAndUpdate();
    });
  }

  Future<void> _fetchWeatherAndUpdate() async {
    if (_isFetchingWeather) return;
    _isFetchingWeather = true;
    try {
      final weatherLocation = _settings.weatherLocation.trim();
      final weatherService = WeatherService();
      if (weatherLocation.isEmpty) {
        final loc = await weatherService.autoDetectLocation();
        if (loc != null) {
          final lat = loc['lat'] as double;
          final lon = loc['lon'] as double;
          final city = loc['city'] as String;
          final resolvedName = '$city, ${loc['countryCode']}';
          final info = await weatherService.fetchWeather(
            lat,
            lon,
            resolvedName,
          );
          if (info != null && mounted) {
            final updated = _settings.copyWith(
              weatherTemp: info.temperature.toStringAsFixed(1),
              weatherStatus: info.status,
              weatherLocationResolved: info.locationName,
              weatherForecastJson: info.forecastJson,
            );
            setState(() => _settings = updated);
            await _settingsService.saveSettings(updated);
          }
        }
      } else {
        final loc = await weatherService.searchLocation(weatherLocation);
        if (loc != null) {
          final lat = loc['lat'] as double;
          final lon = loc['lon'] as double;
          final resolvedName = loc['name'] as String;
          final info = await weatherService.fetchWeather(
            lat,
            lon,
            resolvedName,
          );
          if (info != null && mounted) {
            final updated = _settings.copyWith(
              weatherTemp: info.temperature.toStringAsFixed(1),
              weatherStatus: info.status,
              weatherLocationResolved: info.locationName,
              weatherForecastJson: info.forecastJson,
            );
            setState(() => _settings = updated);
            await _settingsService.saveSettings(updated);
          }
        }
      }
    } catch (e) {
      debugPrint('[DesktopWidget] Failed to auto-fetch weather: $e');
    } finally {
      _isFetchingWeather = false;
    }
  }

  Future<void> _handleManualWeatherSearch(String val) async {
    if (val.trim().isEmpty) return;
    setState(() {
      _weatherSearchError = '';
    });
    try {
      final loc = await WeatherService().searchLocation(val);
      if (!mounted) return;
      if (loc != null) {
        final lat = loc['lat'] as double;
        final lon = loc['lon'] as double;
        final name = loc['name'] as String;
        final info = await WeatherService().fetchWeather(lat, lon, name);
        if (!mounted) return;
        if (info != null && mounted) {
          final updated = _settings.copyWith(
            weatherLocation: val,
            weatherTemp: info.temperature.toStringAsFixed(1),
            weatherStatus: info.status,
            weatherLocationResolved: info.locationName,
            weatherForecastJson: info.forecastJson,
          );
          setState(() {
            _settings = updated;
            _showWeatherSearchOverlay = false;
          });
          await _settingsService.saveSettings(updated);
        } else {
          setState(() {
            _weatherSearchError = 'Could not fetch weather data.';
          });
        }
      } else {
        setState(() {
          _weatherSearchError = 'Location not found.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _weatherSearchError = 'Error: $e';
        });
      }
    }
  }

  Future<void> _handleAutoDetectWeather() async {
    setState(() {
      _weatherSearchError = '';
    });
    try {
      final loc = await WeatherService().autoDetectLocation();
      if (!mounted) return;
      if (loc != null) {
        final lat = loc['lat'] as double;
        final lon = loc['lon'] as double;
        final city = loc['city'] as String;
        final resolvedName = '$city, ${loc['countryCode']}';
        final info = await WeatherService().fetchWeather(
          lat,
          lon,
          resolvedName,
        );
        if (!mounted) return;
        if (info != null && mounted) {
          final updated = _settings.copyWith(
            weatherLocation: '',
            weatherTemp: info.temperature.toStringAsFixed(1),
            weatherStatus: info.status,
            weatherLocationResolved: info.locationName,
            weatherForecastJson: info.forecastJson,
          );
          setState(() {
            _settings = updated;
            _showWeatherSearchOverlay = false;
          });
          await _settingsService.saveSettings(updated);
        } else {
          setState(() {
            _weatherSearchError =
                'Could not fetch weather for auto-detected location.';
          });
        }
      } else {
        setState(() {
          _weatherSearchError = 'Could not auto-detect location.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _weatherSearchError = 'Error auto-detecting: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const SizedBox.shrink();
    if (_startupError != null) {
      return Center(
        child: Text(
          _startupError!,
          style: const TextStyle(color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      );
    }

    final isSleepWeather = _settings.widgetTemplate == 'sleep_weather';
    final isTaskbar = _settings.widgetTemplate.startsWith('taskbar_');
    final isTaskbarReplacement =
        _settings.widgetTemplate == 'taskbar_dock' &&
        _settings.taskbarSettings.nativeTaskbarHideEnabled;
    final defaults =
        WidgetSettings.templateDefaults[_settings.widgetTemplate] ??
        {'width': 360.0, 'height': 200.0, 'sizeFactor': 1.0};
    final baseWidth =
        _settings.widgetTemplate == 'custom' && _settings.width > 0
        ? _settings.width
        : defaults['width']!;
    final baseHeight =
        _settings.widgetTemplate == 'custom' && _settings.height > 0
        ? _settings.height
        : defaults['height']!;

    Widget mainWidget;
    if (isSleepWeather) {
      mainWidget = CustomPaint(
        painter: FolderTabPainter(
          color: const Color(0xFF0F0F11),
          shadowColor: Colors.black.withValues(alpha: 0.6),
          blurRadius: 16,
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipPath(
                clipper: FolderTabClipper(),
                child: _buildBackground(context),
              ),
            ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onSecondaryTapUp: (d) =>
                    _showContextMenu(context, d.globalPosition),
                onPanStart: (d) {
                  _handleInteraction();
                  if (!_settings.isLocked) {
                    _startUserWindowInteraction();
                    windowManager.startDragging();
                  }
                },
                onPanEnd: (_) => _endUserWindowInteraction(),
                onPanCancel: () => _endUserWindowInteraction(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 16,
                  ),
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: SizedBox(
                        width: baseWidth,
                        height: baseHeight,
                        child: Transform.scale(
                          scale: _settings.sizeFactor,
                          child: _buildLayout(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_showWeatherSearchOverlay)
              Positioned.fill(
                child: ClipPath(
                  clipper: FolderTabClipper(),
                  child: _buildWeatherSearchOverlay(),
                ),
              ),
          ],
        ),
      );
    } else if (isTaskbar) {
      final effectiveWidth = math.max(baseWidth, _settings.width);
      mainWidget = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: (d) => _showContextMenu(context, d.globalPosition),
        onPanStart: (d) {
          _handleInteraction();
          if (!_settings.isLocked &&
              !isTaskbarReplacement &&
              !_usesNativeTaskbarAppBar) {
            _startUserWindowInteraction();
            windowManager.startDragging();
          }
        },
        onPanEnd: (_) => _endUserWindowInteraction(),
        onPanCancel: () => _endUserWindowInteraction(),
        child: isTaskbarReplacement
            ? SizedBox.expand(child: _buildLayout())
            : Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: effectiveWidth,
                    height: baseHeight,
                    child: Transform.scale(
                      scale: _settings.sizeFactor,
                      child: _buildLayout(),
                    ),
                  ),
                ),
              ),
      );
    } else {
      mainWidget = Stack(
        children: [
          Positioned.fill(child: _buildBackground(context)),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onSecondaryTapUp: (d) =>
                  _showContextMenu(context, d.globalPosition),
              onPanStart: (d) {
                _handleInteraction();
                if (!_settings.isLocked) {
                  _startUserWindowInteraction();
                  windowManager.startDragging();
                }
              },
              onPanEnd: (_) => _endUserWindowInteraction(),
              onPanCancel: () => _endUserWindowInteraction(),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: baseWidth,
                      height: baseHeight,
                      child: Transform.scale(
                        scale: _settings.sizeFactor,
                        child: _buildLayout(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return RepaintBoundary(
      child: Listener(
        onPointerDown: (_) => _handleInteraction(),
        onPointerMove: (_) => _handleInteraction(),
        onPointerHover: (_) => _handleInteraction(),
        child: MouseRegion(
          onHover: (_) => _handleInteraction(),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onSecondaryTapUp: (d) =>
                _showContextMenu(context, d.globalPosition),
            onTap: () {
              if (_visualEditorModeActive) {
                logInfo(
                  'DesktopWidget',
                  'Tap outside detected. Exiting visual editor mode.',
                );
                _exitVisualEditorMode();
              }
            },
            child: Stack(
              children: [
                Positioned.fill(child: mainWidget),
                if (_visualEditorModeActive && !_settings.isLocked) ...[
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring: true,
                      child: isSleepWeather
                          ? CustomPaint(
                              painter: FolderTabBorderPainter(
                                color: const Color(
                                  0xFF00E5FF,
                                ).withValues(alpha: 0.6),
                                strokeWidth: 2.0,
                              ),
                            )
                          : Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: const Color(
                                    0xFF00E5FF,
                                  ).withValues(alpha: 0.6),
                                  width: isTaskbar ? 1.5 : 2.0,
                                  style: BorderStyle.solid,
                                ),
                                borderRadius: BorderRadius.circular(
                                  isTaskbar ? 10 : 24,
                                ),
                              ),
                            ),
                    ),
                  ),
                  // Editor Mode drag handle label
                  Positioned(
                    top: isSleepWeather ? 42 : (isTaskbar ? 2 : 6),
                    left: isTaskbar ? 6 : 12,
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: isTaskbar ? 4 : 6,
                        vertical: isTaskbar ? 1 : 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E5FF),
                        borderRadius: BorderRadius.circular(3),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.2),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      child: Text(
                        isTaskbar
                            ? 'EDITOR MODE'
                            : 'EDITOR MODE - DRAG EDGES TO RESIZE',
                        style: TextStyle(
                          color: const Color(0xFF060609),
                          fontSize: isTaskbar ? 7.5 : 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                  ..._buildResizeHandles(context),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class FolderTabClipper extends CustomClipper<Path> {
  final double r;
  final double dip;

  FolderTabClipper({this.r = 24.0, this.dip = 36.0});

  @override
  Path getClip(Size size) {
    final path = Path();
    final w = size.width;
    final h = size.height;
    final splitX = w * 0.62;
    final endDipX = w * 0.72;

    path.moveTo(0, dip + r);
    path.quadraticBezierTo(0, dip, r, dip);
    path.lineTo(splitX, dip);
    path.cubicTo(splitX + 15, dip, endDipX - 15, 0, endDipX, 0);
    path.lineTo(w - r, 0);
    path.quadraticBezierTo(w, 0, w, r);
    path.lineTo(w, h - r);
    path.quadraticBezierTo(w, h, w - r, h);
    path.lineTo(r, h);
    path.quadraticBezierTo(0, h, 0, h - r);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(CustomClipper<Path> oldClipper) => true;
}

class FolderTabPainter extends CustomPainter {
  final Color color;
  final Color shadowColor;
  final double blurRadius;
  final double r;
  final double dip;

  FolderTabPainter({
    required this.color,
    required this.shadowColor,
    required this.blurRadius,
    this.r = 24.0,
    this.dip = 36.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final splitX = w * 0.62;
    final endDipX = w * 0.72;

    final path = Path();
    path.moveTo(0, dip + r);
    path.quadraticBezierTo(0, dip, r, dip);
    path.lineTo(splitX, dip);
    path.cubicTo(splitX + 15, dip, endDipX - 15, 0, endDipX, 0);
    path.lineTo(w - r, 0);
    path.quadraticBezierTo(w, 0, w, r);
    path.lineTo(w, h - r);
    path.quadraticBezierTo(w, h, w - r, h);
    path.lineTo(r, h);
    path.quadraticBezierTo(0, h, 0, h - r);
    path.close();

    if (blurRadius > 0) {
      final shadowPaint = Paint()
        ..color = shadowColor
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blurRadius);
      canvas.drawPath(path.shift(const Offset(0, 4)), shadowPaint);
    }

    final bodyPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, bodyPaint);
  }

  @override
  bool shouldRepaint(covariant FolderTabPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.shadowColor != shadowColor ||
        oldDelegate.blurRadius != blurRadius ||
        oldDelegate.r != r ||
        oldDelegate.dip != dip;
  }
}

class FolderTabBorderPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double r;
  final double dip;

  FolderTabBorderPainter({
    required this.color,
    required this.strokeWidth,
    this.r = 24.0,
    this.dip = 36.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final splitX = w * 0.62;
    final endDipX = w * 0.72;

    final path = Path();
    path.moveTo(0, dip + r);
    path.quadraticBezierTo(0, dip, r, dip);
    path.lineTo(splitX, dip);
    path.cubicTo(splitX + 15, dip, endDipX - 15, 0, endDipX, 0);
    path.lineTo(w - r, 0);
    path.quadraticBezierTo(w, 0, w, r);
    path.lineTo(w, h - r);
    path.quadraticBezierTo(w, h, w - r, h);
    path.lineTo(r, h);
    path.quadraticBezierTo(0, h, 0, h - r);
    path.close();

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant FolderTabBorderPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.r != r ||
      oldDelegate.dip != dip;
}

class SleepTrackerPainter extends CustomPainter {
  final Color color;

  SleepTrackerPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    const r = 12.0;
    final splitX = w * 0.75;
    final startCurveX = w * 0.67;
    final dipHeight = 10.0;

    final path = Path();

    path.moveTo(r, h);
    path.lineTo(w - r, h);
    path.quadraticBezierTo(w, h, w, h - r);
    path.lineTo(w, r);
    path.quadraticBezierTo(w, 0, w - r, 0);
    path.lineTo(splitX, 0);
    path.cubicTo(
      splitX - 6,
      0,
      startCurveX + 8,
      dipHeight,
      startCurveX,
      dipHeight,
    );
    path.lineTo(r, dipHeight);
    path.quadraticBezierTo(0, dipHeight, 0, dipHeight + r);
    path.lineTo(0, h - r);
    path.quadraticBezierTo(0, h, r, h);
    path.close();

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant SleepTrackerPainter oldDelegate) =>
      oldDelegate.color != color;
}

// ─────────────────────────────────────────────────────────────────────────────
// ── Live Mechanical Flip Tile Widget (Image 4) ──────────────────────────────
class MechanicalFlipTile extends StatefulWidget {
  final String text;
  final String? subTag;
  final double width;
  final double height;
  final double fontSize;
  final String fontKey;
  final Color textColor;
  final Color cardBg;
  final String fontFamily;

  const MechanicalFlipTile({
    super.key,
    required this.text,
    this.subTag,
    required this.width,
    required this.height,
    required this.fontSize,
    required this.fontKey,
    required this.textColor,
    required this.cardBg,
    required this.fontFamily,
  });

  @override
  State<MechanicalFlipTile> createState() => _MechanicalFlipTileState();
}

class _MechanicalFlipTileState extends State<MechanicalFlipTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  String _currentText = '';
  String _previousText = '';

  @override
  void initState() {
    super.initState();
    _currentText = widget.text;
    _previousText = widget.text;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
  }

  @override
  void didUpdateWidget(covariant MechanicalFlipTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _previousText = oldWidget.text;
      _currentText = widget.text;
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildHalfCard({
    required String text,
    required bool isTop,
    required double width,
    required double height,
  }) {
    return ClipRect(
      child: Align(
        alignment: isTop ? Alignment.topCenter : Alignment.bottomCenter,
        heightFactor: 0.5,
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: widget.cardBg,
            borderRadius: BorderRadius.circular(6 * (width / 54.0)),
            border: Border.all(color: const Color(0xFF2E333D), width: 1.0),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Stack(
            children: [
              Center(
                child: Text(
                  text,
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: widget.fontSize,
                    fontWeight: FontWeight.w900,
                    fontFamily: widget.fontFamily,
                    height: 1.0,
                  ),
                ),
              ),
              if (widget.subTag != null && isTop)
                Positioned(
                  top: 3 * (height / 74.0),
                  left: 4 * (width / 54.0),
                  child: Text(
                    widget.subTag!,
                    style: TextStyle(
                      color: widget.textColor.withValues(alpha: 0.75),
                      fontSize: 7.0 * (widget.fontSize / 34.0),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.width;
    final h = widget.height;

    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 1. Static bottom half with NEW text
          Positioned(
            bottom: 0,
            child: _buildHalfCard(
              text: _currentText,
              isTop: false,
              width: w,
              height: h,
            ),
          ),
          // 2. Static top half with OLD text
          Positioned(
            top: 0,
            child: _buildHalfCard(
              text: _controller.value > 0.5 ? _currentText : _previousText,
              isTop: true,
              width: w,
              height: h,
            ),
          ),
          // 3. 3D Mechanical flap flip animation
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final val = _controller.value;
              if (val == 0.0 || val == 1.0) {
                return Positioned(
                  top: 0,
                  child: _buildHalfCard(
                    text: _currentText,
                    isTop: true,
                    width: w,
                    height: h,
                  ),
                );
              }

              if (val < 0.5) {
                final angle = -val * math.pi;
                return Positioned(
                  top: 0,
                  child: Transform(
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.002)
                      ..rotateX(angle),
                    alignment: Alignment.bottomCenter,
                    child: _buildHalfCard(
                      text: _previousText,
                      isTop: true,
                      width: w,
                      height: h,
                    ),
                  ),
                );
              } else {
                final angle = (1.0 - val) * math.pi;
                return Positioned(
                  bottom: 0,
                  child: Transform(
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.002)
                      ..rotateX(angle),
                    alignment: Alignment.topCenter,
                    child: _buildHalfCard(
                      text: _currentText,
                      isTop: false,
                      width: w,
                      height: h,
                    ),
                  ),
                );
              }
            },
          ),
          // 4. Split Crease Line
          Positioned(
            top: (h / 2) - 0.75,
            left: 0,
            right: 0,
            height: 1.5,
            child: Container(color: Colors.black.withValues(alpha: 0.8)),
          ),
          // 5. Left & right hinge notches
          Positioned(
            top: (h / 2) - 3.0,
            left: 0,
            width: 3.5,
            height: 6.0,
            child: Container(
              decoration: const BoxDecoration(
                color: Color(0xFF111418),
                borderRadius: BorderRadius.only(
                  topRight: Radius.circular(2),
                  bottomRight: Radius.circular(2),
                ),
              ),
            ),
          ),
          Positioned(
            top: (h / 2) - 3.0,
            right: 0,
            width: 3.5,
            height: 6.0,
            child: Container(
              decoration: const BoxDecoration(
                color: Color(0xFF111418),
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(2),
                  bottomLeft: Radius.circular(2),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Arc Clock Dial Painter (Image 3) ──────────────────────────────────────────
class ArcClockDialPainter extends CustomPainter {
  final DateTime dateTime;
  final Color arcStartColor;
  final Color arcEndColor;
  final Color hourHandColor;
  final Color minuteHandColor;
  final Color secondHandColor;
  final Color tickColor;
  final Color dialBgColor;

  ArcClockDialPainter({
    required this.dateTime,
    this.arcStartColor = const Color(0xFF00E5FF),
    this.arcEndColor = const Color(0xFFE040FB),
    this.hourHandColor = const Color(0xFF555B66),
    this.minuteHandColor = const Color(0xFF00E5FF),
    this.secondHandColor = const Color(0xFFE040FB),
    this.tickColor = const Color(0x6600E5FF),
    this.dialBgColor = Colors.transparent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 8;

    if (dialBgColor != Colors.transparent && dialBgColor.a > 0) {
      canvas.drawCircle(center, radius, Paint()..color = dialBgColor);
    }

    // 1. Glowing gradient arc on the left side
    final arcRect = Rect.fromCircle(center: center, radius: radius);
    final gradient = SweepGradient(
      startAngle: math.pi * 0.6,
      endAngle: math.pi * 1.8,
      colors: [arcStartColor, arcEndColor],
      tileMode: TileMode.clamp,
    );

    final arcPaint = Paint()
      ..shader = gradient.createShader(arcRect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    const arcStartAngle = math.pi * 0.55;
    const arcSweepAngle = math.pi * 1.25;
    canvas.drawArc(arcRect, arcStartAngle, arcSweepAngle, false, arcPaint);

    // End caps markers on the arc
    final capPaintMagenta = Paint()
      ..color = arcEndColor
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;
    final capPaintCyan = Paint()
      ..color = arcStartColor
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    final topCapAngle = arcStartAngle + arcSweepAngle;
    canvas.drawLine(
      Offset(
        center.dx + (radius - 5) * math.cos(topCapAngle),
        center.dy + (radius - 5) * math.sin(topCapAngle),
      ),
      Offset(
        center.dx + (radius + 5) * math.cos(topCapAngle),
        center.dy + (radius + 5) * math.sin(topCapAngle),
      ),
      capPaintMagenta,
    );
    canvas.drawLine(
      Offset(
        center.dx + (radius - 5) * math.cos(arcStartAngle),
        center.dy + (radius - 5) * math.sin(arcStartAngle),
      ),
      Offset(
        center.dx + (radius + 5) * math.cos(arcStartAngle),
        center.dy + (radius + 5) * math.sin(arcStartAngle),
      ),
      capPaintCyan,
    );

    // 2. Tick marks along the circle
    final tickPaintFaint = Paint()
      ..color = tickColor.withValues(alpha: 0.35)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    final tickPaintAccent = Paint()
      ..color = arcEndColor.withValues(alpha: 0.85)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    for (int i = 0; i < 12; i++) {
      final angle = i * (math.pi / 6) - (math.pi / 2);
      final isAccent = (i == 9 || i == 0 || i == 3);
      final tickLen = isAccent ? 8.0 : 5.0;

      final p1 = Offset(
        center.dx + (radius - tickLen) * math.cos(angle),
        center.dy + (radius - tickLen) * math.sin(angle),
      );
      final p2 = Offset(
        center.dx + radius * math.cos(angle),
        center.dy + radius * math.sin(angle),
      );
      canvas.drawLine(p1, p2, isAccent ? tickPaintAccent : tickPaintFaint);
    }

    // 3. Hour Hand
    final hourAngle =
        ((dateTime.hour % 12) + dateTime.minute / 60.0) * (math.pi / 6) -
        (math.pi / 2);
    final hourLen = radius * 0.50;
    canvas.drawLine(
      center,
      Offset(
        center.dx + hourLen * math.cos(hourAngle),
        center.dy + hourLen * math.sin(hourAngle),
      ),
      Paint()
        ..color = hourHandColor
        ..strokeWidth = 4.5
        ..strokeCap = StrokeCap.round,
    );

    // 4. Minute Hand
    final minuteAngle =
        (dateTime.minute + dateTime.second / 60.0) * (math.pi / 30) -
        (math.pi / 2);
    final minuteLen = radius * 0.78;
    canvas.drawLine(
      center,
      Offset(
        center.dx + minuteLen * math.cos(minuteAngle),
        center.dy + minuteLen * math.sin(minuteAngle),
      ),
      Paint()
        ..color = minuteHandColor
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round,
    );

    // 5. Center Pivot Hub
    canvas.drawCircle(
      center,
      6.0,
      Paint()
        ..color = minuteHandColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawCircle(
      center,
      2.5,
      Paint()
        ..color = secondHandColor
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant ArcClockDialPainter oldDelegate) => true;
}

// ── Swiss Station Clock Dial Painter (Image 5) ───────────────────────────────
class StationClockDialPainter extends CustomPainter {
  final DateTime dateTime;
  final Color dialColor;
  final Color handColor;
  final Color minuteHandColor;
  final Color secondColor;
  final Color tickColor;

  StationClockDialPainter({
    required this.dateTime,
    this.dialColor = Colors.white,
    this.handColor = const Color(0xFF111827),
    this.minuteHandColor = const Color(0xFF111827),
    this.secondColor = const Color(0xFFEF4444),
    this.tickColor = const Color(0xFF111827),
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;

    // Dial background
    canvas.drawCircle(center, radius, Paint()..color = dialColor);

    // Subtle concentric inner ring
    canvas.drawCircle(
      center,
      radius * 0.55,
      Paint()
        ..color = tickColor.withValues(alpha: 0.1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    // Railroad tick marks around rim
    for (int i = 0; i < 60; i++) {
      final angle = i * (math.pi / 30) - (math.pi / 2);
      final isHour = (i % 5 == 0);
      final tickLen = isHour ? 9.0 : 4.0;
      final tickWidth = isHour ? 2.5 : 1.0;

      final p1 = Offset(
        center.dx + (radius - 4 - tickLen) * math.cos(angle),
        center.dy + (radius - 4 - tickLen) * math.sin(angle),
      );
      final p2 = Offset(
        center.dx + (radius - 4) * math.cos(angle),
        center.dy + (radius - 4) * math.sin(angle),
      );

      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = isHour ? tickColor : tickColor.withValues(alpha: 0.5)
          ..strokeWidth = tickWidth
          ..strokeCap = StrokeCap.square,
      );
    }

    // Hour Hand
    final hourAngle =
        ((dateTime.hour % 12) + dateTime.minute / 60.0) * (math.pi / 6) -
        (math.pi / 2);
    final hourLen = radius * 0.52;
    canvas.drawLine(
      center,
      Offset(
        center.dx + hourLen * math.cos(hourAngle),
        center.dy + hourLen * math.sin(hourAngle),
      ),
      Paint()
        ..color = handColor
        ..strokeWidth = 4.2
        ..strokeCap = StrokeCap.round,
    );

    // Minute Hand
    final minuteAngle =
        (dateTime.minute + dateTime.second / 60.0) * (math.pi / 30) -
        (math.pi / 2);
    final minuteLen = radius * 0.76;
    canvas.drawLine(
      center,
      Offset(
        center.dx + minuteLen * math.cos(minuteAngle),
        center.dy + minuteLen * math.sin(minuteAngle),
      ),
      Paint()
        ..color = minuteHandColor
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round,
    );

    // Second Hand (Swiss Red with counterweight disk)
    final secAngle = dateTime.second * (math.pi / 30) - (math.pi / 2);
    final secLen = radius * 0.82;
    final secBackLen = radius * 0.22;
    final pStart = Offset(
      center.dx - secBackLen * math.cos(secAngle),
      center.dy - secBackLen * math.sin(secAngle),
    );
    final pEnd = Offset(
      center.dx + secLen * math.cos(secAngle),
      center.dy + secLen * math.sin(secAngle),
    );
    canvas.drawLine(
      pStart,
      pEnd,
      Paint()
        ..color = secondColor
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round,
    );

    // Counterweight circular disk on second hand
    final diskCenter = Offset(
      center.dx - secBackLen * 0.7 * math.cos(secAngle),
      center.dy - secBackLen * 0.7 * math.sin(secAngle),
    );
    canvas.drawCircle(diskCenter, 3.5, Paint()..color = secondColor);

    // Center pivot pin
    canvas.drawCircle(center, 4.0, Paint()..color = handColor);
  }

  @override
  bool shouldRepaint(covariant StationClockDialPainter oldDelegate) => true;
}
