import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';
import '../services/live_wallpaper_manager.dart';
import '../services/settings_service.dart';
import '../services/wallpaper_engine.dart';

class WallpaperApp extends StatefulWidget {
  final WidgetSettings settings;
  const WallpaperApp({super.key, required this.settings});

  @override
  State<WallpaperApp> createState() => _WallpaperAppState();
}

class _WallpaperAppState extends State<WallpaperApp> {
  final _controller = WebviewController();
  late final LiveWallpaperManager _liveWallpaperManager = LiveWallpaperManager(
    _controller,
  );
  late WidgetSettings _settings;
  final _settingsService = SettingsService();
  StreamSubscription<FileSystemEvent>? _settingsWatcher;
  StreamSubscription<dynamic>? _playerMessageSubscription;
  final Completer<void> _videoReady = Completer<void>();
  Timer? _watcherDebounce;
  bool _isWebviewInitialized = false;
  Future<void> _settingsUpdateQueue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _settings = widget.settings;
    _playerMessageSubscription = _controller.webMessage.listen(
      _handlePlayerMessage,
      onError: (Object error, StackTrace stackTrace) {
        logError(
          'WallpaperApp',
          'Wallpaper video diagnostics channel failed',
          error,
          stackTrace,
        );
      },
    );
    _initWebview();
    _initSettingsWatcher();
  }

  void _handlePlayerMessage(dynamic message) {
    var payload = message;
    if (payload is String) {
      try {
        payload = jsonDecode(payload);
      } on FormatException catch (error, stackTrace) {
        logError(
          'WallpaperApp',
          'Wallpaper video diagnostics message was not valid JSON',
          error,
          stackTrace,
        );
        return;
      }
    }
    if (payload is! Map) {
      logError(
        'WallpaperApp',
        'Wallpaper video diagnostics message had an unexpected format.',
      );
      return;
    }

    switch (payload['type']) {
      case 'videoReady':
        logInfo(
          'WallpaperApp',
          'Video decoded: ${payload['width']}x${payload['height']}',
        );
        if (!_videoReady.isCompleted) _videoReady.complete();
        break;
      case 'videoError':
        final description =
            'MediaError code ${payload['code']}: ${payload['message']} '
            '(source: ${payload['source']})';
        logError('WallpaperApp', 'Video playback failed: $description');
        if (!_videoReady.isCompleted) {
          _videoReady.completeError(StateError(description));
        }
        break;
    }
  }

  Future<void> _initWebview() async {
    try {
      final localAppData =
          Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
      final webviewDataDirectory = Directory(
        '$localAppData\\WallSyncPro\\WallpaperWebView2',
      );
      await webviewDataDirectory.create(recursive: true);

      logInfo(
        'WallpaperApp',
        'Initializing isolated WebView2 profile: ${webviewDataDirectory.path}',
      );
      await WebviewController.initializeEnvironment(
        userDataPath: webviewDataDirectory.path,
        additionalArguments:
            '--autoplay-policy=no-user-gesture-required '
            '--disable-features=HardwareMediaKeyHandling,MediaRouter,Translate '
            '--disable-background-networking '
            '--disable-background-timer-throttling=0 '
            '--renderer-process-limit=1 '
            '--enable-features=VaapiVideoDecoder '
            '--enable-zero-copy '
            '--enable-gpu-rasterization',
      ).timeout(const Duration(seconds: 30));

      logInfo('WallpaperApp', 'Initializing WebView2 for video playback...');
      await _controller.initialize().timeout(const Duration(seconds: 30));
      logInfo('WallpaperApp', 'WebView2 initialized successfully.');
      logInfo('WallpaperApp', 'Setting WebView background color...');
      await _controller
          .setBackgroundColor(Colors.black)
          .timeout(const Duration(seconds: 15));
      logInfo('WallpaperApp', 'WebView background color set.');

      if (!mounted) return;
      final appDir = await _settingsService.getAppDirectory();
      logInfo('WallpaperApp', 'Mapping html.local to: ${appDir.path}');
      await _controller.addVirtualHostNameMapping(
        'html.local',
        appDir.path,
        WebviewHostResourceAccessKind.allow,
      );

      final initialVideoPath = _settings.activeWallpaperPath ?? '';
      if (initialVideoPath.isEmpty) {
        throw const FormatException(
          'Wallpaper process started without a video path.',
        );
      }
      if (!await _updateVideoHostMapping(initialVideoPath)) {
        throw FileSystemException(
          'Wallpaper video is unavailable.',
          initialVideoPath,
        );
      }
      logInfo('WallpaperApp', 'Generating video player HTML...');
      await _generateHtmlFile(initialVideoPath, _settings.wallpaperFit);
      final videoReady = _videoReady.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw TimeoutException(
          'No decoded video frame was reported within 45 seconds.',
        ),
      );
      logInfo(
        'WallpaperApp',
        'Loading wallpaper HTML via virtual host: https://html.local/wallpaper.html',
      );
      await _controller.loadUrl('https://html.local/wallpaper.html');
      logInfo('WallpaperApp', 'Wallpaper page loaded successfully.');
      await _liveWallpaperManager.initialize();
      await _liveWallpaperManager.wallpaperLoaded();
      await videoReady;
      await WallpaperEngine().markWallpaperReady();

      if (!mounted) return;
      setState(() {
        _isWebviewInitialized = true;
      });
    } catch (e, st) {
      logError('WallpaperApp', 'Failed to initialize WebView2', e, st);
      exit(1);
    }
  }

  Future<bool> _updateVideoHostMapping(String videoPath) async {
    final uri = Uri.tryParse(videoPath);
    final isRemote =
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.hasAuthority &&
        uri.host.isNotEmpty;
    if (videoPath.isEmpty) return true;
    if (isRemote) {
      logError(
        'WallpaperApp',
        'Remote video sources are not allowed in the wallpaper process; '
            'download the video to the local cache first.',
      );
      return false;
    }

    final videoFile = File(videoPath);
    if (!await videoFile.exists() || await videoFile.length() == 0) {
      logError(
        'WallpaperApp',
        'Local wallpaper video does not exist or is empty: $videoPath',
      );
      return false;
    }

    final parentPath = videoFile.parent.path;
    logInfo('WallpaperApp', 'Mapping video.local to: $parentPath');
    await _controller.addVirtualHostNameMapping(
      'video.local',
      parentPath,
      WebviewHostResourceAccessKind.allow,
    );
    return true;
  }

  /// Generates a local HTML file to play the video with proper styles and looping.
  Future<String> _generateHtmlFile(String videoPathOrUrl, String fit) async {
    final appDir = await _settingsService.getAppDirectory();
    final htmlFile = File('${appDir.path}\\wallpaper.html');

    var videoSrc = '';
    final uri = Uri.tryParse(videoPathOrUrl);
    final isRemote =
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.hasAuthority &&
        uri.host.isNotEmpty;
    if (isRemote) {
      throw const FormatException(
        'The wallpaper player requires a locally cached video file.',
      );
    } else if (videoPathOrUrl.isNotEmpty) {
      final videoFile = File(videoPathOrUrl);
      if (await videoFile.exists() && await videoFile.length() > 0) {
        videoSrc =
            'https://video.local/${Uri.encodeComponent(videoFile.uri.pathSegments.last)}';
      }
    }

    // Map wallpaperFit to CSS object-fit
    String objectFit = 'cover';
    if (fit == 'fit') {
      objectFit = 'contain';
    } else if (fit == 'stretch') {
      objectFit = 'fill';
    } else if (fit == 'center') {
      objectFit = 'none';
    }

    final escapedVideoSrc = videoSrc
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final videoType = switch (Uri.tryParse(videoSrc)?.path.toLowerCase()) {
      final path? when path.endsWith('.webm') => 'video/webm',
      final path? when path.endsWith('.ogv') || path.endsWith('.ogg') =>
        'video/ogg',
      final path? when path.endsWith('.mov') => 'video/quicktime',
      final path? when path.endsWith('.mp4') || path.endsWith('.m4v') =>
        'video/mp4',
      _ => '',
    };
    final sourceType = videoType.isEmpty ? '' : ' type="$videoType"';
    final htmlContent =
        '''
<!DOCTYPE html>
<html>
<head>
  <style>
    body, html {
      margin: 0;
      padding: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      background-color: black;
    }
    video {
      width: 100%;
      height: 100%;
      object-fit: $objectFit;
    }
  </style>
</head>
<body>
  ${videoSrc.isEmpty ? '' : '<video autoplay loop muted playsinline id="bg-video"><source src="$escapedVideoSrc"$sourceType></video>'}
  <script>
    const video = document.getElementById('bg-video');
    if (video && window.chrome?.webview) {
      video.addEventListener('loadeddata', () => {
        window.chrome.webview.postMessage({
          type: 'videoReady',
          width: video.videoWidth,
          height: video.videoHeight
        });
      }, { once: true });
      video.addEventListener('error', () => {
        window.chrome.webview.postMessage({
          type: 'videoError',
          code: video.error?.code ?? 0,
          message: video.error?.message ?? 'Unknown media error',
          source: video.currentSrc
        });
      });
    }
    let retries = 0;
    function startPlayback() {
      if (!video || retries >= 5) return;
      video.play().catch(err => {
        retries += 1;
        console.error("Wallpaper video playback failed", err);
        setTimeout(startPlayback, 1000 * retries);
      });
    }
    if (video) {
      video.addEventListener('error', () => {
        if (!video.error) {
          retries += 1;
          if (retries < 5) setTimeout(startPlayback, 1000 * retries);
        }
      });
    }
    startPlayback();
  </script>
</body>
</html>
''';

    await htmlFile.writeAsString(htmlContent, flush: true);
    logInfo(
      'WallpaperApp',
      'Generated HTML file with videoSrc: $videoSrc at: ${htmlFile.path}',
    );
    return htmlFile.path;
  }

  /// Watches the settings file and live-updates the video or fit, or exits if wallpaper is cleared.
  Future<void> _initSettingsWatcher() async {
    try {
      final file = await _settingsService.settingsFile;
      final parentDir = file.parent;
      logInfo(
        'WallpaperApp',
        'Starting settings directory watcher: ${parentDir.path}',
      );

      _settingsWatcher = parentDir.watch().listen(
        (event) {
          if (!event.path.endsWith('overlay_settings.json')) return;
          _watcherDebounce?.cancel();
          _watcherDebounce = Timer(
            const Duration(milliseconds: 150),
            _queueSettingsUpdate,
          );
        },
        onError: (Object error, StackTrace stackTrace) {
          logError(
            'WallpaperApp',
            'Settings file watcher failed',
            error,
            stackTrace,
          );
        },
      );
    } catch (e, st) {
      logError('WallpaperApp', 'Failed to watch wallpaper settings', e, st);
    }
  }

  void _queueSettingsUpdate() {
    _settingsUpdateQueue = _settingsUpdateQueue
        .then((_) async {
          if (!mounted) return;
          final updated = await _settingsService.loadSettings();
          if (!mounted) return;
          if (updated.activeWallpaperType != 'video') {
            logInfo(
              'WallpaperApp',
              'Wallpaper type changed to ${updated.activeWallpaperType}; closing wallpaper process.',
            );
            _settingsWatcher?.cancel();
            _playerMessageSubscription?.cancel();
            exit(0);
          }

          final pathChanged =
              updated.activeWallpaperPath != _settings.activeWallpaperPath;
          final fitChanged = updated.wallpaperFit != _settings.wallpaperFit;
          _settings = updated;
          if (pathChanged || fitChanged) {
            if (mounted) setState(() {});
            if (_isWebviewInitialized) {
              await _updateWallpaper(updated, reload: pathChanged);
            }
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          logError(
            'WallpaperApp',
            'Failed to apply changed wallpaper settings',
            error,
            stackTrace,
          );
        });
  }

  Future<void> _updateWallpaper(
    WidgetSettings settings, {
    required bool reload,
  }) async {
    final videoPath = settings.activeWallpaperPath ?? '';
    if (!await _updateVideoHostMapping(videoPath)) return;
    await _generateHtmlFile(videoPath, settings.wallpaperFit);
    if (reload) {
      await _controller.loadUrl('https://html.local/wallpaper.html');
      await _liveWallpaperManager.wallpaperLoaded();
      return;
    }

    final objectFit = switch (settings.wallpaperFit) {
      'fit' => 'contain',
      'stretch' => 'fill',
      'center' => 'none',
      _ => 'cover',
    };
    await _controller.executeScript(
      'document.getElementById("bg-video")?.style.setProperty("object-fit", "$objectFit");',
    );
  }

  @override
  void dispose() {
    _settingsWatcher?.cancel();
    _watcherDebounce?.cancel();
    _liveWallpaperManager.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WallSync Wallpaper',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: _isWebviewInitialized
            ? Webview(_controller)
            : const SizedBox.shrink(),
      ),
    );
  }
}
