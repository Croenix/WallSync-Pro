import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:crypto/crypto.dart';
import 'settings_service.dart';
import 'wallpaper_metadata_service.dart';

Map<String, Object?> _parseWallpaperCatalogSnapshot(String content) {
  final decodeStopwatch = Stopwatch()..start();
  final dynamic decoded = jsonDecode(content);
  final jsonDecodeMicros = decodeStopwatch.elapsedMicroseconds;
  final dynamic data = decoded is Map && decoded['wallpapers'] is List
      ? decoded['wallpapers']
      : decoded;
  final modelStopwatch = Stopwatch()..start();
  final wallpapers = <FirebaseWallpaper>[];
  final savedKeys = decoded is Map && decoded['keys'] is List
      ? (decoded['keys'] as List).map((key) => key.toString()).toList()
      : null;
  final keys = <String>[];
  if (data is Map) {
    data.forEach((key, value) {
      keys.add(key.toString());
      if (value is Map) {
        final wallpaper = FirebaseWallpaper.fromJson(
          key.toString(),
          Map<String, dynamic>.from(value),
        );
        if (wallpaper.hasUsableSource) wallpapers.add(wallpaper);
      }
    });
  } else if (data is List) {
    for (var index = 0; index < data.length; index++) {
      final value = data[index];
      keys.add(
        value is Map && value['id'] != null
            ? value['id'].toString()
            : index.toString(),
      );
      if (value is Map) {
        final wallpaper = FirebaseWallpaper.fromJson(
          value['id']?.toString() ?? index.toString(),
          Map<String, dynamic>.from(value),
        );
        if (wallpaper.hasUsableSource) wallpapers.add(wallpaper);
      }
    }
  }
  return {
    'keys': savedKeys ?? keys,
    'wallpapers': wallpapers,
    'jsonDecodeMicros': jsonDecodeMicros,
    'modelConversionMicros': modelStopwatch.elapsedMicroseconds,
  };
}

Future<Set<String>> _listValidCachedWallpaperFilenames(String path) async {
  final dir = Directory(path);
  if (!await dir.exists()) return <String>{};
  final valid = <String>{};
  try {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) {
        try {
          if (await entity.length() > 0) {
            final p = entity.path;
            final sep = Platform.pathSeparator;
            final idx = p.lastIndexOf(sep);
            final name = idx != -1 ? p.substring(idx + 1) : p;
            valid.add(name);
          }
        } catch (_) {}
      }
    }
  } catch (_) {}
  return valid;
}

const int _catalogIsolateThresholdCharacters = 256 * 1024;

class _RemoteWallpaperCatalog {
  final List<FirebaseWallpaper> wallpapers;
  final List<String> keys;

  const _RemoteWallpaperCatalog(this.wallpapers, this.keys);
}

class FirebaseWallpaper {
  final String id;
  final String name;
  final String category;
  final String type; // 'static' | 'animated'
  final String url; // remote URL
  final String? thumbnailUrl;
  final String?
  animatedBgPreset; // if animated, which local preset to use (optional)
  final String? description; // short description (optional)
  final String filename;
  final String legacyFilename;
  final int width;
  final int height;
  final String resolutionLabel;
  final String resolutionSource;
  final bool resolutionVerified;
  final bool isPro;

  FirebaseWallpaper({
    required this.id,
    required this.name,
    required this.category,
    required this.type,
    required this.url,
    this.thumbnailUrl,
    this.animatedBgPreset,
    this.description,
    this.width = 0,
    this.height = 0,
    this.resolutionLabel = 'Resolution unavailable',
    this.resolutionSource = 'unavailable',
    this.resolutionVerified = false,
    this.isPro = false,
  }) : filename =
           '${_safeFilePart(id)}_${_urlDigest(url)}_${_getFilenameFromUrl(url)}',
       legacyFilename = '${_safeFilePart(id)}_${_getFilenameFromUrl(url)}';

  static String _safeFilePart(String value) {
    final sanitized = value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (sanitized.isEmpty) return 'wallpaper';
    return sanitized.substring(
      0,
      sanitized.length > 80 ? 80 : sanitized.length,
    );
  }

  static String _urlDigest(String url) =>
      sha256.convert(utf8.encode(url)).toString().substring(0, 16);

