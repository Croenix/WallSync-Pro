import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'mpv_runtime_resolver.dart';
import 'settings_service.dart';
import 'video_wallpaper_cache.dart';

class _MpvThumbnailExtractPayload {
  final String mpvPath;
  final String resolvedSource;
  final String tempOutDirPath;
  final String targetFilePath;

  const _MpvThumbnailExtractPayload({
    required this.mpvPath,
    required this.resolvedSource,
    required this.tempOutDirPath,
    required this.targetFilePath,
  });
}

Future<bool> _runMpvThumbnailExtract(
  _MpvThumbnailExtractPayload payload,
) async {
  const timeout = Duration(seconds: 8);
  final stopwatch = Stopwatch()..start();

  for (final startSeconds in const [1, 0]) {
    final remaining = timeout - stopwatch.elapsed;
    if (remaining <= Duration.zero) return false;
    final generated = File(payload.targetFilePath);
    if (await generated.exists()) await generated.delete();
    final process = await Process.start(payload.mpvPath, [
      payload.resolvedSource,
      '--no-audio',
      '--no-config',
      '--start=$startSeconds',
      '--length=2',
      '--speed=8',
      '--vo=image',
      '--vo-image-format=jpg',
      '--vo-image-outdir=${payload.tempOutDirPath}',
      '--vf=scale=640:-2',
      '--vd-lavc-threads=1',
      '--demuxer-max-bytes=4MiB',
      '--demuxer-max-back-bytes=0',
      '--cache=no',
      '--priority=belownormal',
    ]);
    final stdout = StringBuffer();
    final stderr = StringBuffer();
    final stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .listen((chunk) => _appendDiagnostic(stdout, chunk));
    final stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .listen((chunk) => _appendDiagnostic(stderr, chunk));
    final exitFuture = process.exitCode;
    var exited = false;
    int? exitCode;
    var previousLength = -1;
    var stableLengthChecks = 0;
    var generatedFrameReady = false;
    try {
      while (stopwatch.elapsed < timeout) {
        if (await generated.exists()) {
          final length = await generated.length();
          if (length > 500) {
            stableLengthChecks = length == previousLength
                ? stableLengthChecks + 1
                : 0;
            previousLength = length;
            if (stableLengthChecks >= 1) {
              generatedFrameReady = true;
              break;
            }
          }
        }

        final remaining = timeout - stopwatch.elapsed;
        if (remaining <= Duration.zero) break;
        exitCode = await Future.any<int?>([
          exitFuture.then<int?>((code) => code),
          Future<void>.delayed(
            remaining < const Duration(milliseconds: 100)
                ? remaining
                : const Duration(milliseconds: 100),
          ).then<int?>((_) => null),
        ]);
        if (exitCode != null) {
          exited = true;
          break;
        }
      }

      if (generatedFrameReady && !exited) {
        process.kill();
        await exitFuture.timeout(
          const Duration(seconds: 1),
          onTimeout: () => -1,
        );
      } else if (!exited) {
        process.kill();
        exitCode = await exitFuture.timeout(
          const Duration(seconds: 1),
          onTimeout: () => -1,
        );
      }
    } finally {
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
    }

    if (generatedFrameReady && await generated.exists()) {
      return true;
    }
    logWarning(
      'VideoThumbnailService',
      'MPV did not produce a thumbnail at $startSeconds seconds '
          '(exit code ${exitCode ?? 'unknown'}): '
          '${_diagnosticText(stdout, stderr)}',
    );
    if (!exited) return false;
  }
  return false;
}

void _appendDiagnostic(StringBuffer buffer, String chunk) {
  const maxLength = 2048;
  final remaining = maxLength - buffer.length;
  if (remaining > 0) {
    buffer.write(
      chunk.length <= remaining ? chunk : chunk.substring(0, remaining),
    );
  }
}

String _diagnosticText(StringBuffer stdout, StringBuffer stderr) {
  final output = [
    stdout.toString().trim(),
    stderr.toString().trim(),
  ].where((text) => text.isNotEmpty).join('\n');
  return output.isEmpty ? 'No process output was captured.' : output;
}

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
  final Queue<Completer<void>> _extractionWaiters = Queue<Completer<void>>();
  int _activeExtractions = 0;
  static const _maxConcurrentExtractions = 2;

  /// Generates a deterministic cache key for a video path or URL.
  static String hashKey(String input) {
    final normalized = VideoWallpaperCache.normalizeVideoUrl(input.trim());
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  Future<String> _cacheKeyFor(String input) async {
    final normalized = VideoWallpaperCache.normalizeVideoUrl(input.trim());
    final file = File(input.trim());
    late final FileStat stat;
    try {
      stat = await file.stat();
    } on FileSystemException {
      return hashKey(input);
    }
    if (stat.type != FileSystemEntityType.file) return hashKey(input);
    return sha256
        .convert(
          utf8.encode(
            '$normalized|${stat.size}|${stat.modified.microsecondsSinceEpoch}',
          ),
        )
        .toString();
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
  Future<File?> getCachedThumbnailFile(String videoPathOrUrl) async {
    final trimmed = videoPathOrUrl.trim();
    if (trimmed.isEmpty) return null;

    final key = await _cacheKeyFor(trimmed);
    return _getCachedThumbnailFile(key);
  }

  Future<File?> _getCachedThumbnailFile(String key) {
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
    final directory = await getThumbnailDirectory();
    final path = _memoryCache[key] ?? '${directory.path}\\$key.jpg';
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

    final key = await _cacheKeyFor(trimmed);

    // 1. Check in-memory & on-disk cache
    if (!forceRegenerate) {
      final existing = await _getCachedThumbnailFile(key);
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
      await tempOutDir.delete(recursive: true);
    }
    await tempOutDir.create(recursive: true);
    final generatedFile = File('${tempOutDir.path}\\00000001.jpg');

    final sw = Stopwatch()..start();
    try {
      final resolvedSource = await _resolveVideoSource(input);
      if (resolvedSource.isEmpty) return null;

      final payload = _MpvThumbnailExtractPayload(
        mpvPath: mpvPath,
        resolvedSource: resolvedSource,
        tempOutDirPath: tempOutDir.path,
        targetFilePath: generatedFile.path,
      );

      final extracted = await _withExtractionSlot(
        () => _runMpvThumbnailExtract(payload),
      );

      final durationMs = sw.elapsedMilliseconds;
      if (extracted && await generatedFile.exists()) {
        if (await targetFile.exists()) await targetFile.delete();
        await generatedFile.rename(targetFile.path);
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
            'Extracted video thumbnail off-thread in ${durationMs}ms: ${targetFile.path}',
          );
        }
        return targetFile;
      }
      logWarning(
        'VideoThumbnailService',
        'Thumbnail extraction did not create an image for $input.',
      );
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
        } on FileSystemException catch (error, stackTrace) {
          logWarning(
            'VideoThumbnailService',
            'Could not clean thumbnail extraction directory '
                '${tempOutDir.path}: $error\n$stackTrace',
          );
        }
      }
    }

    return null;
  }

  Future<T> _withExtractionSlot<T>(Future<T> Function() action) async {
    if (_activeExtractions >= _maxConcurrentExtractions) {
      final waiter = Completer<void>();
      _extractionWaiters.addLast(waiter);
      await waiter.future;
    } else {
      _activeExtractions++;
    }
    try {
      return await action();
    } finally {
      if (_extractionWaiters.isNotEmpty) {
        _extractionWaiters.removeFirst().complete();
      } else {
        _activeExtractions--;
      }
    }
  }
}
