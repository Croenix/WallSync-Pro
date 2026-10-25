import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'settings_service.dart';
import 'video_thumbnail_service.dart';

class WallpaperMetadata {
  final int width;
  final int height;
  final String label;
  final String source;
  final bool verified;

  const WallpaperMetadata({
    required this.width,
    required this.height,
    required this.label,
    required this.source,
    required this.verified,
  });

  const WallpaperMetadata.unavailable()
    : width = 0,
      height = 0,
      label = 'Resolution unavailable',
      source = 'unavailable',
      verified = false;

  String get displayLabel => verified ? '$width × $height · $label' : label;

  Map<String, Object?> toJson() => {
    'width': width,
    'height': height,
    'resolutionLabel': label,
    'resolutionSource': source,
    'resolutionVerified': verified,
  };

  factory WallpaperMetadata.fromJson(Map<String, dynamic> json) {
    final rawWidth = json['width'];
    final rawHeight = json['height'];
    final width = rawWidth is num ? rawWidth.toInt() : 0;
    final height = rawHeight is num ? rawHeight.toInt() : 0;
    final verified =
        json['resolutionVerified'] == true && width > 0 && height > 0;
    final rawSource = json['resolutionSource'];
    return WallpaperMetadata(
      width: verified ? width : 0,
      height: verified ? height : 0,
      label: verified
          ? classifyResolution(width, height)
          : 'Resolution unavailable',
      source: rawSource is String ? rawSource : 'unavailable',
      verified: verified,
    );
  }
}

String classifyResolution(int width, int height) {
  if (width <= 0 || height <= 0) return 'Resolution unavailable';

  final longSide = width > height ? width : height;
  final shortSide = width > height ? height : width;
  const references = <(int, int, String)>[
    (1280, 720, 'HD'),
    (1920, 1080, 'Full HD'),
    (2048, 1080, '2K'),
    (2560, 1440, '2K'),
    (4096, 2160, '4K'),
    (3840, 2160, '4K'),
    (7680, 4320, '8K'),
    (15360, 8640, '16K'),
  ];
  for (final (targetLong, targetShort, label) in references) {
    final longRatio = longSide / targetLong;
    final shortRatio = shortSide / targetShort;
    if ((longRatio - shortRatio).abs() <= 0.03 &&
        (longRatio - 1).abs() <= 0.05 &&
        (shortRatio - 1).abs() <= 0.05) {
      return label;
    }
  }
  return 'Other';
}

class WallpaperMetadataService {
  WallpaperMetadataService._();
  static final WallpaperMetadataService instance = WallpaperMetadataService._();

  static const int _maxHeaderBytes = 256 * 1024;
  static const Duration _probeTimeout = Duration(seconds: 12);
  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..maxConnectionsPerHost = 4;
  final Map<String, WallpaperMetadata> _memoryCache = {};
  final Map<String, DateTime> _memoryCacheTime = {};
  final Map<String, Future<WallpaperMetadata>> _inFlight = {};
  int _activeVideoProbes = 0;
  Timer? _cacheWriteDebounce;
  Map<String, dynamic>? _diskCache;
  Future<void>? _cacheLoad;