  static String _getFilenameFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.pathSegments.isNotEmpty) {
        var name = uri.pathSegments.last;
        if (name.isNotEmpty) {
          if (!name.contains('.')) {
            name = '$name.jpg';
          }
          name = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
          name = name.replaceAll(RegExp(r'^\.+'), '');
          if (name.isNotEmpty) {
            return name.substring(0, name.length > 100 ? 100 : name.length);
          }
        }
      }
    } catch (e, st) {
      debugPrint(
        'Swallowed Error in lib/services/firebase_service.dart: $e\nStacktrace: $st',
      );
    }
    return 'wallpaper.png';
  }

  static String normalizeMixkitUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return trimmed;
    final match = RegExp(
      r'assets\.mixkit\.co\/videos\/preview\/(?:mixkit-)?.*?(\d+)-(?:large|medium|small)\.mp4',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (match != null) {
      final videoId = match.group(1);
      return 'https://assets.mixkit.co/videos/$videoId/$videoId-720.mp4';
    }
    return trimmed;
  }

  bool get isVideo {
    final lowerType = type.toLowerCase();
    final lowerCat = category.toLowerCase();
    final lowerUrl = url.toLowerCase();
    return lowerType == 'video' ||
        lowerCat.contains('video') ||
        lowerCat.contains('live') ||
        lowerUrl.contains('/video/') ||
        lowerUrl.endsWith('.mp4') ||
        lowerUrl.endsWith('.webm') ||
        lowerUrl.endsWith('.mkv') ||
        lowerUrl.endsWith('.mov') ||
        lowerUrl.contains('.mp4?') ||
        lowerUrl.contains('.webm?');
  }

  String get wallpaperType => isVideo ? 'video' : 'static';

  static bool isValidThumbnailUrl(String url) {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host == 'example.com' ||
        uri.host.endsWith('.example.com')) {
      return false;
    }
    final lower = trimmed.toLowerCase();
    final path = uri.path.toLowerCase();
    final videoExtRegex = RegExp(
      r'\.(mp4|webm|mkv|mov|avi|m4v)(\?|#|$)',
      caseSensitive: false,
    );
    if (videoExtRegex.hasMatch(lower) || videoExtRegex.hasMatch(path)) {
      return false;
    }
    return true;
  }

  bool get hasUsableSource {
    if (url.startsWith('asset://')) return true;
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.hasAuthority &&
        uri.host.isNotEmpty &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host != 'example.com' &&
        !uri.host.endsWith('.example.com');
  }

  static String? resolveDefaultVideoThumbnail({
    required String id,
    required String name,
    required String category,
    required String url,
  }) {
    if (url.contains('res.cloudinary.com')) {
      final sanitized = url.replaceAll(
        RegExp(r'\.[a-zA-Z0-9]+(\?.*)?$'),
        '.jpg',
      );
      if (sanitized != url) return sanitized;
      return '$url.jpg';
    }
    return null;
  }

  static String resolveFallbackLocalAsset({
    required String id,
    required String name,
    required String category,
  }) {
    final lowerId = id.toLowerCase();
    final lowerName = name.toLowerCase();
    final lowerCat = category.toLowerCase();

    if (lowerId.contains('stream') ||
        lowerName.contains('forest') ||
        lowerName.contains('leaves') ||
        lowerCat.contains('nature')) {
      return 'asset://assets/forest.png';
    }
    if (lowerId.contains('blazes') ||
        lowerName.contains('solar') ||
        lowerCat.contains('space')) {
      return 'asset://assets/cosmic_dust.png';
    }
    return 'asset://assets/cyberpunk.png';
  }

  /// Transforms high-resolution Cloudinary URLs into lightweight preview thumbnails
  /// (~20KB vs 20MB 8K originals, reducing memory consumption by over 99%).
  static String toOptimizedThumbnailUrl(
    String imageUrl, {
    int width = 360,
    int height = 240,
  }) {
    final trimmed = imageUrl.trim();
    if (trimmed.isEmpty) return trimmed;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host != 'res.cloudinary.com') return trimmed;

    final isImage = uri.path.contains('/image/upload/');
    final isVideo = uri.path.contains('/video/upload/');
    if (!isImage && !isVideo) return trimmed;

    final uploadMarker = isImage ? '/image/upload/' : '/video/upload/';
    final markerIndex = uri.path.indexOf(uploadMarker);
    if (markerIndex < 0) return trimmed;
    final insertionIndex = markerIndex + uploadMarker.length;
    final sub = uri.path.substring(insertionIndex);
    if (sub.startsWith('w_') || sub.startsWith('c_')) return trimmed;

    final transformedPath =
        '${uri.path.substring(0, insertionIndex)}'
        'w_$width,h_$height,c_fill,q_auto,f_auto/'
        '$sub';
    return uri.replace(path: transformedPath).toString();
  }

  factory FirebaseWallpaper.fromJson(String id, Map<String, dynamic> json) {
    final rawUrl = json['url'] is String ? json['url'] as String : '';
    final url = normalizeMixkitUrl(rawUrl);
    final category = json['category'] is String
        ? json['category'] as String
        : 'General';
    final name = json['name'] is String
        ? json['name'] as String
        : 'Wallpaper $id';
    final type = json['type'] is String ? json['type'] as String : 'static';

    final rawThumb =
        json['thumbnailUrl'] ??
        json['thumbnail'] ??
        json['previewImage'] ??
        json['poster'];
    String? thumb = rawThumb is String && rawThumb.trim().isNotEmpty
        ? rawThumb.trim()
        : null;
    if (thumb != null &&
        !thumb.startsWith('asset://') &&
        !isValidThumbnailUrl(thumb)) {
      thumb = null;
    }

    final lowerUrl = url.toLowerCase();
    final isVideo =
        type == 'video' ||
        category.toLowerCase().contains('video') ||
        category.toLowerCase().contains('live') ||
        lowerUrl.contains('/video/') ||
        lowerUrl.endsWith('.mp4') ||
        lowerUrl.endsWith('.webm') ||
        lowerUrl.endsWith('.mkv') ||
        lowerUrl.endsWith('.mov') ||
        lowerUrl.contains('.mp4?') ||
        lowerUrl.contains('.webm?');

    if (thumb == null && isVideo) {
      thumb = resolveDefaultVideoThumbnail(
        id: id,
        name: name,
        category: category,
        url: url,
      );
    }

    // Automatically optimize Cloudinary thumbnail URLs so 4K/8K images are never
    // downloaded or decoded as full uncompressed bitmaps for card previews
    if (thumb != null) {
      thumb = toOptimizedThumbnailUrl(thumb);
    } else if (!isVideo && url.isNotEmpty) {
      thumb = toOptimizedThumbnailUrl(url);
    }

    final resolution = WallpaperMetadata.fromJson(json);
    final isPro =
        json['isPro'] == true ||
        json['pro'] == true ||
        json['is_pro'] == true;
    return FirebaseWallpaper(
      id: id,
      name: name,
      category: category,
      type: type,
      url: url,
      thumbnailUrl: thumb,
      animatedBgPreset: json['animatedBgPreset'] is String
          ? json['animatedBgPreset'] as String
          : null,
      description: json['description'] is String
          ? json['description'] as String
          : null,
      width: resolution.width,
      height: resolution.height,
      resolutionLabel: resolution.label,
      resolutionSource: resolution.source,
      resolutionVerified: resolution.verified,
      isPro: isPro,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'wallpaperId': id,
      'name': name,
      'category': category,
      'type': type,
      'url': url,
      'thumbnailUrl': thumbnailUrl,
      'animatedBgPreset': animatedBgPreset,
      'description': description,
      'width': width,
      'height': height,
      'resolutionLabel': resolutionLabel,
      'resolutionSource': resolutionSource,
      'resolutionVerified': resolutionVerified,
      'isPro': isPro,
    };
  }
}

class FirebaseService {
  static final FirebaseService _instance = FirebaseService._internal();
  factory FirebaseService() => _instance;
  FirebaseService._internal()
    : _databaseUrl = databaseUrl,
      _httpClient = _sharedClient;

  @visibleForTesting
  FirebaseService.forTesting({required String endpoint, HttpClient? httpClient})
    : _databaseUrl = endpoint,
      _httpClient = httpClient ?? HttpClient();

  static FirebaseService get instance => _instance;

  static const String databaseUrl =
      'https://wallsync-e043c-default-rtdb.firebaseio.com';
  final String _databaseUrl;
  final HttpClient _httpClient;
  final Map<String, Future<String>> _pendingReportSubmissions = {};
  static bool _cachedWallpapersDirCreated = false;

  // Shared HttpClient to enable TCP connection reuse (Keep-Alive) and massive performance optimizations.
  static final HttpClient _sharedClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 5;

  static final Map<String, Future<File?>> _wallpaperDownloads = {};
  static final Map<String, Future<File?>> _thumbnailDownloads = {};
  static final Map<String, DateTime> _thumbnailFailureUntil = {};
  static const Duration _thumbnailFailureCooldown = Duration(minutes: 5);
  static int _activeThumbnailDownloads = 0;
  static final List<Completer<void>> _thumbnailSlotWaiters = [];
  Set<String> _localCatalogKeys = {};
  static List<FirebaseWallpaper>? _inMemoryCatalogCache;
  Future<_RemoteWallpaperCatalog?>? _inFlightRemoteCatalog;
  Future<Map<String, dynamic>?>? _inFlightCheckUpdate;

  // In-memory index of wallpaper filenames known to exist in cached_wallpapers/.
  // Populated from one directory listing, then validated only when a catalog
  // item references a candidate file.
  static final Set<String> _cachedWallpaperFilenames = {};
  static final Map<String, Future<bool>> _wallpaperFileValidations = {};
  static bool _wallpaperCacheIndexWarmed = false;
  static Future<void>? _wallpaperCacheIndexWarmup;

  /// Warms the in-memory cached-wallpaper file index from a single directory scan.
  /// Call this once after the app directory is known, before loading the gallery.
  static Future<void> warmWallpaperCacheIndex() {
    if (_wallpaperCacheIndexWarmed) return Future<void>.value();
    final pending = _wallpaperCacheIndexWarmup;
    if (pending != null) return pending;
    final warmup = _warmWallpaperCacheIndex();
    _wallpaperCacheIndexWarmup = warmup;
    return warmup.whenComplete(() {
      if (identical(_wallpaperCacheIndexWarmup, warmup)) {
        _wallpaperCacheIndexWarmup = null;
      }
    });
  }

  static Future<void> _warmWallpaperCacheIndex() async {
    final stopwatch = Stopwatch()..start();
    try {
      final appDirectoryStopwatch = Stopwatch()..start();
      final appDir = await SettingsService().getAppDirectory();
      final appDirectoryMs = appDirectoryStopwatch.elapsedMilliseconds;
      final cacheDir = Directory('${appDir.path}/cached_wallpapers');
      final cacheDirectoryStopwatch = Stopwatch()..start();
      final cacheDirectoryExists = await cacheDir.exists();
      final cacheDirectoryMs = cacheDirectoryStopwatch.elapsedMilliseconds;
      if (!cacheDirectoryExists) {
        _wallpaperCacheIndexWarmed = true;
        logPerf(
          'FirebaseService',
          'Wallpaper cache index warmup found no cache directory '
              '(app directory ${appDirectoryMs}ms, cache directory check '
              '${cacheDirectoryMs}ms; total ${stopwatch.elapsedMilliseconds}ms).',
        );
        return;
      }
      final listingStopwatch = Stopwatch()..start();
      final validFilenames = await _listValidCachedWallpaperFilenames(cacheDir.path);
      final listingMs = listingStopwatch.elapsedMilliseconds;
      _cachedWallpaperFilenames
        ..clear()
        ..addAll(validFilenames);
      _validatedCachedWallpapers
        ..clear()
        ..addAll(validFilenames);
      _wallpaperFileValidations.clear();
      _wallpaperCacheIndexWarmed = true;
      final totalMs = stopwatch.elapsedMilliseconds;
      final measuredPhaseMs = appDirectoryMs + cacheDirectoryMs + listingMs;
      final unaccountedMs = max(0, totalMs - measuredPhaseMs);
      logPerf(
        'FirebaseService',
        'Wallpaper cache index listed ${_cachedWallpaperFilenames.length} files '
            'in ${listingMs}ms using async I/O '
            '(app directory ${appDirectoryMs}ms, cache directory check '
            '${cacheDirectoryMs}ms, unaccounted wall time ${unaccountedMs}ms; '
            '${totalMs}ms total warmup).',
      );
    } catch (e, st) {
      logError(
        'FirebaseService',
        'Failed to warm wallpaper cache index',
        e,
        st,
      );
      _wallpaperCacheIndexWarmed = true;
    }
  }

