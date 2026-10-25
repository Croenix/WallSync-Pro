import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

import '../services/firebase_service.dart';
import '../services/settings_service.dart';
import '../services/video_wallpaper_cache.dart';
import '../services/video_thumbnail_service.dart';
import '../services/wallpaper_metadata_service.dart';

/// Hardware-accelerated live video preview widget using WebView2.
class LiveVideoPreview extends StatefulWidget {
  final String videoPathOrUrl;
  final String? thumbnailUrl;
  final bool autoPlay;
  final bool loop;
  final bool muted;
  final String fit; // 'fill', 'fit', 'stretch', 'center'
  final BorderRadius? borderRadius;
  final VoidCallback? onReady;

  const LiveVideoPreview({
    super.key,
    required this.videoPathOrUrl,
    this.thumbnailUrl,
    this.autoPlay = true,
    this.loop = true,
    this.muted = true,
    this.fit = 'fill',
    this.borderRadius,
    this.onReady,
  });

  @override
  State<LiveVideoPreview> createState() => LiveVideoPreviewState();
}

class LiveVideoPreviewState extends State<LiveVideoPreview> {
  WebviewController? _controller;
  StreamSubscription? _messageSub;
  bool _isControllerDisposed = false;
  bool _isInitialized = false;
  bool _isPlaying = false;
  bool _hasError = false;
  bool _isDisposed = false;
  late bool _muted;

  static bool _environmentInitialized = false;
  static final _settingsService = SettingsService();

  void _safeDisposeController() {
    if (_isControllerDisposed) return;
    _isControllerDisposed = true;
    _messageSub?.cancel();
    _messageSub = null;
    final c = _controller;
    _controller = null;
    if (c != null) {
      try {
        c.dispose();
      } catch (_) {}
    }
  }

  @override
  void initState() {
    super.initState();
    _muted = widget.muted;
    _initPlayer();
  }

