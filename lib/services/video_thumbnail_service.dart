import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'mpv_runtime_resolver.dart';
import 'settings_service.dart';
import 'video_wallpaper_cache.dart';

/// High-performance video thumbnail generator and cache.
/// Extracts actual video frame snapshots directly from video files or streams using MPV,
/// guaranteeing that live wallpaper thumbnails are real frames of the video itself.
class VideoThumbnailService {
  static final VideoThumbnailService instance =
      VideoThumbnailService._internal();
  factory VideoThumbnailService() => instance;
  VideoThumbnailService._internal();

  final _settingsService = SettingsService();
  final Map<String, String> _memoryCache = {};
  final Set<String> _negativeCache = {};
  final Map<String, Future<File?>> _inFlight = {};
  final Map<String, Future<File?>> _cacheLookupsInFlight = {};

  /// Generates a deterministic cache key for a video path or URL.
  static String hashKey(String input) {
    final normalized = VideoWallpaperCache.normalizeVideoUrl(input.trim());
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  /// Locates the bundled mpv.exe binary via [MpvRuntimeResolver].
  static Future<String?> findMpvExecutable() async {
    return MpvRuntimeResolver.instance.findExecutablePath();
  }

  /// Returns the thumbnail directory: `<appDir>\video_thumbnails`.
  Future<Directory> getThumbnailDirectory() async {
    final appDir = await _settingsService.getAppDirectory();
    final dir = Directory('${appDir.path}\\video_thumbnails');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Checks for a valid cached thumbnail without blocking the calling isolate.
  Future<File?> getCachedThumbnailFile(String videoPathOrUrl) {
    final trimmed = videoPathOrUrl.trim();
    if (trimmed.isEmpty) return Future<File?>.value();

    final key = hashKey(trimmed);
    final pending = _cacheLookupsInFlight[key];
    if (pending != null) return pending;

    final lookup = _readCachedThumbnail(key);
    _cacheLookupsInFlight[key] = lookup;
    return lookup.whenComplete(() {
      if (identical(_cacheLookupsInFlight[key], lookup)) {
        _cacheLookupsInFlight.remove(key);
      }
    });
  }

  Future<File?> _readCachedThumbnail(String key) async {
    if (_negativeCache.contains(key)) return null;
    final appData =
        Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    final path =
        _memoryCache[key] ??
        '$appData\\com.example\\wallsync\\video_thumbnails\\$key.jpg';
    final targetFile = File(path);
    try {
      if (await targetFile.exists() && await targetFile.length() > 500) {
        _memoryCache[key] = targetFile.path;
        return targetFile;
      } else {
        _memoryCache.remove(key);
        _negativeCache.add(key);
      }
    } on FileSystemException {
      _memoryCache.remove(key);
      _negativeCache.add(key);
    }
    return null;
  }

  /// Resolves the actual source path for extraction.
  /// If the URL is already cached locally in `video_wallpapers`, uses the local file for instant extraction.
  Future<String> _resolveVideoSource(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return '';

    final localFile = File(trimmed);
    if (await localFile.exists()) {
      return localFile.path;
    }

    // Check if downloaded in video_wallpapers cache
    try {
      final appDir = await _settingsService.getAppDirectory();
      final cacheDir = Directory('${appDir.path}\\video_wallpapers');
      if (await cacheDir.exists()) {
        final rawKey = sha256.convert(utf8.encode(trimmed)).toString();
        final normKey = hashKey(trimmed);
        const supportedExtensions = ['mp4', 'm4v', 'webm', 'mov', 'ogv', 'ogg'];
        for (final key in {rawKey, normKey}) {
          for (final ext in supportedExtensions) {
            final candidate = File('${cacheDir.path}\\$key.$ext');
            if (await candidate.exists() && await candidate.length() > 0) {
              return candidate.path;
            }
          }
        }
      }
    } catch (_) {}

    return VideoWallpaperCache.normalizeVideoUrl(trimmed);
  }

  Future<String> resolveVideoSourceForMetadata(String input) =>
      _resolveVideoSource(input);

  /// Extracts or retrieves an authentic frame snapshot from the given video.
  Future<File?> getThumbnailFile(
    String videoPathOrUrl, {
    bool forceRegenerate = false,
  }) async {
    final trimmed = videoPathOrUrl.trim();
    if (trimmed.isEmpty) return null;

    final key = hashKey(trimmed);

    // 1. Check in-memory & on-disk cache
    if (!forceRegenerate) {
      final existing = await getCachedThumbnailFile(trimmed);
      if (existing != null) {
        return existing;
      }
    }

    // 2. Share in-flight extraction request to avoid duplicate work
    if (_inFlight.containsKey(key)) {
      return _inFlight[key]!;
    }

    final future = _extractThumbnailInternal(trimmed, key);
    _inFlight[key] = future;

    try {
      final result = await future;
      return result;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<File?> _extractThumbnailInternal(String input, String key) async {
    final mpvPath = await findMpvExecutable();
    if (mpvPath == null) {
      logError(
        'VideoThumbnailService',
        'mpv.exe not found for thumbnail extraction',
      );
      return null;
    }

    final thumbDir = await getThumbnailDirectory();
    final targetFile = File('${thumbDir.path}\\$key.jpg');

    if (await targetFile.exists() && await targetFile.length() > 500) {
      _memoryCache[key] = targetFile.path;
      _negativeCache.remove(key);
      return targetFile;
    }

    final tempOutDir = Directory('${thumbDir.path}\\temp_$key');
    if (await tempOutDir.exists()) {
      try {
        await tempOutDir.delete(recursive: true);
      } catch (_) {}
    }
    await tempOutDir.create(recursive: true);

    final resolvedSource = await _resolveVideoSource(input);
    if (resolvedSource.isEmpty) {
      return null;
    }

    final sw = Stopwatch()..start();
    try {
      // Step 1: Attempt extraction at 1.0 second (avoids black intro frame)
      await Process.run(mpvPath, [
        resolvedSource,
        '--no-audio',
        '--no-config',
        '--start=1',
        '--frames=1',
        '--vo=image',
        '--vo-image-format=jpg',
        '--vo-image-outdir=${tempOutDir.path}',
      ]).timeout(const Duration(seconds: 12));

      var generated = File('${tempOutDir.path}\\00000001.jpg');

      // Step 2: Fallback to second 0 if --start=1 did not produce a frame
      if (!await generated.exists() || await generated.length() == 0) {
        await Process.run(mpvPath, [
          resolvedSource,
          '--no-audio',
          '--no-config',
          '--start=0',
          '--frames=1',
          '--vo=image',
          '--vo-image-format=jpg',
          '--vo-image-outdir=${tempOutDir.path}',
        ]).timeout(const Duration(seconds: 12));
        generated = File('${tempOutDir.path}\\00000001.jpg');
      }

      final durationMs = sw.elapsedMilliseconds;
      if (await generated.exists() && await generated.length() > 500) {
        if (await targetFile.exists()) {
          await targetFile.delete();
        }
        await generated.rename(targetFile.path);
        _memoryCache[key] = targetFile.path;
        _negativeCache.remove(key);
        if (durationMs > 3000) {
          logWarning(
            'VideoThumbnailService',
            '[OVERWAIT WARNING] Thumbnail extraction took ${durationMs}ms for $input',
          );
        } else {
          logPerf(
            'VideoThumbnailService',
            'Extracted video thumbnail in ${durationMs}ms: ${targetFile.path}',
          );
        }
        return targetFile;
      }
    } catch (e, st) {
      logError(
        'VideoThumbnailService',
        'Error extracting video thumbnail for $input',
        e,
        st,
      );
    } finally {
      if (await tempOutDir.exists()) {
        try {
          await tempOutDir.delete(recursive: true);
        } catch (_) {}
      }
    }

    return null;
  }
}