  static String _thumbnailFilename(String url) =>
      '${sha256.convert(utf8.encode(url)).toString()}.image';

  static bool _isThumbnailCoolingDown(String url) {
    final until = _thumbnailFailureUntil[url];
    if (until == null) return false;
    if (until.isAfter(DateTime.now())) return true;
    _thumbnailFailureUntil.remove(url);
    return false;
  }

  static void _markThumbnailFailure(String url) {
    _thumbnailFailureUntil[url] = DateTime.now().add(_thumbnailFailureCooldown);
  }

  /// Opens requests with the original hostname so HTTPS SNI and certificate
  /// hostname validation remain correct.
  static Future<HttpClientRequest> _openRequestRobustly(
    String method,
    Uri uri, {
    HttpClient? client,
  }) async {
    if (method != 'GET' && method != 'POST' && method != 'PUT') {
      throw UnsupportedError('Unsupported HTTP method: $method');
    }
    if (!uri.hasAuthority || (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw FormatException('Unsupported request URL: $uri');
    }
    final req = await (client ?? _sharedClient).openUrl(method, uri);
    req.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
    );
    req.headers.set(HttpHeaders.acceptHeader, '*/*');
    return req;
  }

  static Future<HttpClientResponse> _closeRequestWithTimeout(
    HttpClientRequest request,
    Duration timeout,
  ) async {
    try {
      return await request.close().timeout(timeout);
    } catch (_) {
      request.abort();
      rethrow;
    }
  }

  static Future<int> _writeResponseToFile(
    HttpClientResponse response,
    File destination, {
    void Function(double progress)? onProgress,
    required Duration inactivityTimeout,
  }) async {
    final contentType = response.headers.contentType?.mimeType;
    if (contentType != null &&
        !contentType.startsWith('image/') &&
        contentType != 'application/octet-stream') {
      await response.drain();
      throw FormatException(
        'Expected an image response, received $contentType.',
      );
    }

    final total = response.contentLength;
    var received = 0;
    final sink = destination.openWrite();
    try {
      await sink.addStream(
        response
            .map((chunk) {
              received += chunk.length;
              if (total > 0) {
                onProgress?.call((received / total).clamp(0.0, 1.0));
              }
              return chunk;
            })
            .timeout(inactivityTimeout),
      );
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (received == 0) {
      throw const FormatException('The image response was empty.');
    }
    return received;
  }

  static const String _localDbFileName = 'local_rtdb_wallpapers.json';
  static final Set<String> _validatedCachedWallpapers = <String>{};
  static final Map<String, File> _cachedThumbnailFileMap = {};

  Future<File> get _localDbFile async {
    final appDir = await SettingsService().getAppDirectory();
    return File('${appDir.path}/$_localDbFileName');
  }

  /// Loads wallpapers saved in local RTDB cache file.
  Future<List<FirebaseWallpaper>?> loadLocalWallpapers() async {
    final cached = _inMemoryCatalogCache;
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }
    try {
      final file = await _localDbFile;
      if (!await file.exists() || await file.length() == 0) return null;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;
      final snapshot = content.length >= _catalogIsolateThresholdCharacters
          ? await compute(_parseWallpaperCatalogSnapshot, content)
          : _parseWallpaperCatalogSnapshot(content);
      _localCatalogKeys = Set<String>.from(snapshot['keys']! as List);
      final list = List<FirebaseWallpaper>.from(
        snapshot['wallpapers']! as List,
      );
      if (list.isNotEmpty) {
        final result = deduplicateWallpapers(list);
        _inMemoryCatalogCache = result;
        unawaited(_prewarmThumbnailCache(result));
        return result;
      }
    } catch (e, st) {
      logError('FirebaseService', 'Failed to read local RTDB cache', e, st);
    }
    return null;
  }

  static bool catalogHasChanges(
    List<FirebaseWallpaper> current,
    List<FirebaseWallpaper> updated,
  ) {
    if (current.length != updated.length) return true;
    for (var i = 0; i < current.length; i++) {
      final old = current[i];
      final next = updated[i];
      if (old.id != next.id ||
          old.name != next.name ||
          old.category != next.category ||
          old.type != next.type ||
          old.url != next.url ||
          old.thumbnailUrl != next.thumbnailUrl ||
          old.animatedBgPreset != next.animatedBgPreset ||
          old.description != next.description ||
          old.width != next.width ||
          old.height != next.height ||
          old.resolutionLabel != next.resolutionLabel ||
          old.resolutionSource != next.resolutionSource ||
          old.resolutionVerified != next.resolutionVerified) {
        return true;
      }
    }
    return false;
  }

  Future<void> _prewarmThumbnailCache(
    List<FirebaseWallpaper> wallpapers,
  ) async {
    try {
      final appDir = await SettingsService().getAppDirectory();
      final cacheDir = Directory('${appDir.path}/cached_thumbnails');
      if (!await cacheDir.exists()) return;

      // 1. Single-pass directory list: collect sizes and filenames, purge oversized files
      final fileSizes = <String, int>{};
      await for (final entity in cacheDir.list(followLinks: false)) {
        if (entity is File) {
          try {
            final len = await entity.length();
            final name = entity.uri.pathSegments.last;
            if (len > 400 * 1024) {
              await entity.delete();
            } else if (len > 0) {
              fileSizes[name] = len;
            }
          } catch (_) {}
        }
      }

      // 2. Prewarm in-memory thumbnail file lookup map for rapid 0ms synchronous access (zero individual stat calls)
      for (final w in wallpapers) {
        final url = w.thumbnailUrl;
        if (url != null && FirebaseWallpaper.isValidThumbnailUrl(url)) {
          final optUrl = FirebaseWallpaper.toOptimizedThumbnailUrl(url);
          final optName = _thumbnailFilename(optUrl);
          final rawName = _thumbnailFilename(url);

          File? validFile;
          if (fileSizes.containsKey(optName)) {
            validFile = File('${cacheDir.path}/$optName');
          } else if (fileSizes.containsKey(rawName)) {
            validFile = File('${cacheDir.path}/$rawName');
          }

          if (validFile != null) {
            _cachedThumbnailFileMap[url] = validFile;
            _cachedThumbnailFileMap[optUrl] = validFile;
          }
        }
      }
    } catch (_) {}
  }