  @override
  void didUpdateWidget(LiveVideoPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPathOrUrl != widget.videoPathOrUrl) {
      _reloadVideo();
    }
  }

  Future<void> _reloadVideo() async {
    final controller = _controller;
    if (controller != null && _isInitialized && !_isDisposed) {
      final resolved = await _resolveVideoSource(widget.videoPathOrUrl);
      if (_isDisposed || _controller == null) return;
      final videoSrc = await _formatVideoSrc(controller, resolved);
      if (_isDisposed || _controller == null) return;
      if (videoSrc.isNotEmpty) {
        try {
          await controller.executeScript('''
            const v = document.getElementById('v');
            if (v) {
              v.src = '$videoSrc';
              v.load();
              v.play();
            }
          ''');
        } catch (_) {}
      }
    }
  }

  Future<String> _resolveVideoSource(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return '';

    // If local file exists, use it directly
    final localFile = File(trimmed);
    if (await localFile.exists()) {
      return localFile.path;
    }

    // If it's a remote URL, check if already cached in video_wallpapers cache dir
    final normalized = VideoWallpaperCache.normalizeVideoUrl(trimmed);
    try {
      final appDir = await _settingsService.getAppDirectory();
      final cacheDir = Directory('${appDir.path}\\video_wallpapers');
      if (await cacheDir.exists()) {
        final rawKey = sha256.convert(utf8.encode(trimmed)).toString();
        final normKey = sha256.convert(utf8.encode(normalized)).toString();
        final entries = await cacheDir.list(followLinks: false).toList();
        for (final key in {rawKey, normKey}) {
          final prefix = '$key.';
          for (final entity in entries) {
            if (entity is File &&
                entity.uri.pathSegments.last.startsWith(prefix) &&
                await entity.length() > 0) {
              return entity.path;
            }
          }
        }
      }
    } catch (_) {}

    return normalized;
  }

  Future<String> _formatVideoSrc(
    WebviewController controller,
    String resolved,
  ) async {
    if (resolved.isEmpty) return '';
    final uri = Uri.tryParse(resolved);
    final isRemote =
        uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.hasAuthority;

    if (isRemote) {
      return resolved;
    }

    final file = File(resolved);
    if (await file.exists()) {
      final parentDir = file.parent.path;
      final hostKey =
          'vhost-${parentDir.hashCode.abs().toRadixString(16)}.local';
      try {
        await controller.addVirtualHostNameMapping(
          hostKey,
          parentDir,
          WebviewHostResourceAccessKind.allow,
        );
        return 'https://$hostKey/${Uri.encodeComponent(file.uri.pathSegments.last)}';
      } catch (_) {
        return resolved;
      }
    }
    return '';
  }

  Future<void> _initPlayer() async {
    if (!Platform.isWindows) return;

    try {
      if (!_environmentInitialized) {
        final localAppData =
            Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
        final previewProfileDir = Directory(
          '$localAppData\\WallSync\\PreviewWebView2',
        );
        if (!await previewProfileDir.exists()) {
          await previewProfileDir.create(recursive: true);
        }
        try {
          await WebviewController.initializeEnvironment(
            userDataPath: previewProfileDir.path,
            additionalArguments:
                '--autoplay-policy=no-user-gesture-required '
                '--disable-features=HardwareMediaKeyHandling '
                '--disable-background-timer-throttling '
                '--enable-features=HardwareAccelerationMode',
          );
        } catch (_) {}
        _environmentInitialized = true;
      }

      if (_isDisposed) return;

      final controller = WebviewController();
      _controller = controller;

      await controller.initialize();
      if (_isDisposed) {
        _safeDisposeController();
        return;
      }

      await controller.setBackgroundColor(Colors.black);
      if (_isDisposed) {
        _safeDisposeController();
        return;
      }

      final resolved = await _resolveVideoSource(widget.videoPathOrUrl);
      if (_isDisposed) {
        _safeDisposeController();
        return;
      }

      final videoSrc = await _formatVideoSrc(controller, resolved);
      if (_isDisposed) {
        _safeDisposeController();
        return;
      }
      if (videoSrc.isEmpty) {
        if (mounted) setState(() => _hasError = true);
        return;
      }

      final objectFit = switch (widget.fit.toLowerCase()) {
        'fit' => 'contain',
        'stretch' => 'fill',
        'center' => 'none',
        _ => 'cover',
      };

      final escapedSrc = videoSrc.replaceAll('"', '&quot;');

      final html =
          '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body, html {
    width: 100%;
    height: 100%;
    overflow: hidden;
    background: #000;
  }
  video {
    width: 100%;
    height: 100%;
    object-fit: $objectFit;
    display: block;
    background: #000;
  }
</style>
</head>
<body>
  <video id="v" ${widget.autoPlay ? 'autoplay' : ''} ${widget.loop ? 'loop' : ''} ${_muted ? 'muted' : ''} playsinline src="$escapedSrc"></video>
  <script>
    const v = document.getElementById('v');
    v.addEventListener('playing', () => {
      try { window.chrome.webview.postMessage('playing'); } catch(e){}
    });
    v.addEventListener('error', (e) => {
      try { window.chrome.webview.postMessage('error'); } catch(e){}
    });
  </script>
</body>
</html>
''';

      _messageSub = controller.webMessage.listen((dynamic msg) {
        if (_isDisposed || !mounted) return;
        if (msg == 'playing') {
          setState(() => _isPlaying = true);
          widget.onReady?.call();
        } else if (msg == 'error') {
          setState(() => _hasError = true);
        }
      });

      final dataUri = Uri.dataFromString(
        html,
        mimeType: 'text/html',
        encoding: utf8,
      ).toString();

      await controller.loadUrl(dataUri);
      if (_isDisposed) {
        _safeDisposeController();
        return;
      }

      if (!_isDisposed && mounted) {
        setState(() {
          _isInitialized = true;
        });
      }
    } catch (_) {
      if (!_isDisposed && mounted) {
        setState(() => _hasError = true);
      }
    }
  }

  Future<void> toggleMute() async {
    final next = !_muted;
    _muted = next;
    final controller = _controller;
    if (controller != null && _isInitialized && !_isDisposed) {
      try {
        await controller.executeScript('''
          const v = document.getElementById('v');
          if (v) { v.muted = $next; }
        ''');
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  Future<void> togglePlayPause() async {
    final next = !_isPlaying;
    _isPlaying = next;
    final controller = _controller;
    if (controller != null && _isInitialized && !_isDisposed) {
      try {
        if (next) {
          await controller.executeScript('''
            const v = document.getElementById('v');
            if (v) { v.play(); }
          ''');
        } else {
          await controller.executeScript('''
            const v = document.getElementById('v');
            if (v) { v.pause(); }
          ''');
        }
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _isDisposed = true;
    _safeDisposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget content;

    Widget placeholder;
    if (widget.thumbnailUrl != null && widget.thumbnailUrl!.isNotEmpty) {
      final thumb = widget.thumbnailUrl!;
      Widget img;
      if (thumb.startsWith('asset://')) {
        img = Image.asset(
          thumb.replaceFirst('asset://', ''),
          fit: BoxFit.cover,
          cacheWidth: 320,
          cacheHeight: 240,
          errorBuilder: (_, _, _) => Container(color: const Color(0xFF0B1220)),
        );
      } else if (thumb.startsWith('http://') || thumb.startsWith('https://')) {
        final cached = FirebaseService.instance.getCachedThumbnailSync(thumb);
        if (cached != null) {
          img = Image.file(
            cached,
            fit: BoxFit.cover,
            cacheWidth: 320,
            cacheHeight: 240,
            errorBuilder: (_, _, _) =>
                Container(color: const Color(0xFF0B1220)),
          );
        } else {
          FirebaseService.instance.downloadThumbnailToCache(thumb);
          img = Image.network(
            thumb,
            fit: BoxFit.cover,
            cacheWidth: 320,
            cacheHeight: 240,
            errorBuilder: (_, _, _) =>
                Container(color: const Color(0xFF0B1220)),
          );
        }
      } else if (thumb.isNotEmpty) {
        img = Image.file(
          File(thumb),
          fit: BoxFit.cover,
          cacheWidth: 320,
          cacheHeight: 240,
          errorBuilder: (_, _, _) => Container(color: const Color(0xFF0B1220)),
        );
      } else {
        img = Container(color: const Color(0xFF0B1220));
      }

      placeholder = Stack(
        fit: StackFit.expand,
        children: [
          img,
          Container(color: Colors.black.withValues(alpha: 0.35)),
          const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
              ),
            ),
          ),
        ],
      );
    } else {
      placeholder = Container(
        color: const Color(0xFF0B1220),
        child: const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
            ),
          ),
        ),
      );
    }

    if (_hasError) {
      content = Container(
        color: const Color(0xFF0F172A),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.videocam_off_rounded, size: 28, color: Colors.white24),
              SizedBox(height: 6),
              Text(
                'Preview unavailable',
                style: TextStyle(fontSize: 10, color: Colors.white38),
              ),
            ],
          ),
        ),
      );
    } else if (!_isInitialized || _controller == null) {
      content = placeholder;
    } else {
      content = Stack(
        fit: StackFit.expand,
        children: [Webview(_controller!), if (!_isPlaying) placeholder],
      );
    }

    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: content);
    }
    return content;
  }
}

/// A sleek, high-definition thumbnail widget for video wallpapers.
/// Displays the actual thumbnail visual with an elegant glassmorphism
/// play badge, gradient vignette, and "Hover to Preview" prompt.
/// A sleek, high-definition thumbnail widget for video wallpapers.
/// Displays the actual video frame visual extracted directly from the video itself.
class VideoThumbnailWidget extends StatefulWidget {
  final FirebaseWallpaper wallpaper;
  final BoxFit fit;
  final bool showBadge;
  final BorderRadius? borderRadius;

  const VideoThumbnailWidget({
    super.key,
    required this.wallpaper,
    this.fit = BoxFit.cover,
    this.showBadge = true,
    this.borderRadius,
  });

  @override
  State<VideoThumbnailWidget> createState() => _VideoThumbnailWidgetState();
}

class _VideoThumbnailWidgetState extends State<VideoThumbnailWidget> {
  File? _extractedFrameFile;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(VideoThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.wallpaper.url != widget.wallpaper.url ||
        oldWidget.wallpaper.thumbnailUrl != widget.wallpaper.thumbnailUrl) {
      _loadThumbnail();
    }
  }

  void _loadThumbnail() {
    final generation = ++_loadGeneration;
    unawaited(_loadThumbnailAsync(generation));
  }

  Future<void> _loadThumbnailAsync(int generation) async {
    final wp = widget.wallpaper;
    final posterUrl = wp.thumbnailUrl;
    if (posterUrl != null && posterUrl.startsWith('http')) {
      final poster = FirebaseService.instance.getCachedThumbnailSync(posterUrl);
      if (poster != null) {
        _extractedFrameFile = poster;
      } else {
        unawaited(
          FirebaseService.instance
              .downloadThumbnailToCache(posterUrl)
              .then((file) {
                if (mounted && generation == _loadGeneration && file != null) {
                  setState(() => _extractedFrameFile = file);
                }
              })
              .catchError((Object error, StackTrace stackTrace) {
                logError(
                  'VideoThumbnailWidget',
                  'Failed to load poster: $posterUrl',
                  error,
                  stackTrace,
                );
                return null;
              }),
        );
      }
      return;
    }

    // Check if thumbnail frame already exists on disk
    final cached = await VideoThumbnailService.instance.getCachedThumbnailFile(
      wp.url,
    );
    if (!mounted || generation != _loadGeneration) return;
    if (cached != null) {
      setState(() => _extractedFrameFile = cached);
      return;
    }

    final localVideo = File(wp.url);
    if (!localVideo.isAbsolute || !await localVideo.exists()) return;
    try {
      final file = await VideoThumbnailService.instance.getThumbnailFile(
        wp.url,
      );
      if (mounted && generation == _loadGeneration && file != null) {
        setState(() => _extractedFrameFile = file);
      }
    } catch (error, stackTrace) {
      logError(
        'VideoThumbnailWidget',
        'Video frame extraction failed: ${wp.url}',
        error,
        stackTrace,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final fallbackAsset = FirebaseWallpaper.resolveFallbackLocalAsset(
      id: widget.wallpaper.id,
      name: widget.wallpaper.name,
      category: widget.wallpaper.category,
    );

    Widget imageWidget;
    if (_extractedFrameFile != null) {
      imageWidget = Image.file(
        _extractedFrameFile!,
        fit: widget.fit,
        cacheWidth: 320,
        cacheHeight: 240,
        errorBuilder: (context, error, stackTrace) => Image.asset(
          fallbackAsset.replaceFirst('asset://', ''),
          fit: widget.fit,
          cacheWidth: 320,
          cacheHeight: 240,
        ),
      );
    } else if (widget.wallpaper.thumbnailUrl != null &&
        widget.wallpaper.thumbnailUrl!.isNotEmpty &&
        !widget.wallpaper.thumbnailUrl!.contains('unsplash.com')) {
      final thumb = widget.wallpaper.thumbnailUrl!;
      if (thumb.startsWith('asset://')) {
        imageWidget = Image.asset(
          thumb.replaceFirst('asset://', ''),
          fit: widget.fit,
          cacheWidth: 320,
          cacheHeight: 240,
          errorBuilder: (context, error, stackTrace) => Image.asset(
            fallbackAsset.replaceFirst('asset://', ''),
            fit: widget.fit,
            cacheWidth: 320,
            cacheHeight: 240,
          ),
        );
      } else if (thumb.startsWith('http://') || thumb.startsWith('https://')) {
        final cached = FirebaseService.instance.getCachedThumbnailSync(thumb);
        if (cached != null) {
          imageWidget = Image.file(
            cached,
            fit: widget.fit,
            cacheWidth: 320,
            cacheHeight: 240,
            errorBuilder: (context, error, stackTrace) => Image.asset(
              fallbackAsset.replaceFirst('asset://', ''),
              fit: widget.fit,
              cacheWidth: 320,
              cacheHeight: 240,
            ),
          );
        } else {
          final optThumb = FirebaseWallpaper.toOptimizedThumbnailUrl(thumb);
          FirebaseService.instance.downloadThumbnailToCache(optThumb);
          imageWidget = Image.network(
            optThumb,
            fit: widget.fit,
            cacheWidth: 320,
            cacheHeight: 240,
            errorBuilder: (context, error, stackTrace) => Image.asset(
              fallbackAsset.replaceFirst('asset://', ''),
              fit: widget.fit,
              cacheWidth: 320,
              cacheHeight: 240,
            ),
          );
        }
      } else if (thumb.isNotEmpty) {
        imageWidget = Image.file(
          File(thumb),
          fit: widget.fit,
          cacheWidth: 320,
          cacheHeight: 240,
          errorBuilder: (context, error, stackTrace) => Image.asset(
            fallbackAsset.replaceFirst('asset://', ''),
            fit: widget.fit,
            cacheWidth: 320,
            cacheHeight: 240,
          ),
        );
      } else {
        imageWidget = Image.asset(
          fallbackAsset.replaceFirst('asset://', ''),
          fit: widget.fit,
          cacheWidth: 320,
          cacheHeight: 240,
        );
      }
    } else {
      imageWidget = Image.asset(
        fallbackAsset.replaceFirst('asset://', ''),
        fit: widget.fit,
        cacheWidth: 320,
        cacheHeight: 240,
      );
    }

    Widget content = Stack(
      fit: StackFit.expand,
      children: [
        // 1. Crisp visual thumbnail image
        imageWidget,

        // 2. Elegant dark cinematic gradient
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.15),
                Colors.black.withValues(alpha: 0.55),
              ],
            ),
          ),
        ),

        // 3. Centered frosted-glass play icon badge
        if (widget.showBadge)
          Center(
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withValues(alpha: 0.65),
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.6),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
                    blurRadius: 16,
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: const Icon(
                Icons.play_arrow_rounded,
                size: 28,
                color: Color(0xFF38BDF8),
              ),
            ),
          ),

        // 4. Subtle bottom indicator "Live Video"
        if (widget.showBadge)
          Positioned(
            bottom: 38,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.15),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.movie_creation_outlined,
                      size: 10,
                      color: Color(0xFF38BDF8),
                    ),
                    SizedBox(width: 4),
                    Text(
                      'Live Video',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: Colors.white70,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );

    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: content);
    }
    return content;
  }
}

/// A dedicated, ultra-efficient widget displaying the actual video frame of the currently active live wallpaper.
/// Guarantees that the thumbnail is the exact photo snapshot from the active video without spawning WebView2.
class CurrentVideoWallpaperThumbnailWidget extends StatefulWidget {
  final String videoPathOrUrl;
  final String fit; // 'fill', 'fit', 'stretch', 'center'
  final BorderRadius? borderRadius;

  const CurrentVideoWallpaperThumbnailWidget({
    super.key,
    required this.videoPathOrUrl,
    this.fit = 'fill',
    this.borderRadius,
  });

  @override
  State<CurrentVideoWallpaperThumbnailWidget> createState() =>
      _CurrentVideoWallpaperThumbnailWidgetState();
}

class _CurrentVideoWallpaperThumbnailWidgetState
    extends State<CurrentVideoWallpaperThumbnailWidget> {
  File? _thumbnailFile;
  bool _isLoading = true;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(CurrentVideoWallpaperThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPathOrUrl != widget.videoPathOrUrl) {
      _loadThumbnail();
    }
  }

  void _loadThumbnail() {
    final generation = ++_loadGeneration;
    unawaited(_loadThumbnailAsync(generation));
  }

  Future<void> _loadThumbnailAsync(int generation) async {
    final path = widget.videoPathOrUrl.trim();
    if (path.isEmpty) {
      if (mounted) {
        setState(() {
          _thumbnailFile = null;
          _isLoading = false;
        });
      }
      return;
    }

    final cached = await VideoThumbnailService.instance.getCachedThumbnailFile(
      path,
    );
    if (!mounted || generation != _loadGeneration) return;
    if (cached != null) {
      setState(() {
        _thumbnailFile = cached;
        _isLoading = false;
      });
      return;
    }

    setState(() => _isLoading = true);
    try {
      final file = await VideoThumbnailService.instance.getThumbnailFile(path);
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _thumbnailFile = file;
          _isLoading = false;
        });
      }
    } catch (error, stackTrace) {
      logError(
        'CurrentVideoWallpaperThumbnailWidget',
        'Video thumbnail lookup failed for $path.',
        error,
        stackTrace,
      );
      if (mounted && generation == _loadGeneration) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final boxFit = switch (widget.fit.toLowerCase()) {
      'fit' => BoxFit.contain,
      'stretch' => BoxFit.fill,
      'center' => BoxFit.none,
      _ => BoxFit.cover,
    };

    Widget content;
    if (_thumbnailFile != null) {
      content = Image.file(
        _thumbnailFile!,
        fit: boxFit,
        cacheWidth: 800,
        errorBuilder: (context, error, stackTrace) =>
            Container(color: const Color(0xFF0B1220)),
      );
    } else {
      content = Container(
        color: const Color(0xFF0B1220),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _isLoading
                    ? 'Extracting video preview...'
                    : 'Generating snapshot...',
                style: const TextStyle(fontSize: 10, color: Colors.white54),
              ),
            ],
          ),
        ),
      );
    }

    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: content);
    }
    return content;
  }
}

/// Interactive Full Video Preview Modal dialog with live playback and Set Wallpaper button.
Future<void> showLiveVideoPreviewDialog({
  required BuildContext context,
  required FirebaseWallpaper wallpaper,
  required bool isActive,
  required Future<void> Function(String pathOrUrl) onApplyWallpaper,
  Future<void> Function(FirebaseWallpaper wallpaper)? onReportWallpaper,
}) async {
  await showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Live Video Preview',
    barrierColor: Colors.black.withValues(alpha: 0.75),
    transitionDuration: const Duration(milliseconds: 250),
    transitionBuilder: (context, anim1, anim2, child) {
      return FadeTransition(
        opacity: anim1,
        child: ScaleTransition(
          scale: CurvedAnimation(parent: anim1, curve: Curves.easeOutCubic),
          child: child,
        ),
      );
    },
    pageBuilder: (context, anim1, anim2) {
      return _LiveVideoPreviewDialog(
        wallpaper: wallpaper,
        isActive: isActive,
        onApplyWallpaper: onApplyWallpaper,
        onReportWallpaper: onReportWallpaper,
      );
    },
  );
}

class _LiveVideoPreviewDialog extends StatefulWidget {
  final FirebaseWallpaper wallpaper;
  final bool isActive;
  final Future<void> Function(String pathOrUrl) onApplyWallpaper;
  final Future<void> Function(FirebaseWallpaper wallpaper)? onReportWallpaper;

  const _LiveVideoPreviewDialog({
    required this.wallpaper,
    required this.isActive,
    required this.onApplyWallpaper,
    this.onReportWallpaper,
  });

  @override
  State<_LiveVideoPreviewDialog> createState() =>
      _LiveVideoPreviewDialogState();
}

class _LiveVideoPreviewDialogState extends State<_LiveVideoPreviewDialog> {
  final GlobalKey<LiveVideoPreviewState> _playerKey =
      GlobalKey<LiveVideoPreviewState>();
  bool _isApplying = false;
  bool _isMuted = true;
  bool _isPlaying = true;

  @override
  Widget build(BuildContext context) {
    final wp = widget.wallpaper;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 780,
          constraints: const BoxConstraints(maxHeight: 680),
          margin: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF131722),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                blurRadius: 32,
                spreadRadius: 2,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.8),
                blurRadius: 24,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Top Header Bar ──
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.3),
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.videocam_rounded,
                            size: 13,
                            color: Color(0xFF38BDF8),
                          ),
                          SizedBox(width: 4),
                          Text(
                            'LIVE VIDEO PREVIEW',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF38BDF8),
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        wp.name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    FutureBuilder<WallpaperMetadata>(
                      future: WallpaperMetadataService.instance.getMetadata(
                        url: wp.url,
                        isVideo: true,
                      ),
                      builder: (context, snapshot) => ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: Text(
                          snapshot.data?.displayLabel ?? 'Checking resolution…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Colors.white60,
                        size: 20,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      splashRadius: 18,
                    ),
                    if (widget.onReportWallpaper != null)
                      PopupMenuButton<String>(
                        tooltip: 'Wallpaper actions',
                        onSelected: (value) {
                          if (value == 'report') {
                            widget.onReportWallpaper!(wp);
                          }
                        },
                        color: const Color(0xFF202434),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'report',
                            child: Text('Report wallpaper'),
                          ),
                        ],
                        icon: const Icon(
                          Icons.more_vert_rounded,
                          color: Colors.white60,
                        ),
                      ),
                  ],
                ),
              ),

              const Divider(height: 1, color: Colors.white12),

              // ── Video Preview Player ──
              Expanded(
                child: Container(
                  color: Colors.black,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      LiveVideoPreview(
                        key: _playerKey,
                        videoPathOrUrl: wp.url,
                        thumbnailUrl: wp.thumbnailUrl,
                        autoPlay: true,
                        loop: true,
                        muted: _isMuted,
                        fit: 'cover',
                      ),

                      // Floating player controls overlay (bottom right)
                      Positioned(
                        right: 14,
                        bottom: 14,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.15),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  _isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                tooltip: _isPlaying
                                    ? 'Pause preview'
                                    : 'Play preview',
                                onPressed: () {
                                  _playerKey.currentState?.togglePlayPause();
                                  setState(() => _isPlaying = !_isPlaying);
                                },
                              ),
                              IconButton(
                                icon: Icon(
                                  _isMuted
                                      ? Icons.volume_off_rounded
                                      : Icons.volume_up_rounded,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                tooltip: _isMuted
                                    ? 'Unmute preview'
                                    : 'Mute preview',
                                onPressed: () {
                                  _playerKey.currentState?.toggleMute();
                                  setState(() => _isMuted = !_isMuted);
                                },
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Live indicator pill (top left)
                      Positioned(
                        left: 14,
                        top: 14,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: const Color(
                                0xFF22C55E,
                              ).withValues(alpha: 0.5),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircleAvatar(
                                radius: 3.5,
                                backgroundColor: Color(0xFF22C55E),
                              ),
                              SizedBox(width: 5),
                              Text(
                                'HARDWARE ACCELERATED',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF22C55E),
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const Divider(height: 1, color: Colors.white12),

              // ── Bottom Action & Info Deck ──
              Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    // Wallpaper info column
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              if (wp.isPro) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: const LinearGradient(
                                      colors: [
                                        Color(0xFFFFB703),
                                        Color(0xFFFB8500),
                                      ],
                                    ),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: const Text(
                                    '👑 PRO',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF0F111A),
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Text(
                                  wp.category.toUpperCase(),
                                  style: const TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white70,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFF38BDF8,
                                  ).withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: const Text(
                                  '720p / 1080p MP4',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF38BDF8),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (wp.description != null &&
                              wp.description!.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              wp.description!,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white60,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),

                    const SizedBox(width: 16),

                    // Apply / Set Wallpaper Button
                    ElevatedButton.icon(
                      onPressed: (wp.isPro || _isApplying)
                          ? null
                          : () async {
                              setState(() => _isApplying = true);
                              try {
                                await widget.onApplyWallpaper(wp.url);
                                if (context.mounted) {
                                  Navigator.of(context).pop();
                                }
                              } finally {
                                if (mounted) {
                                  setState(() => _isApplying = false);
                                }
                              }
                            },
                      icon: _isApplying
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : Icon(
                              wp.isPro
                                  ? Icons.lock_rounded
                                  : widget.isActive
                                  ? Icons.check_circle_rounded
                                  : Icons.wallpaper_rounded,
                              size: 18,
                            ),
                      label: Text(
                        _isApplying
                            ? 'Applying...'
                            : wp.isPro
                            ? 'WallSync Pro Only'
                            : (widget.isActive
                                  ? 'Active Wallpaper'
                                  : 'Set as Desktop Wallpaper'),
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: wp.isPro
                            ? const Color(0xFFFFB703).withValues(alpha: 0.2)
                            : widget.isActive
                            ? const Color(0xFF22C55E)
                            : const Color(0xFF38BDF8),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 22,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        elevation: 4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