  Future<WallpaperMetadata> getMetadata({
    required String url,
    required bool isVideo,
  }) async {
    final key = sha256.convert(utf8.encode(url)).toString();
    final cached = _memoryCache[key];
    final cachedAt = _memoryCacheTime[key];
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < const Duration(minutes: 10)) {
      return cached;
    }
    _memoryCache.remove(key);
    _memoryCacheTime.remove(key);
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _probe(key, url, isVideo);
    _inFlight[key] = future;
    try {
      final metadata = await future;
      _memoryCache[key] = metadata;
      _memoryCacheTime[key] = DateTime.now();
      return metadata;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<WallpaperMetadata> _probe(String key, String url, bool isVideo) async {
    try {
      await _loadCache();
      final source = url.trim();
      if (source.startsWith('asset://')) {
        final assetPath = source.substring('asset://'.length);
        final data = await rootBundle.load(assetPath);
        final metadata = _fromImageBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          'asset',
        );
        await _saveMetadata(key, metadata, _fingerprint(data.lengthInBytes));
        return metadata;
      }
      if (isVideo) {
        while (_activeVideoProbes >= 2) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        _activeVideoProbes++;
        late final WallpaperMetadata video;
        try {
          video = await _probeVideo(source);
        } finally {
          _activeVideoProbes--;
        }
        if (video.verified) {
          await _saveMetadata(key, video, 'video-stream');
          return video;
        }
        return _cached(key) ?? video;
      }

      final request = await _httpClient
          .getUrl(Uri.parse(source))
          .timeout(_probeTimeout);
      request.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=0-${_maxHeaderBytes - 1}',
      );
      final response = await request.close().timeout(_probeTimeout);
      if (response.statusCode != HttpStatus.partialContent &&
          response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return _cached(key) ?? const WallpaperMetadata.unavailable();
      }
      final bytes = BytesBuilder(copy: false);
      var read = 0;
      await for (final chunk in response.timeout(_probeTimeout)) {
        final available = _maxHeaderBytes - read;
        if (available <= 0) break;
        final length = chunk.length < available ? chunk.length : available;
        bytes.add(chunk.sublist(0, length));
        read += length;
        if (length < chunk.length || read == _maxHeaderBytes) break;
      }
      final etag = response.headers.value(HttpHeaders.etagHeader) ?? '';
      final modified =
          response.headers.value(HttpHeaders.lastModifiedHeader) ?? '';
      final contentRange = response.headers.value('content-range') ?? '';
      final fingerprint =
          '$etag|$modified|$contentRange|${response.contentLength}';
      final cachedEntry = _diskCache?[key];
      if ((etag.isNotEmpty ||
              modified.isNotEmpty ||
              contentRange.isNotEmpty ||
              response.contentLength >= 0) &&
          cachedEntry is Map &&
          cachedEntry['fingerprint'] == fingerprint) {
        return WallpaperMetadata.fromJson(
          Map<String, dynamic>.from(cachedEntry),
        );
      }
      final image = _fromImageBytes(bytes.takeBytes(), 'source');
      if (image.verified) {
        await _saveMetadata(key, image, fingerprint);
        return image;
      }
      return _cached(key) ?? image;
    } on TimeoutException {
      return _cached(key) ?? const WallpaperMetadata.unavailable();
    } on IOException {
      return _cached(key) ?? const WallpaperMetadata.unavailable();
    } on FormatException {
      return _cached(key) ?? const WallpaperMetadata.unavailable();
    } catch (error, stackTrace) {
      logWarning(
        'WallpaperMetadataService',
        'Unexpected resolution probe failure: $error\n$stackTrace',
      );
      return _cached(key) ?? const WallpaperMetadata.unavailable();
    }
  }

  Future<WallpaperMetadata> _probeVideo(String source) async {
    final executable = await VideoThumbnailService.findMpvExecutable();
    if (executable == null) return const WallpaperMetadata.unavailable();
    final resolvedSource = await VideoThumbnailService.instance
        .resolveVideoSourceForMetadata(source);
    if (resolvedSource.isEmpty) return const WallpaperMetadata.unavailable();
    Process? process;
    try {
      process = await Process.start(executable, [
        '--no-config',
        '--vo=null',
        '--ao=null',
        '--frames=1',
        '--term-playing-msg=WS_RESOLUTION=\${width}x\${height}',
        resolvedSource,
      ]);
      final stdout = StringBuffer();
      final stderr = StringBuffer();
      final outSubscription = process.stdout
          .transform(utf8.decoder)
          .listen(stdout.write);
      final errSubscription = process.stderr
          .transform(utf8.decoder)
          .listen(stderr.write);
      try {
        await process.exitCode.timeout(_probeTimeout);
      } on TimeoutException {
        process.kill();
      }
      await Future.wait([outSubscription.cancel(), errSubscription.cancel()]);
      final output = '${stdout.toString()}\n${stderr.toString()}';
      final match = RegExp(r'WS_RESOLUTION=(\d+)x(\d+)').firstMatch(output);
      if (match == null) return const WallpaperMetadata.unavailable();
      final width = int.parse(match.group(1)!);
      final height = int.parse(match.group(2)!);
      return _create(width, height, 'video-stream');
    } finally {
      if (process != null) process.kill();
    }
  }

  WallpaperMetadata _fromImageBytes(Uint8List bytes, String source) {
    final dimensions = readImageDimensions(bytes);
    if (dimensions == null) return const WallpaperMetadata.unavailable();
    return _create(dimensions.$1, dimensions.$2, source);
  }

  WallpaperMetadata _create(int width, int height, String source) {
    if (width <= 0 || height <= 0) {
      return const WallpaperMetadata.unavailable();
    }
    return WallpaperMetadata(
      width: width,
      height: height,
      label: classifyResolution(width, height),
      source: source,
      verified: true,
    );
  }

  static (int, int)? readImageDimensions(Uint8List b) {
    if (b.length >= 24 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4e &&
        b[3] == 0x47) {
      return (_u32be(b, 16), _u32be(b, 20));
    }
    if (b.length >= 10 && String.fromCharCodes(b.take(3)) == 'GIF') {
      return (_u16le(b, 6), _u16le(b, 8));
    }
    if (b.length >= 30 &&
        String.fromCharCodes(b.take(4)) == 'RIFF' &&
        String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
      final kind = String.fromCharCodes(b.sublist(12, 16));
      if (kind == 'VP8X' && b.length >= 30) {
        final width = 1 + b[24] + (b[25] << 8) + (b[26] << 16);
        final height = 1 + b[27] + (b[28] << 8) + (b[29] << 16);
        return (width, height);
      }
      if (kind == 'VP8 ' && b.length >= 30) {
        return (_u16le(b, 26) & 0x3fff, _u16le(b, 28) & 0x3fff);
      }
      if (kind == 'VP8L' && b.length >= 25) {
        final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
        return ((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
      }
    }
    if (b.length >= 26 && b[0] == 0x42 && b[1] == 0x4d) {
      return (_u32le(b, 18), _u32le(b, 22));
    }
    if (b.length < 4 || b[0] != 0xff || b[1] != 0xd8) return null;
    var offset = 2;
    while (offset + 4 <= b.length) {
      if (b[offset] != 0xff) {
        offset++;
        continue;
      }
      while (offset < b.length && b[offset] == 0xff) {
        offset++;
      }
      if (offset >= b.length) break;
      final marker = b[offset++];
      if (marker == 0xd8 ||
          marker == 0xd9 ||
          marker == 0x01 ||
          (marker >= 0xd0 && marker <= 0xd7)) {
        continue;
      }
      if (offset + 2 > b.length) break;
      final length = (b[offset] << 8) | b[offset + 1];
      if (length < 2 || offset + length > b.length) break;
      if (_isJpegStartOfFrame(marker)) {
        if (length < 7) return null;
        return (
          (b[offset + 5] << 8) | b[offset + 6],
          (b[offset + 3] << 8) | b[offset + 4],
        );
      }
      offset += length;
    }
    return null;
  }

  static bool _isJpegStartOfFrame(int marker) =>
      marker == 0xc0 ||
      marker == 0xc1 ||
      marker == 0xc2 ||
      marker == 0xc3 ||
      marker == 0xc5 ||
      marker == 0xc6 ||
      marker == 0xc7 ||
      marker == 0xc9 ||
      marker == 0xca ||
      marker == 0xcb ||
      marker == 0xcd ||
      marker == 0xce ||
      marker == 0xcf;

  static int _u16le(Uint8List b, int offset) =>
      b[offset] | (b[offset + 1] << 8);
  static int _u32be(Uint8List b, int offset) =>
      (b[offset] << 24) |
      (b[offset + 1] << 16) |
      (b[offset + 2] << 8) |
      b[offset + 3];
  static int _u32le(Uint8List b, int offset) =>
      b[offset] |
      (b[offset + 1] << 8) |
      (b[offset + 2] << 16) |
      (b[offset + 3] << 24);

  String _fingerprint(int length) => 'asset:$length';

  WallpaperMetadata? _cached(String key) {
    final entry = _diskCache?[key];
    if (entry is! Map) return null;
    return WallpaperMetadata.fromJson(Map<String, dynamic>.from(entry));
  }

  Future<void> _loadCache() async {
    if (_diskCache != null) return;
    final pending = _cacheLoad;
    if (pending != null) return pending;
    _cacheLoad = () async {
      try {
        final dir = await SettingsService().getAppDirectory();
        final file = File('${dir.path}\\wallpaper_resolution_cache.json');
        if (await file.exists()) {
          final json = jsonDecode(await file.readAsString());
          if (json is Map<String, dynamic>) _diskCache = json;
        }
      } on FileSystemException {
        _diskCache = {};
      } on FormatException {
        _diskCache = {};
      } catch (error, stackTrace) {
        logWarning(
          'WallpaperMetadataService',
          'Could not load wallpaper resolution cache: $error\n$stackTrace',
        );
        _diskCache = {};
      }
      _diskCache ??= {};
    }();
    try {
      await _cacheLoad;
    } finally {
      _cacheLoad = null;
    }
  }

  Future<void> _saveMetadata(
    String key,
    WallpaperMetadata metadata,
    String fingerprint,
  ) async {
    await _loadCache();
    final cached = _diskCache![key];
    if (cached is Map && cached['fingerprint'] == fingerprint) return;
    _diskCache![key] = {...metadata.toJson(), 'fingerprint': fingerprint};
    _cacheWriteDebounce?.cancel();
    _cacheWriteDebounce = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(_writeCache()),
    );
  }

  Future<void> _writeCache() async {
    try {
      final dir = await SettingsService().getAppDirectory();
      final file = File('${dir.path}\\wallpaper_resolution_cache.json');
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(_diskCache), flush: true);
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
    } on FileSystemException catch (error) {
      logWarning(
        'WallpaperMetadataService',
        'Could not persist wallpaper resolution cache: $error',
      );
    }
  }
}
