import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'settings_service.dart';

class VideoWallpaperCache {
  VideoWallpaperCache({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;
  final _settingsService = SettingsService();
  final Map<String, Future<File>> _downloads = {};

  /// Normalizes dynamic video URLs (e.g. converting preview page URLs to direct stream/download URLs).
  static String normalizeVideoUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return trimmed;

    // Mixkit preview page URLs: convert to direct 720p mp4 stream
    // e.g. https://assets.mixkit.co/videos/preview/mixkit-...-1240-large.mp4 -> https://assets.mixkit.co/videos/1240/1240-720.mp4
    final mixkitMatch = RegExp(
      r'assets\.mixkit\.co\/videos\/preview\/(?:mixkit-)?.*?(\d+)-(?:large|medium|small)\.mp4',
      caseSensitive: false,
    ).firstMatch(trimmed);

    if (mixkitMatch != null) {
      final videoId = mixkitMatch.group(1);
      return 'https://assets.mixkit.co/videos/$videoId/$videoId-720.mp4';
    }

    return trimmed;
  }

  /// Generates ordered candidate URLs to try for a given video URL from the database.
  static List<String> getCandidateUrls(String rawUrl) {
    final trimmed = rawUrl.trim();
    final normalized = normalizeVideoUrl(trimmed);
    final candidates = <String>[];

    // Priority 1: Normalized direct stream URL
    candidates.add(normalized);

    // If it's a Mixkit URL with an ID, add alternative resolutions as fallbacks:
    final mixkitIdMatch = RegExp(
      r'assets\.mixkit\.co\/videos\/(?:preview\/.*?-)?(\d+)',
      caseSensitive: false,
    ).firstMatch(trimmed);

    if (mixkitIdMatch != null) {
      final videoId = mixkitIdMatch.group(1);
      final alt720 =
          'https://assets.mixkit.co/videos/$videoId/$videoId-720.mp4';
      final alt1080 =
          'https://assets.mixkit.co/videos/$videoId/$videoId-1080.mp4';
      if (!candidates.contains(alt720)) candidates.add(alt720);
      if (!candidates.contains(alt1080)) candidates.add(alt1080);
    }

    // Last fallback: the raw URL if different from candidates
    if (!candidates.contains(trimmed)) {
      candidates.add(trimmed);
    }

    return candidates;
  }

  Future<File> download(
    String url, {
    void Function(double progress)? onProgress,
  }) {
    final normalized = normalizeVideoUrl(url);
    final key = '$url|$normalized';
    final existing =
        _downloads[key] ?? _downloads[url] ?? _downloads[normalized];
    if (existing != null) return existing;

    final downloadFuture = _download(url, onProgress);
    _downloads[key] = downloadFuture;
    _downloads[url] = downloadFuture;
    _downloads[normalized] = downloadFuture;

    return downloadFuture.whenComplete(() {
      if (identical(_downloads[key], downloadFuture)) {
        _downloads.remove(key);
      }
      if (identical(_downloads[url], downloadFuture)) {
        _downloads.remove(url);
      }
      if (identical(_downloads[normalized], downloadFuture)) {
        _downloads.remove(normalized);
      }
    });
  }

  Future<File> _download(
    String url,
    void Function(double progress)? onProgress,
  ) async {
    final candidates = getCandidateUrls(url);
    if (candidates.isEmpty) {
      throw const FormatException('Enter a valid HTTP or HTTPS video URL.');
    }

    final appDir = await _settingsService.getAppDirectory();
    final cacheDir = Directory('${appDir.path}\\video_wallpapers');
    await cacheDir.create(recursive: true);

    final rawUrlKey = sha256.convert(utf8.encode(url.trim())).toString();
    final normalizedUrlKey = sha256
        .convert(utf8.encode(normalizeVideoUrl(url)))
        .toString();

    // Check if video is already downloaded under either raw or normalized key.
    // Pre-list the directory once (async) and then search both keys without re-listing.
    List<FileSystemEntity> entities;
    try {
      entities = await cacheDir.list(followLinks: false).toList();
    } catch (_) {
      entities = const [];
    }
    for (final key in {rawUrlKey, normalizedUrlKey}) {
      final cachePrefix = '$key.';
      for (final entity in entities) {
        if (entity is File &&
            entity.uri.pathSegments.last.startsWith(cachePrefix) &&
            _supportedExtensions.contains(_extension(entity.path)) &&
            await entity.length() > 0) {
          onProgress?.call(1);
          return entity;
        }
      }
    }

    final tempFile = File('${cacheDir.path}\\$rawUrlKey.part');
    if (await tempFile.exists()) await tempFile.delete();

    DioException? lastDioException;
    Object? lastError;

    for (final candidateUrl in candidates) {
      final candidateUri = Uri.tryParse(candidateUrl);
      if (candidateUri == null ||
          !candidateUri.hasAuthority ||
          candidateUri.host.isEmpty ||
          (candidateUri.scheme != 'http' && candidateUri.scheme != 'https')) {
        continue;
      }

      try {
        if (await tempFile.exists()) await tempFile.delete();

        final sw = Stopwatch()..start();
        final response = await _dio.download(
          candidateUri.toString(),
          tempFile.path,
          deleteOnError: true,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              onProgress?.call((received / total).clamp(0, 1).toDouble());
            }
          },
          options: Options(
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
              'Accept': '*/*',
              'Accept-Language': 'en-US,en;q=0.9',
              if (candidateUri.hasAuthority)
                'Referer':
                    '${candidateUri.scheme}://${candidateUri.authority}/',
            },
            followRedirects: true,
            receiveTimeout: const Duration(minutes: 10),
            validateStatus: (status) =>
                status != null && status >= 200 && status < 300,
          ),
        );

        final contentType = response.headers
            .value(Headers.contentTypeHeader)
            ?.split(';')
            .first
            .trim();
        final extension = _extensionFor(contentType, candidateUri.path);
        if (extension == null) {
          throw FormatException(
            'The URL did not return a supported video format '
            '(MP4, WebM, MOV, or Ogg).',
          );
        }
        if (!await tempFile.exists() || await tempFile.length() == 0) {
          throw const FormatException('The downloaded video file is empty.');
        }

        final targetFile = File('${cacheDir.path}\\$rawUrlKey.$extension');
        if (await targetFile.exists()) await targetFile.delete();
        await tempFile.rename(targetFile.path);

        final durationMs = sw.elapsedMilliseconds;
        final fileSizeMb = (await targetFile.length()) / (1024 * 1024);
        if (durationMs > 15000) {
          logWarning(
            'VideoWallpaperCache',
            '[OVERWAIT WARNING] Video download took ${durationMs}ms for ${fileSizeMb.toStringAsFixed(2)}MB',
          );
        } else {
          logPerf(
            'VideoWallpaperCache',
            'Video cached: ${targetFile.path} (${fileSizeMb.toStringAsFixed(2)} MB in ${durationMs}ms)',
          );
        }

        // Also duplicate/link under normalizedKey if different for instant lookups
        if (rawUrlKey != normalizedUrlKey) {
          final normalizedTarget = File(
            '${cacheDir.path}\\$normalizedUrlKey.$extension',
          );
          if (!await normalizedTarget.exists()) {
            try {
              await targetFile.copy(normalizedTarget.path);
            } catch (_) {}
          }
        }

        onProgress?.call(1);
        return targetFile;
      } on DioException catch (dioErr) {
        lastDioException = dioErr;
        lastError = dioErr;
        if (await tempFile.exists()) await tempFile.delete();
        // Try the next candidate if available
        continue;
      } catch (err) {
        lastError = err;
        if (await tempFile.exists()) await tempFile.delete();
      }
    }

    if (lastDioException != null) {
      final code = lastDioException.response?.statusCode;
      if (code == 403) {
        throw const HttpException(
          'Access denied by video server (HTTP 403). The video link may have expired or is protected.',
        );
      } else if (code == 404) {
        throw const HttpException(
          'Video not found (HTTP 404). The source video file may have been moved or deleted.',
        );
      }
      throw HttpException(
        lastDioException.message ??
            'Failed to download video from remote server.',
      );
    }

    if (lastError != null) {
      if (lastError is Exception) throw lastError;
      throw Exception(lastError.toString());
    }

    throw const FormatException('Failed to download video from provided URL.');
  }

  static const _supportedExtensions = {
    'mp4',
    'm4v',
    'webm',
    'mov',
    'ogv',
    'ogg',
  };

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    return dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  }

  static String? _extensionFor(String? contentType, String urlPath) {
    final byContentType = switch (contentType?.toLowerCase()) {
      'video/mp4' => 'mp4',
      'video/x-m4v' => 'm4v',
      'video/webm' => 'webm',
      'video/quicktime' => 'mov',
      'video/ogg' || 'application/ogg' => 'ogv',
      _ => null,
    };
    if (byContentType != null) return byContentType;

    if (contentType != null &&
        contentType.isNotEmpty &&
        contentType != 'application/octet-stream') {
      return null;
    }
    final fromUrl = _extension(urlPath);
    return _supportedExtensions.contains(fromUrl) ? fromUrl : null;
  }
}