  /// Saves wallpapers and their keys to local RTDB cache file atomically.
  Future<void> saveLocalWallpapers(
    List<FirebaseWallpaper> wallpapers,
    List<String> keys,
  ) async {
    try {
      final file = await _localDbFile;
      final tempFile = File('${file.path}.tmp');
      final payload = {
        'version': 1,
        'lastSynced': DateTime.now().millisecondsSinceEpoch,
        'keys': keys,
        'wallpapers': wallpapers.map((w) => w.toJson()).toList(),
      };
      await tempFile.writeAsString(jsonEncode(payload), flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await tempFile.rename(file.path);
      _localCatalogKeys = keys.toSet();
      _inMemoryCatalogCache = wallpapers;
      logInfo(
        'FirebaseService',
        'Saved ${wallpapers.length} wallpapers to local RTDB file: ${file.path}',
      );
    } catch (e, st) {
      logError(
        'FirebaseService',
        'Failed to save local RTDB cache file',
        e,
        st,
      );
    }
  }

  /// Fetches wallpapers: checks local RTDB first, then syncs with remote RTDB
  /// only if new entries or modified data are found.
  Future<List<FirebaseWallpaper>> fetchWallpapers({
    bool forceRefresh = false,
    void Function(List<FirebaseWallpaper> updated)? onRemoteUpdated,
  }) async {
    // 1. Try to load from Local RTDB first to avoid calling remote RTDB every time
    final localList = await loadLocalWallpapers();
    if (!forceRefresh && localList != null && localList.isNotEmpty) {
      logInfo(
        'FirebaseService',
        'Loaded ${localList.length} wallpapers immediately from local RTDB cache.',
      );
      unawaited(_refreshRemoteCatalogInBackground(localList, onRemoteUpdated));
      // Pre-cache thumbnails asynchronously in the background
      unawaited(prefetchThumbnails(_thumbnailUrls(localList)));
      return localList;
    }

    if (!forceRefresh) {
      final fallback = _getFallbackCuratedWallpapers();
      unawaited(_refreshRemoteCatalogInBackground(fallback, onRemoteUpdated));
      return fallback;
    }

    // 2. Fetch full catalog from remote RTDB (first run or manual force refresh)
    final remoteCatalog = await _fetchRemoteWallpapers();
    if (remoteCatalog != null && remoteCatalog.wallpapers.isNotEmpty) {
      await saveLocalWallpapers(remoteCatalog.wallpapers, remoteCatalog.keys);
      unawaited(prefetchThumbnails(_thumbnailUrls(remoteCatalog.wallpapers)));
      return remoteCatalog.wallpapers;
    }

    // 3. Fallback to local DB if remote failed, else curated wallpapers
    if (localList != null && localList.isNotEmpty) {
      return localList;
    }
    return _getFallbackCuratedWallpapers();
  }

  Future<void> _refreshRemoteCatalogInBackground(
    List<FirebaseWallpaper> currentCatalog,
    void Function(List<FirebaseWallpaper> updated)? onRemoteUpdated,
  ) async {
    try {
      final remoteCatalog = await _fetchRemoteWallpapers();
      if (remoteCatalog == null || remoteCatalog.wallpapers.isEmpty) return;
      final catalogChanged = catalogHasChanges(
        currentCatalog,
        remoteCatalog.wallpapers,
      );
      final keysChanged =
          _localCatalogKeys.length != remoteCatalog.keys.length ||
          !_localCatalogKeys.containsAll(remoteCatalog.keys);
      if (catalogChanged || keysChanged) {
        await saveLocalWallpapers(remoteCatalog.wallpapers, remoteCatalog.keys);
      }
      if (catalogChanged) {
        onRemoteUpdated?.call(remoteCatalog.wallpapers);
        unawaited(prefetchThumbnails(_thumbnailUrls(remoteCatalog.wallpapers)));
      }
    } catch (error, stackTrace) {
      logError(
        'FirebaseService',
        'Background initial catalog refresh failed',
        error,
        stackTrace,
      );
    }
  }

  Future<_RemoteWallpaperCatalog?> _fetchRemoteWallpapers() {
    final pending = _inFlightRemoteCatalog;
    if (pending != null) return pending;
    final operation = _fetchRemoteWallpapersInternal();
    _inFlightRemoteCatalog = operation;
    return operation.whenComplete(() {
      if (identical(_inFlightRemoteCatalog, operation)) {
        _inFlightRemoteCatalog = null;
      }
    });
  }

  Future<_RemoteWallpaperCatalog?> _fetchRemoteWallpapersInternal() async {
    logInfo(
      'FirebaseService',
      'Fetching wallpaper catalog from remote RTDB database...',
    );
    final sw = Stopwatch()..start();
    int maxRetries = 2;
    for (int i = 0; i < maxRetries; i++) {
      try {
        final requestOpenStopwatch = Stopwatch()..start();
        final request = await _openRequestRobustly(
          'GET',
          Uri.parse('$databaseUrl/wallpapers.json'),
        ).timeout(const Duration(seconds: 12));
        final requestOpenMs = requestOpenStopwatch.elapsedMilliseconds;

        final responseHeaderStopwatch = Stopwatch()..start();
        final response = await _closeRequestWithTimeout(
          request,
          const Duration(seconds: 12),
        );
        final responseHeaderMs = responseHeaderStopwatch.elapsedMilliseconds;

        if (response.statusCode == 200) {
          final bodyReadStopwatch = Stopwatch()..start();
          final responseBody = await response.transform(utf8.decoder).join();
          final bodyReadMs = bodyReadStopwatch.elapsedMilliseconds;
          final parseStopwatch = Stopwatch()..start();
          final Map<String, Object?> snapshot =
              responseBody.length >= _catalogIsolateThresholdCharacters
              ? await compute(_parseWallpaperCatalogSnapshot, responseBody)
              : _parseWallpaperCatalogSnapshot(responseBody);
          final parseDispatchMs = parseStopwatch.elapsedMilliseconds;
          final parsedWallpapers = snapshot['wallpapers'];
          if (parsedWallpapers is! List<FirebaseWallpaper>) {
            throw const FormatException(
              'Firebase wallpaper catalog had an invalid parsed shape.',
            );
          }
          final keys = List<String>.from(snapshot['keys']! as List);
          final deduplicateStopwatch = Stopwatch()..start();
          final finalList = deduplicateWallpapers(parsedWallpapers);
          final deduplicateMs = deduplicateStopwatch.elapsedMilliseconds;
          logPerf(
            'FirebaseService',
            'Catalog fetched ${finalList.length} wallpapers: '
                'request open/connect ${requestOpenMs}ms, response headers '
                '${responseHeaderMs}ms, body read ${bodyReadMs}ms, '
                'parse/dispatch '
                '${parseDispatchMs}ms '
                '(JSON ${snapshot['jsonDecodeMicros']}us, '
                'model conversion ${snapshot['modelConversionMicros']}us), '
                'deduplicate ${deduplicateMs}ms, '
                '${responseBody.length} characters total '
                '(${sw.elapsedMilliseconds}ms overall).',
          );
          return _RemoteWallpaperCatalog(finalList, keys);
        } else {
          await response.drain();
        }
        break;
      } catch (e) {
        logWarning(
          'FirebaseService',
          'Attempt ${i + 1} to fetch wallpapers failed: $e',
        );
        if (i < maxRetries - 1) {
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    }
    return null;
  }

  /// Checks if the wallpaper is already downloaded in the local cache.
  /// Checks if a wallpaper's local file exists in the cache directory.
  /// Uses the URL-versioned filename so a changed source URL cannot reuse stale
  /// content from a legacy filename that did not include the URL.
  Future<bool> isWallpaperCached(FirebaseWallpaper wallpaper) async {
    await warmWallpaperCacheIndex();
    return _isValidCachedWallpaper(wallpaper.filename);
  }

  Future<bool> _isValidCachedWallpaper(String filename) async {
    if (!_cachedWallpaperFilenames.contains(filename)) return false;
    if (_validatedCachedWallpapers.contains(filename)) return true;
    final pending = _wallpaperFileValidations[filename];
    if (pending != null) return pending;

    final validation = () async {
      try {
        final appDir = await SettingsService().getAppDirectory();
        final file = File('${appDir.path}/cached_wallpapers/$filename');
        final isValid = await isCachedWallpaperFileValid(file);
        if (isValid) {
          _validatedCachedWallpapers.add(filename);
        } else {
          _cachedWallpaperFilenames.remove(filename);
          _validatedCachedWallpapers.remove(filename);
        }
        return isValid;
      } on FileSystemException {
        _cachedWallpaperFilenames.remove(filename);
        _validatedCachedWallpapers.remove(filename);
        return false;
      }
    }();
    _wallpaperFileValidations[filename] = validation;
    try {
      return await validation;
    } finally {
      if (identical(_wallpaperFileValidations[filename], validation)) {
        _wallpaperFileValidations.remove(filename);
      }
    }
  }

  @visibleForTesting
  static Future<bool> isCachedWallpaperFileValid(File file) async {
    try {
      return await file.length() > 0;
    } on FileSystemException {
      return false;
    }
  }

  /// Downloads a wallpaper asset to the local cache directory.
  /// Reports download progress (0.0 to 1.0).
  /// Skips downloading if the file is already cached.
  Future<File?> downloadWallpaper(
    FirebaseWallpaper wallpaper,
    void Function(double progress) onProgress,
  ) async {
    final key = '${wallpaper.id}|${wallpaper.url}';
    final existing = _wallpaperDownloads[key];
    if (existing != null) return existing;

    final download = _downloadWallpaper(wallpaper, onProgress);
    _wallpaperDownloads[key] = download;
    try {
      return await download;
    } finally {
      if (identical(_wallpaperDownloads[key], download)) {
        _wallpaperDownloads.remove(key);
      }
    }
  }

  Future<File?> _downloadWallpaper(
    FirebaseWallpaper wallpaper,
    void Function(double progress) onProgress,
  ) async {
    final downloadStopwatch = Stopwatch()..start();
    debugPrint(
      '[FirebaseService] ENTER downloadWallpaper(url: ${wallpaper.url})',
    );
    try {
      final appDir = await SettingsService().getAppDirectory();
      final cacheDir = Directory('${appDir.path}/cached_wallpapers');
      if (!_cachedWallpapersDirCreated) {
        if (!await cacheDir.exists()) {
          await cacheDir.create(recursive: true);
        }
        _cachedWallpapersDirCreated = true;
      }

      final targetFile = File('${cacheDir.path}/${wallpaper.filename}');
      debugPrint(
        '[FirebaseService] STATE: Target file path: ${targetFile.path}',
      );

      // Check if it's already cached first
      final cacheLookupStopwatch = Stopwatch()..start();
      final targetExists = await targetFile.exists();
      final cachedLength = targetExists ? await targetFile.length() : 0;
      final cacheLookupMs = cacheLookupStopwatch.elapsedMilliseconds;
      if (cachedLength > 0) {
        debugPrint(
          '[FirebaseService] STATE: Wallpaper is already cached: ${wallpaper.filename} ($cachedLength bytes)',
        );
        logPerf(
          'FirebaseService',
          'Wallpaper cache lookup found ${wallpaper.filename} in '
              '${cacheLookupMs}ms (total ${downloadStopwatch.elapsedMilliseconds}ms).',
        );
        debugPrint('[FirebaseService] EXIT downloadWallpaper() - CACHED');
        onProgress(1.0);
        return targetFile;
      }
      logPerf(
        'FirebaseService',
        'Wallpaper cache lookup missed ${wallpaper.filename} in ${cacheLookupMs}ms.',
      );

      // If it's a local asset scheme, load from rootBundle and write to local cache dir
      if (wallpaper.url.startsWith('asset://')) {
        try {
          final assetPath = wallpaper.url.replaceFirst('asset://', '');
          debugPrint(
            '[FirebaseService] STATE: Extracting asset wallpaper: $assetPath to ${targetFile.path}',
          );
          final data = await rootBundle.load(assetPath);
          final bytes = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
          final tempFile = File('${targetFile.path}.tmp');
          await tempFile.writeAsBytes(bytes, flush: true);
          if (await targetFile.exists()) await targetFile.delete();
          await tempFile.rename(targetFile.path);
          _markWallpaperCached(wallpaper.filename);
          onProgress(1.0);
          debugPrint(
            '[FirebaseService] EXIT downloadWallpaper() - ASSET EXTRACTED',
          );
          return targetFile;
        } catch (e, st) {
          final partialAsset = File('${targetFile.path}.tmp');
          if (await partialAsset.exists()) await partialAsset.delete();
          debugPrint(
            '[FirebaseService] ERROR: Failed to extract asset wallpaper: $e\nStacktrace: $st',
          );
          debugPrint(
            '[FirebaseService] EXIT downloadWallpaper() - ASSET ERROR',
          );
          return null;
        }
      }

      // If it's a local dummy or empty, skip downloading
      if (wallpaper.url.isEmpty || wallpaper.url.startsWith('asset')) {
        debugPrint(
          '[FirebaseService] ERROR: Unsupported wallpaper URL: ${wallpaper.url}',
        );
        return null;
      }

      debugPrint(
        '[FirebaseService] STATE: Downloading wallpaper natively: ${wallpaper.url}',
      );
      final tempFile = File('${targetFile.path}.tmp');

      int maxRetries = 2;
      int retryCount = 0;
      bool success = false;
      final networkStopwatch = Stopwatch()..start();

      while (retryCount < maxRetries && !success) {
        try {
          final requestStopwatch = Stopwatch()..start();
          debugPrint(
            '[FirebaseService] STATE: Opening connection to CDN... (Attempt ${retryCount + 1}/$maxRetries)',
          );
          final request = await _openRequestRobustly(
            'GET',
            Uri.parse(wallpaper.url),
          ).timeout(const Duration(seconds: 15));
          final requestOpenMs = requestStopwatch.elapsedMilliseconds;

          final responseStopwatch = Stopwatch()..start();
          debugPrint(
            '[FirebaseService] STATE: Headers set, waiting for response...',
          );
          final response = await _closeRequestWithTimeout(
            request,
            const Duration(seconds: 15),
          );
          final responseMs = responseStopwatch.elapsedMilliseconds;
          debugPrint(
            '[FirebaseService] STATE: Response received: HTTP ${response.statusCode}. Content-Length: ${response.contentLength}',
          );

          if (response.statusCode == 200) {
            final streamStopwatch = Stopwatch()..start();
            debugPrint('[FirebaseService] STATE: Beginning chunk stream...');
            final downloadedBytes = await _writeResponseToFile(
              response,
              tempFile,
              onProgress: onProgress,
              inactivityTimeout: const Duration(seconds: 45),
            );
            logPerf(
              'FirebaseService',
              'Wallpaper transfer phases for ${wallpaper.filename}: '
                  'request open/connect=${requestOpenMs}ms, '
                  'response headers=${responseMs}ms, '
                  'body/file stream=${streamStopwatch.elapsedMilliseconds}ms, '
                  'bytes=$downloadedBytes.',
            );
            success = true;
          } else {
            await response.drain();
            throw Exception(
              'Failed to download, HTTP status: ${response.statusCode}',
            );
          }
        } catch (e, st) {
          retryCount++;
          if (retryCount >= maxRetries) {
            debugPrint(
              '[FirebaseService] ERROR: Download completely failed after $maxRetries attempts. Error: $e\nStacktrace: $st',
            );
            rethrow;
          }
          debugPrint(
            '[FirebaseService] WARNING: Download failed (attempt $retryCount/$maxRetries). Retrying in 2 seconds... Error: $e\nStacktrace: $st',
          );
          await Future.delayed(const Duration(seconds: 1));
        }
      }

      debugPrint(
        '[FirebaseService] STATE: Preparing to rename temp file to target...',
      );
      // Rename temp file to final target file
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      if (await tempFile.length() == 0) {
        throw const FormatException('Downloaded wallpaper file is empty.');
      }
      await tempFile.rename(targetFile.path);
      debugPrint(
        '[FirebaseService] STATE: Rename successful. Download complete.',
      );

      // Update in-memory cache index so isWallpaperCached() instantly finds this file.
      _markWallpaperCached(wallpaper.filename);

      onProgress(1.0);
      debugPrint(
        '[FirebaseService] EXIT downloadWallpaper() - DOWNLOAD SUCCESS',
      );
      logPerf(
        'FirebaseService',
        'Wallpaper retrieval completed for ${wallpaper.filename}: '
            'cache lookup=${cacheLookupMs}ms, '
            'network=${networkStopwatch.elapsedMilliseconds}ms, '
            'total=${downloadStopwatch.elapsedMilliseconds}ms.',
      );
      return targetFile;
    } catch (e, st) {
      try {
        final appDir = await SettingsService().getAppDirectory();
        final tempFile = File(
          '${appDir.path}/cached_wallpapers/${wallpaper.filename}.tmp',
        );
        if (await tempFile.exists()) await tempFile.delete();
      } catch (cleanupError, cleanupStack) {
        logError(
          'FirebaseService',
          'Failed to remove partial wallpaper cache file',
          cleanupError,
          cleanupStack,
        );
      }

      logError(
        'FirebaseService',
        'Failed to download wallpaper: ${wallpaper.url}',
        e,
        st,
      );
      debugPrint(
        '[FirebaseService] ERROR: Unhandled exception in downloadWallpaper: $e\nStacktrace: $st',
      );
      debugPrint('[FirebaseService] EXIT downloadWallpaper() - EXCEPTION');
      return null;
    }
  }

  static void _markWallpaperCached(String filename) {
    _cachedWallpaperFilenames.add(filename);
    _validatedCachedWallpapers.add(filename);
    _wallpaperFileValidations.remove(filename);
  }

  /// Synchronously returns the cached thumbnail file if already on disk or in memory.
  File? getCachedThumbnailSync(String url) {
    if (!FirebaseWallpaper.isValidThumbnailUrl(url) ||
        _isThumbnailCoolingDown(url)) {
      return null;
    }
    final optUrl = FirebaseWallpaper.toOptimizedThumbnailUrl(url);
    return _cachedThumbnailFileMap[optUrl] ?? _cachedThumbnailFileMap[url];
  }

  /// Asynchronously pre-fetches thumbnails for all wallpapers without blocking the UI.
  static final Set<String> _prefetchInFlight = {};
  static const int _thumbnailConcurrency = 3;
  static const int _thumbnailMaxAttempts = 3;
  static const int _maxThumbnailBytes = 6 * 1024 * 1024;

  static List<String> _thumbnailUrls(List<FirebaseWallpaper> wallpapers) =>
      wallpapers
          .map((wallpaper) {
            final t =
                wallpaper.thumbnailUrl ??
                (!wallpaper.isVideo ? wallpaper.url : null);
            return t != null
                ? FirebaseWallpaper.toOptimizedThumbnailUrl(t)
                : null;
          })
          .whereType<String>()
          .where(FirebaseWallpaper.isValidThumbnailUrl)
          .toSet()
          .toList();

  static Future<void> _acquireThumbnailSlot() async {
    while (_activeThumbnailDownloads >= _thumbnailConcurrency) {
      final waiter = Completer<void>();
      _thumbnailSlotWaiters.add(waiter);
      await waiter.future;
    }
    _activeThumbnailDownloads++;
  }

  static void _releaseThumbnailSlot() {
    _activeThumbnailDownloads--;
    if (_thumbnailSlotWaiters.isNotEmpty) {
      _thumbnailSlotWaiters.removeAt(0).complete();
    }
  }

  Future<void> prefetchThumbnails(List<String> urls, {int maxCount = 8}) async {
    try {
      final pending = urls
          .map(FirebaseWallpaper.toOptimizedThumbnailUrl)
          .where(FirebaseWallpaper.isValidThumbnailUrl)
          .where((url) => getCachedThumbnailSync(url) == null)
          .where((url) => !_prefetchInFlight.contains(url))
          .take(maxCount)
          .toSet()
          .toList();
      _prefetchInFlight.addAll(pending);
      var nextIndex = 0;
      Future<void> worker() async {
        while (true) {
          if (nextIndex >= pending.length) return;
          final url = pending[nextIndex++];

          try {
            await downloadThumbnailToCache(url);
          } catch (error, stackTrace) {
            logError(
              'FirebaseService',
              'Thumbnail prefetch failed: $url',
              error,
              stackTrace,
            );
          } finally {
            _prefetchInFlight.remove(url);
          }
        }
      }

      await Future.wait(
        List.generate(
          pending.length < _thumbnailConcurrency
              ? pending.length
              : _thumbnailConcurrency,
          (_) => worker(),
        ),
      );
    } catch (error, stackTrace) {
      logError(
        'FirebaseService',
        'Unable to schedule thumbnail prefetch',
        error,
        stackTrace,
      );
    }
  }

  /// Downloads a remote image thumbnail to the cache directory using native client.
  Future<File?> downloadThumbnailToCache(String url) async {
    final targetUrl = FirebaseWallpaper.toOptimizedThumbnailUrl(url);
    if (!FirebaseWallpaper.isValidThumbnailUrl(targetUrl) ||
        _isThumbnailCoolingDown(targetUrl)) {
      return null;
    }
    final cached = getCachedThumbnailSync(targetUrl);
    if (cached != null) return cached;

    final existing = _thumbnailDownloads[targetUrl];
    if (existing != null) return existing;

    final download = _downloadThumbnailWithSlot(targetUrl);
    _thumbnailDownloads[targetUrl] = download;
    try {
      final res = await download;
      if (res != null) {
        _cachedThumbnailFileMap[url] = res;
        _cachedThumbnailFileMap[targetUrl] = res;
      }
      return res;
    } finally {
      if (identical(_thumbnailDownloads[targetUrl], download)) {
        _thumbnailDownloads.remove(targetUrl);
      }
    }
  }

  Future<File?> _downloadThumbnailWithSlot(String url) async {
    await _acquireThumbnailSlot();
    try {
      return await _downloadThumbnailToCache(url);
    } finally {
      _releaseThumbnailSlot();
    }
  }

  Future<File?> _downloadThumbnailToCache(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (!FirebaseWallpaper.isValidThumbnailUrl(url) || uri == null) {
        debugPrint(
          '[FirebaseService] Invalid thumbnail URL: $url',
        );
        return null;
      }

      final appDir = await SettingsService().getAppDirectory();
      final cacheDir = Directory('${appDir.path}/cached_thumbnails');
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }

      // Create a unique filename based on hash of URL
      final filename = _thumbnailFilename(url);
      final targetFile = File('${cacheDir.path}/$filename');

      if (await targetFile.exists()) {
        final len = await targetFile.length();
        if (len > 400 * 1024) {
          try {
            await targetFile.delete();
          } catch (_) {}
        } else if (len > 0) {
          _cachedThumbnailFileMap[url] = targetFile;
          return targetFile;
        }
      }

      debugPrint('[FirebaseService] STATE: Downloading thumbnail from CDN...');
      final tempFile = File('${targetFile.path}.tmp');
      Object? lastError;
      for (var attempt = 1; attempt <= _thumbnailMaxAttempts; attempt++) {
        try {
          final request = await _openRequestRobustly(
            'GET',
            uri,
          ).timeout(const Duration(seconds: 8));
          final response = await _closeRequestWithTimeout(
            request,
            const Duration(seconds: 8),
          );
          if (response.statusCode != HttpStatus.ok) {
            await response.drain();
            final error = HttpException(
              'Thumbnail request failed with HTTP ${response.statusCode}.',
              uri: uri,
            );
            if (response.statusCode < 500 &&
                response.statusCode != 408 &&
                response.statusCode != 429) {
              _markThumbnailFailure(url);
              return null;
            }
            throw error;
          }
          final contentType = response.headers.contentType?.mimeType
              .toLowerCase();
          if (contentType == null || !contentType.startsWith('image/')) {
            await response.drain();
            _markThumbnailFailure(url);
            return null;
          }
          final bytes = await response
              .fold<BytesBuilder>(BytesBuilder(), (builder, chunk) {
                if (builder.length + chunk.length > _maxThumbnailBytes) {
                  throw const FormatException(
                    'Thumbnail exceeds the 20 MB limit.',
                  );
                }
                return builder..add(chunk);
              })
              .timeout(const Duration(seconds: 15))
              .then((builder) => builder.takeBytes());
          if (!_looksLikeImage(bytes)) {
            _markThumbnailFailure(url);
            return null;
          }
          await tempFile.writeAsBytes(bytes, flush: true);
          if (await targetFile.exists()) await targetFile.delete();
          await tempFile.rename(targetFile.path);
          _cachedThumbnailFileMap[url] = targetFile;
          return targetFile;
        } catch (error) {
          lastError = error;
          if (attempt < _thumbnailMaxAttempts &&
              _isTransientThumbnailError(error)) {
            await Future.delayed(
              Duration(milliseconds: 300 * (1 << (attempt - 1))),
            );
          } else {
            break;
          }
        }
      }
      if (lastError != null) throw lastError;
      return null;
    } catch (e, st) {
      _markThumbnailFailure(url);
      try {
        final appDir = await SettingsService().getAppDirectory();
        final tempFile = File(
          '${appDir.path}/cached_thumbnails/${_thumbnailFilename(url)}.tmp',
        );
        if (await tempFile.exists()) await tempFile.delete();
      } catch (cleanupError, cleanupStack) {
        logError(
          'FirebaseService',
          'Failed to remove partial thumbnail cache file',
          cleanupError,
          cleanupStack,
        );
      }
      logError('FirebaseService', 'Failed to download thumbnail: $url', e, st);
      debugPrint(
        '[FirebaseService] ERROR: Unhandled exception in downloadThumbnailToCache: $e\nStacktrace: $st',
      );
      debugPrint(
        '[FirebaseService] EXIT downloadThumbnailToCache() - EXCEPTION',
      );
      return null;
    }
  }

  static bool _isTransientThumbnailError(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      (error is HttpException &&
          RegExp(r'HTTP (408|429|5\d\d)').hasMatch(error.message));

  static bool _looksLikeImage(List<int> bytes) {
    if (bytes.length < 12) return false;
    final png =
        bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a;
    final jpeg = bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff;
    final gif = String.fromCharCodes(bytes.take(3)) == 'GIF';
    final webp =
        String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
        String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP';
    final bmp = bytes[0] == 0x42 && bytes[1] == 0x4d;
    return png || jpeg || gif || webp || bmp;
  }

  Future<void> invalidateThumbnailCache(String url) async {
    try {
      _cachedThumbnailFileMap.remove(url);
      _thumbnailFailureUntil.remove(url);
      final appDir = await SettingsService().getAppDirectory();
      final cacheFile = File(
        '${appDir.path}/cached_thumbnails/${_thumbnailFilename(url)}',
      );
      if (await cacheFile.exists()) await cacheFile.delete();
    } catch (e, st) {
      logError(
        'FirebaseService',
        'Failed to invalidate thumbnail cache',
        e,
        st,
      );
    }
  }

  /// Deduplicates a list of wallpapers by ID, URL, and (for video wallpapers) by URL or name.
  /// Preserves the entry with the richer metadata (e.g. non-null thumbnail URL or description).
  static List<FirebaseWallpaper> deduplicateWallpapers(
    List<FirebaseWallpaper> wallpapers,
  ) {
    final List<FirebaseWallpaper> result = [];
    final seenIds = <String>{};
    final seenUrls = <String>{};
    final seenVideoNames = <String>{};

    for (final wp in wallpapers) {
      if (!wp.hasUsableSource) continue;
      final idKey = wp.id.trim();
      final urlKey = wp.url.trim().toLowerCase();
      final isVideo =
          wp.type == 'video' ||
          wp.url.endsWith('.mp4') ||
          wp.url.endsWith('.webm') ||
          wp.url.endsWith('.mkv') ||
          wp.url.endsWith('.mov') ||
          wp.category.toLowerCase().contains('video') ||
          wp.category.toLowerCase().contains('live');
      final nameKey = wp.name.trim().toLowerCase();

      final isIdDuplicate = idKey.isNotEmpty && seenIds.contains(idKey);
      final isUrlDuplicate = urlKey.isNotEmpty && seenUrls.contains(urlKey);
      final isVideoNameDuplicate =
          isVideo && nameKey.isNotEmpty && seenVideoNames.contains(nameKey);

      if (isIdDuplicate || isUrlDuplicate || isVideoNameDuplicate) {
        // If existing record lacked thumbnail/description but this duplicate has it, replace it
        if ((wp.thumbnailUrl?.isNotEmpty ?? false) ||
            (wp.description?.isNotEmpty ?? false)) {
          final existingIdx = result.indexWhere(
            (existing) =>
                (idKey.isNotEmpty && existing.id.trim() == idKey) ||
                (urlKey.isNotEmpty &&
                    existing.url.trim().toLowerCase() == urlKey) ||
                (isVideo &&
                    nameKey.isNotEmpty &&
                    existing.name.trim().toLowerCase() == nameKey),
          );
          if (existingIdx != -1) {
            final existing = result[existingIdx];
            final existingHasThumbnail =
                existing.thumbnailUrl?.isNotEmpty ?? false;
            if (!existingHasThumbnail &&
                (wp.thumbnailUrl?.isNotEmpty ?? false)) {
              result[existingIdx] = wp;
            }
          }
        }
        continue;
      }

      if (idKey.isNotEmpty) seenIds.add(idKey);
      if (urlKey.isNotEmpty) seenUrls.add(urlKey);
      if (isVideo && nameKey.isNotEmpty) seenVideoNames.add(nameKey);
      result.add(wp);
    }

    return result;
  }

  List<FirebaseWallpaper> _getFallbackCuratedWallpapers() {
    final list = [
      FirebaseWallpaper(
        id: 'cyberpunk',
        name: 'Cyberpunk Skyline',
        category: 'Cyberpunk',
        type: 'static',
        url: 'asset://assets/cyberpunk.png',
        description:
            'A futuristic city street glowing with neon signs under a foggy midnight rain.',
      ),
      FirebaseWallpaper(
        id: 'aurora',
        name: 'Aurora Borealis',
        category: 'Nature',
        type: 'static',
        url: 'asset://assets/aurora.png',
        description:
            'Vibrant green aurora curtains dancing over snow-capped mountains in Norway.',
      ),
      FirebaseWallpaper(
        id: 'forest',
        name: 'Mystic Forest',
        category: 'Nature',
        type: 'static',
        url: 'asset://assets/forest.png',
        description:
            'Sunbeams filtering through deep green forest foliage in a peaceful, quiet morning.',
      ),
      FirebaseWallpaper(
        id: 'nebula',
        name: 'Cosmic Nebula',
        category: 'Space',
        type: 'static',
        url: 'asset://assets/nebula.png',
        description:
            'An active interstellar cloud of colorful gas, dust, and newborn stars deep in the galaxy.',
      ),
      FirebaseWallpaper(
        id: 'desert_sunset',
        name: 'Desert Sunset',
        category: 'Minimalist',
        type: 'static',
        url: 'asset://assets/desert_sunset.png',
        description:
            'A clean, serene landscape of desert sand dunes painted in pastel orange and pink tones during sunset.',
      ),
      FirebaseWallpaper(
        id: 'cosmic_dust',
        name: 'Cosmic Dust',
        category: 'Space',
        type: 'static',
        url: 'asset://assets/cosmic_dust.png',
        description:
            'Deep galaxy dust particles shimmering under stellar ultraviolet light.',
      ),
      FirebaseWallpaper(
        id: 'golden_hour',
        name: 'Golden Hour Mountain',
        category: 'Nature',
        type: 'static',
        url: 'asset://assets/golden_hour.png',
        description:
            'Warm golden sunlight touching rocky alpine mountain summits at twilight.',
      ),
      FirebaseWallpaper(
        id: 'ocean_breeze',
        name: 'Ocean Breeze',
        category: 'Nature',
        type: 'static',
        url: 'asset://assets/ocean_breeze.png',
        description:
            'Gentle turquoise ocean waves rolling onto a golden sand shore under noon sunlight.',
      ),
    ];
    return deduplicateWallpapers(list);
  }

  /// Submits a bug report to the Firebase Realtime Database.
  Future<bool> submitBugReport(Map<String, dynamic> reportData) async {
    debugPrint('[FirebaseService] ENTER submitBugReport()');
    try {
      final payload = Map<String, dynamic>.from(reportData);
      payload['badge'] = 'PRO';
      payload['appType'] = 'Pro';
      payload['userType'] = 'Pro';
      payload['isPro'] = true;
      payload['edition'] = 'WallSync Pro';
      final jsonBody = jsonEncode(payload);
      final random = Random.secure();
      final reportId =
          '${DateTime.now().microsecondsSinceEpoch}_${List.generate(12, (_) => random.nextInt(36).toRadixString(36)).join()}';

      for (final path in ['reports_pro', 'reports']) {
        try {
          final request = await _openRequestRobustly(
            'PUT',
            Uri.parse('$databaseUrl/$path/$reportId.json'),
          ).timeout(const Duration(seconds: 15));
          request.headers.set(
            HttpHeaders.contentTypeHeader,
            'application/json; charset=utf-8',
          );
          request.add(utf8.encode(jsonBody));
          final response = await _closeRequestWithTimeout(
            request,
            const Duration(seconds: 15),
          );

          if (response.statusCode == 200 || response.statusCode == 201) {
            await response.drain();
            debugPrint('[FirebaseService] EXIT submitBugReport() - SUCCESS ($path)');
            return true;
          }
          await response.drain();
        } catch (subError) {
          if (path == 'reports') {
            rethrow;
          }
        }
      }
      logError(
        'FirebaseService',
        'Bug report submission failed for both reports_pro and reports.',
      );
      return false;
    } catch (e, st) {
      logError('FirebaseService', 'Failed to submit bug report', e, st);
      debugPrint(
        '[FirebaseService] ERROR: Unhandled exception in submitBugReport: $e\nStacktrace: $st',
      );
      debugPrint('[FirebaseService] EXIT submitBugReport() - EXCEPTION');
      return false;
    }
  }

  Future<String> submitWallpaperReport({
    required String wallpaperId,
    required String wallpaperTitle,
    required String wallpaperType,
    required String wallpaperResolution,
    required String userEmail,
    required String description,
  }) {
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              wallpaperId,
              wallpaperTitle,
              wallpaperType,
              wallpaperResolution,
              userEmail.trim(),
              description.trim(),
            ]),
          ),
        )
        .toString();
    final pending = _pendingReportSubmissions[fingerprint];
    if (pending != null) return pending;

    late final Future<String> submission;
    submission =
        _submitWallpaperReport(
          wallpaperId: wallpaperId,
          wallpaperTitle: wallpaperTitle,
          wallpaperType: wallpaperType,
          wallpaperResolution: wallpaperResolution,
          userEmail: userEmail,
          description: description,
        ).whenComplete(() {
          if (identical(_pendingReportSubmissions[fingerprint], submission)) {
            _pendingReportSubmissions.remove(fingerprint);
          }
        });
    _pendingReportSubmissions[fingerprint] = submission;
    return submission;
  }

  Future<String> _submitWallpaperReport({
    required String wallpaperId,
    required String wallpaperTitle,
    required String wallpaperType,
    required String wallpaperResolution,
    required String userEmail,
    required String description,
  }) async {
    final reportId = List.generate(
      32,
      (_) => Random.secure().nextInt(16).toRadixString(16),
    ).join();
    final report = <String, Object?>{
      'reportId': reportId,
      'wallpaperId': wallpaperId,
      'wallpaperTitle': wallpaperTitle,
      'wallpaperType': wallpaperType,
      'wallpaperResolution': wallpaperResolution,
      'userEmail': userEmail.trim(),
      'description': description.trim(),
      'status': 'pending',
      'createdAt': {'.sv': 'timestamp'},
      'updatedAt': {'.sv': 'timestamp'},
    };
    await _writeWallpaperReport('wallpaper_reports_pro', reportId, report);
    return reportId;
  }

  Future<void> _writeWallpaperReport(
    String path,
    String reportId,
    Map<String, Object?> report,
  ) async {
    final request = await _openRequestRobustly(
      'PUT',
      Uri.parse('$_databaseUrl/$path/$reportId.json'),
      client: _httpClient,
    ).timeout(const Duration(seconds: 15));
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/json; charset=utf-8',
    );
    request.add(utf8.encode(jsonEncode(report)));
    final response = await _closeRequestWithTimeout(
      request,
      const Duration(seconds: 15),
    );
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < HttpStatus.ok ||
        response.statusCode >= HttpStatus.multipleChoices) {
      logWarning(
        'FirebaseService',
        'Report submission to $path failed with HTTP ${response.statusCode}.',
      );
      var detail = '';
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map && decoded['error'] is String) {
          detail = ': ${decoded['error']}';
        } else if (decoded is String && decoded.isNotEmpty) {
          detail = ': $decoded';
        }
      } on FormatException {
        if (body.trim().isNotEmpty) detail = ': ${body.trim()}';
      }
      throw HttpException(
        'Firebase rejected the report (${response.statusCode})$detail.',
      );
    }
    // Realtime Database REST PUT success is acknowledged with HTTP 200 and
    // commonly returns JSON null; the status code is the write acknowledgement.
    logInfo(
      'FirebaseService',
      'Wallpaper report write acknowledged at $path/$reportId '
          '(HTTP ${response.statusCode}).',
    );
  }

  Future<Map<String, dynamic>?> checkUpdate() {
    final pending = _inFlightCheckUpdate;
    if (pending != null) return pending;
    final operation = _checkUpdateInternal();
    _inFlightCheckUpdate = operation;
    return operation.whenComplete(() {
      if (identical(_inFlightCheckUpdate, operation)) {
        _inFlightCheckUpdate = null;
      }
    });
  }

  Future<Map<String, dynamic>?> _checkUpdateInternal() async {
    for (int i = 0; i < 2; i++) {
      try {
        final request = await _openRequestRobustly(
          'GET',
          Uri.parse('$databaseUrl/update_pro.json'),
        ).timeout(const Duration(seconds: 5));
        final response = await _closeRequestWithTimeout(
          request,
          const Duration(seconds: 5),
        );

        if (response.statusCode == 200) {
          final responseBody = await response.transform(utf8.decoder).join();
          if (responseBody.trim().isEmpty || responseBody == 'null') {
            debugPrint(
              '[FirebaseService] Update check: No update manifest configured on server (null/empty).',
            );
            return null;
          }
          final data = json.decode(responseBody);
          if (data is Map) {
            final versionCode = data['versionCode'];
            debugPrint(
              '[FirebaseService] Update check SUCCESS: Remote version payload received (versionCode: $versionCode).',
            );
            return Map<String, dynamic>.from(data);
          } else {
            debugPrint(
              '[FirebaseService] Update check INVALID RESPONSE: Expected JSON object but got ${data.runtimeType}.',
            );
            return null;
          }
        } else {
          debugPrint(
            '[FirebaseService] Update check REQUEST FAILED: HTTP ${response.statusCode} from update endpoint.',
          );
          return null;
        }
      } on TimeoutException catch (e) {
        if (i == 1) {
          debugPrint(
            '[FirebaseService] Update check TIMED OUT after retrying: $e',
          );
        } else {
          debugPrint(
            '[FirebaseService] Update check timed out on attempt 1. Retrying...',
          );
          await Future.delayed(const Duration(seconds: 1));
        }
      } catch (e, st) {
        if (i == 1) {
          debugPrint(
            '[FirebaseService] Update check REQUEST FAILED: $e\nStacktrace: $st',
          );
        } else {
          debugPrint(
            '[FirebaseService] Update check failed on attempt 1: $e. Retrying...',
          );
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    }
    return null;
  }
}
