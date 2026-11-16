import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'settings_service.dart';

/// Supported cloud asset types from Croenix/Font repository.
enum CloudAssetType {
  gif,
  icon,
}

/// Represents an individual cloud asset item (either an animated GIF icon or a PNG/SVG icon).
class CloudAssetItem {
  final String fileName;
  final String folder; // 'Gifs' or 'Icons'
  final String sha;
  final int fileSize;
  final String downloadUrl;
  final CloudAssetType assetType;
  final String category;
  final String designer;

  const CloudAssetItem({
    required this.fileName,
    required this.folder,
    this.sha = '',
    this.fileSize = 0,
    required this.downloadUrl,
    required this.assetType,
    this.category = 'General',
    this.designer = 'Croenix Studio',
  });

  factory CloudAssetItem.fromGitHubJson(
    Map<String, dynamic> json,
    String folder,
  ) {
    final name = json['name']?.toString() ?? '';
    final isGif = name.toLowerCase().endsWith('.gif');
    final type = isGif ? CloudAssetType.gif : CloudAssetType.icon;
    final downloadUrl = json['download_url']?.toString() ??
        '${CustomAssetService.rawBaseUrl}/$folder/$name';

    return CloudAssetItem(
      fileName: name,
      folder: folder,
      sha: json['sha']?.toString() ?? '',
      fileSize: (json['size'] as num?)?.toInt() ?? 0,
      downloadUrl: downloadUrl,
      assetType: type,
      category: _inferCategory(name, folder),
    );
  }

  factory CloudAssetItem.fromJson(Map<String, dynamic> json) {
    final folder = json['folder']?.toString() ?? 'Icons';
    final name = json['file_name']?.toString() ?? json['name']?.toString() ?? '';
    final typeStr = json['asset_type']?.toString() ?? 'icon';
    final isGif = name.toLowerCase().endsWith('.gif') || typeStr == 'gif';
    final assetType = isGif ? CloudAssetType.gif : CloudAssetType.icon;
    final size = (json['file_size'] as num?)?.toInt() ??
        (json['size'] as num?)?.toInt() ??
        0;

    return CloudAssetItem(
      fileName: name,
      folder: folder,
      sha: json['sha']?.toString() ?? '',
      fileSize: size,
      downloadUrl: json['download_url']?.toString() ?? '',
      assetType: assetType,
      category: json['category']?.toString() ?? _inferCategory(name, folder),
      designer: json['designer']?.toString() ?? 'Croenix Studio',
    );
  }

  Map<String, dynamic> toJson() => {
    'file_name': fileName,
    'folder': folder,
    'sha': sha,
    'file_size': fileSize,
    'download_url': downloadUrl,
    'asset_type': assetType == CloudAssetType.gif ? 'gif' : 'icon',
    'category': category,
    'designer': designer,
  };

  static String _inferCategory(String name, String folder) {
    final lower = name.toLowerCase();
    if (lower.contains('rain') || lower.contains('drop')) {
      return 'Rain & Weather';
    }
    if (lower.contains('sun') || lower.contains('sunny') || lower.contains('day')) {
      return 'Sun & Daylight';
    }
    if (lower.contains('cloud')) {
      return 'Clouds & Skies';
    }
    if (lower.contains('moon') || lower.contains('star')) {
      return 'Celestial & Night';
    }
    if (lower.contains('thunder') || lower.contains('storm')) {
      return 'Storm & Lightning';
    }
    if (lower.contains('wind')) {
      return 'Wind & Air';
    }
    return folder == 'Gifs' ? 'Animated Icons' : 'Static Icons';
  }

  String get displayName {
    final dotIndex = fileName.lastIndexOf('.');
    final base = dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
    final words = base
        .replaceAll(RegExp(r'[-_]'), ' ')
        .split(' ')
        .where((w) => w.isNotEmpty);
    return words
        .map((w) => w[0].toUpperCase() + (w.length > 1 ? w.substring(1) : ''))
        .join(' ');
  }

  String get fileExtension {
    final dotIndex = fileName.lastIndexOf('.');
    if (dotIndex > 0 && dotIndex < fileName.length - 1) {
      return fileName.substring(dotIndex + 1).toLowerCase();
    }
    return '';
  }

  bool get isSvg => fileExtension == 'svg';
  bool get isGif => fileExtension == 'gif';
  bool get isPng => fileExtension == 'png';

  String get formattedSize {
    if (fileSize <= 0) return '0 B';
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  bool get isDownloaded => CustomAssetService.instance.isAssetDownloaded(this);
  String? get localPath => CustomAssetService.instance.getAssetLocalPath(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CloudAssetItem &&
          runtimeType == other.runtimeType &&
          fileName == other.fileName &&
          folder == other.folder;

  @override
  int get hashCode => fileName.hashCode ^ folder.hashCode;
}

/// Batch download progress tracking for cloud assets.
class CloudAssetBatchProgress {
  final int totalFiles;
  final int completedFiles;
  final String currentFileName;
  final double fraction;
  final bool isDownloading;
  final bool isCancelled;
  final String? error;

  const CloudAssetBatchProgress({
    this.totalFiles = 0,
    this.completedFiles = 0,
    this.currentFileName = '',
    this.fraction = 0.0,
    this.isDownloading = false,
    this.isCancelled = false,
    this.error,
  });

  CloudAssetBatchProgress copyWith({
    int? totalFiles,
    int? completedFiles,
    String? currentFileName,
    double? fraction,
    bool? isDownloading,
    bool? isCancelled,
    String? error,
  }) {
    return CloudAssetBatchProgress(
      totalFiles: totalFiles ?? this.totalFiles,
      completedFiles: completedFiles ?? this.completedFiles,
      currentFileName: currentFileName ?? this.currentFileName,
      fraction: fraction ?? this.fraction,
      isDownloading: isDownloading ?? this.isDownloading,
      isCancelled: isCancelled ?? this.isCancelled,
      error: error ?? this.error,
    );
  }
}

/// Core service that manages animating GIF icons and PNG/SVG icons from
/// the Croenix/Font repository, provides local disk persistence, pre-download
/// thumbnail caching, startup update checks, and strict usability gating.
class CustomAssetService extends ChangeNotifier {
  static final CustomAssetService instance = CustomAssetService._internal();
  factory CustomAssetService() => instance;
  CustomAssetService._internal();

  static const String repoUrl = 'https://github.com/Croenix/Font.git';
  static const String rawBaseUrl =
      'https://raw.githubusercontent.com/Croenix/Font/main';
  static const String gifsRawBaseUrl = '$rawBaseUrl/Gifs';
  static const String iconsRawBaseUrl = '$rawBaseUrl/Icons';
  static const String githubGifsApiUrl =
      'https://api.github.com/repos/Croenix/Font/contents/Gifs';
  static const String githubIconsApiUrl =
      'https://api.github.com/repos/Croenix/Font/contents/Icons';
  static const String githubCommitApiUrl =
      'https://api.github.com/repos/Croenix/Font/commits/main';

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  Directory? _customAssetsDirectory;
  Directory? _gifsFolder;
  Directory? _iconsFolder;
  Directory? _previewFolder;

  List<CloudAssetItem> _assets = [];
  List<CloudAssetItem> get assets => List.unmodifiable(_assets);

  final Set<String> _downloadedKeys = <String>{}; // key: '$folder/$fileName'

  bool _isCheckingUpdates = false;
  bool get isCheckingUpdates => _isCheckingUpdates;

  bool _hasUpdateAvailable = false;
  bool get hasUpdateAvailable => _hasUpdateAvailable;

  int _newAssetsCount = 0;
  int get newAssetsCount => _newAssetsCount;

  DateTime? _lastCheckedAt;
  DateTime? get lastCheckedAt => _lastCheckedAt;

  CloudAssetBatchProgress _batchProgress = const CloudAssetBatchProgress();
  CloudAssetBatchProgress get batchProgress => _batchProgress;

  bool _cancelRequested = false;

  /// Default bundled manifest reflecting the remote repository's contents.
  /// Ensures instant offline availability and resilience against GitHub API rate-limits.
  static const List<CloudAssetItem> _bundledAssets = [
    // ── Gifs Folder ──────────────────────────────────────────────────────────
    CloudAssetItem(
      fileName: 'cloud.gif',
      folder: 'Gifs',
      sha: '6e024070ab0dfccd3749e16dd179bf719a6eaed9',
      fileSize: 141643,
      downloadUrl: '$rawBaseUrl/Gifs/cloud.gif',
      assetType: CloudAssetType.gif,
      category: 'Clouds & Skies',
    ),
    CloudAssetItem(
      fileName: 'outline cloud.gif',
      folder: 'Gifs',
      sha: '01df6e1540bb5d92a7cc03a4835ea8aa02da3818',
      fileSize: 53287,
      downloadUrl: '$rawBaseUrl/Gifs/outline%20cloud.gif',
      assetType: CloudAssetType.gif,
      category: 'Clouds & Skies',
    ),
    CloudAssetItem(
      fileName: 'outline moon stars.gif',
      folder: 'Gifs',
      sha: '0805da970fbb94ebc7e65ffd1ec43555806ccf8c',
      fileSize: 229351,
      downloadUrl: '$rawBaseUrl/Gifs/outline%20moon%20stars.gif',
      assetType: CloudAssetType.gif,
      category: 'Celestial & Night',
    ),
    CloudAssetItem(
      fileName: 'rain drop.gif',
      folder: 'Gifs',
      sha: '5953db272c4f8826e15abc8e165d0184b78ba19b',
      fileSize: 107565,
      downloadUrl: '$rawBaseUrl/Gifs/rain%20drop.gif',
      assetType: CloudAssetType.gif,
      category: 'Rain & Weather',
    ),
    CloudAssetItem(
      fileName: 'stars hover.gif',
      folder: 'Gifs',
      sha: 'e699888ffed4f6c488a2ae9a07deb66e215c7466',
      fileSize: 233383,
      downloadUrl: '$rawBaseUrl/Gifs/stars%20hover.gif',
      assetType: CloudAssetType.gif,
      category: 'Celestial & Night',
    ),
    CloudAssetItem(
      fileName: 'Woman enjoying Rain Day.gif',
      folder: 'Gifs',
      sha: '1d6f45b5dad383eaebd4fbb95eaed79a2c800d3c',
      fileSize: 22091346,
      downloadUrl: '$rawBaseUrl/Gifs/Woman%20enjoying%20Rain%20Day.gif',
      assetType: CloudAssetType.gif,
      category: 'Atmosphere & Nature',
    ),

    // ── Icons Folder ─────────────────────────────────────────────────────────
    CloudAssetItem(
      fileName: 'rain.png',
      folder: 'Icons',
      sha: 'a7de8c8052102e6e2cc7b423660ffd95e3bc7b4d',
      fileSize: 20926,
      downloadUrl: '$rawBaseUrl/Icons/rain.png',
      assetType: CloudAssetType.icon,
      category: 'Rain & Weather',
    ),
    CloudAssetItem(
      fileName: 'sun.png',
      folder: 'Icons',
      sha: 'aff51547a1753d5bfbf7442ab732ea43b77c8b2b',
      fileSize: 30442,
      downloadUrl: '$rawBaseUrl/Icons/sun.png',
      assetType: CloudAssetType.icon,
      category: 'Sun & Daylight',
    ),
    CloudAssetItem(
      fileName: 'thunder.png',
      folder: 'Icons',
      sha: '3827a2a31b44a8e78e030206e7d4aabd65587a94',
      fileSize: 18344,
      downloadUrl: '$rawBaseUrl/Icons/thunder.png',
      assetType: CloudAssetType.icon,
      category: 'Storm & Lightning',
    ),
    CloudAssetItem(
      fileName: 'windy-rain.png',
      folder: 'Icons',
      sha: '2daf757d7d7e664e782bfec32d78804dcc298b2b',
      fileSize: 25678,
      downloadUrl: '$rawBaseUrl/Icons/windy-rain.png',
      assetType: CloudAssetType.icon,
      category: 'Wind & Air',
    ),
    CloudAssetItem(
      fileName: 'windy.png',
      folder: 'Icons',
      sha: '96e89d1a46fb098e20c8da8954e56e1b8f4b8e2e',
      fileSize: 21340,
      downloadUrl: '$rawBaseUrl/Icons/windy.png',
      assetType: CloudAssetType.icon,
      category: 'Wind & Air',
    ),
  ];

  /// Initialize local custom assets directory, scan downloaded items, and restore metadata.
  /// Set [resetLocalState] to true when a test or a fresh startup should ignore any stale
  /// downloaded files left in the app data directory.
  Future<void> init({bool resetLocalState = false}) async {
    if (_isInitialized && !resetLocalState) return;

    _isInitialized = false;
    _assets = List<CloudAssetItem>.from(_bundledAssets);
    _downloadedKeys.clear();

    try {
      final appDir = await SettingsService().getAppDirectory();
      _customAssetsDirectory = Directory('${appDir.path}\\custom_assets');
      _gifsFolder = Directory('${_customAssetsDirectory!.path}\\Gifs');
      _iconsFolder = Directory('${_customAssetsDirectory!.path}\\Icons');
      _previewFolder = Directory('${_customAssetsDirectory!.path}\\.previews');

      if (resetLocalState && await _customAssetsDirectory!.exists()) {
        await _customAssetsDirectory!.delete(recursive: true);
      }

      if (!await _customAssetsDirectory!.exists()) {
        await _customAssetsDirectory!.create(recursive: true);
      }
      if (!await _gifsFolder!.exists()) {
        await _gifsFolder!.create(recursive: true);
      }
      if (!await _iconsFolder!.exists()) {
        await _iconsFolder!.create(recursive: true);
      }
      if (!await _previewFolder!.exists()) {
        await _previewFolder!.create(recursive: true);
      }

      await _loadLocalOrBundledAssets();
      await _scanDownloadedFiles();

      _isInitialized = true;
      notifyListeners();
    } catch (e, st) {
      logError('CustomAssetService', 'Failed to initialize CustomAssetService', e, st);
    }
  }

  /// Automatically called during app startup to check if new Gifs or Icons have been published.
  Future<void> checkForUpdatesOnStartup() async {
    if (!_isInitialized) await init();
    try {
      await checkForUpdates(silent: true);
    } catch (e) {
      logWarning('CustomAssetService', 'Startup asset update check skipped: $e');
    }
  }

  /// Load assets from locally cached metadata JSON or fall back to the bundled list.
  Future<void> _loadLocalOrBundledAssets() async {
    final metaFile = File('${_customAssetsDirectory!.path}\\asset_manifest.json');
    if (await metaFile.exists()) {
      try {
        final content = await metaFile.readAsString();
        final jsonList = jsonDecode(content) as List<dynamic>;
        _assets = jsonList
            .whereType<Map<String, dynamic>>()
            .map(CloudAssetItem.fromJson)
            .toList();
        return;
      } catch (e) {
        logWarning('CustomAssetService', 'Failed to parse local asset_manifest.json: $e');
      }
    }

    _assets = List.from(_bundledAssets);
  }

  /// Persist current asset manifest to local storage.
  Future<void> _saveAssetManifest() async {
    if (_customAssetsDirectory == null) return;
    try {
      final metaFile = File('${_customAssetsDirectory!.path}\\asset_manifest.json');
      final jsonList = _assets.map((a) => a.toJson()).toList();
      await metaFile.writeAsString(jsonEncode(jsonList));
    } catch (e) {
      logWarning('CustomAssetService', 'Failed to save asset_manifest.json: $e');
    }
  }

  /// Scans the local Gifs and Icons folders to detect downloaded files.
  Future<void> _scanDownloadedFiles() async {
    _downloadedKeys.clear();

    if (_gifsFolder != null && await _gifsFolder!.exists()) {
      await for (final entity in _gifsFolder!.list(followLinks: false)) {
        if (entity is File) {
          final fileName = entity.uri.pathSegments.last;
          if (fileName.isNotEmpty && !fileName.startsWith('.')) {
            _downloadedKeys.add('Gifs/$fileName');
          }
        }
      }
    }

    if (_iconsFolder != null && await _iconsFolder!.exists()) {
      await for (final entity in _iconsFolder!.list(followLinks: false)) {
        if (entity is File) {
          final fileName = entity.uri.pathSegments.last;
          if (fileName.isNotEmpty && !fileName.startsWith('.')) {
            _downloadedKeys.add('Icons/$fileName');
          }
        }
      }
    }

    notifyListeners();
  }

  /// Checks if a specific asset is already downloaded and usable locally.
  bool isAssetDownloaded(CloudAssetItem item) {
    return _downloadedKeys.contains('${item.folder}/${item.fileName}');
  }

  /// Returns the absolute local file path of a downloaded asset, or null if not downloaded.
  String? getAssetLocalPath(CloudAssetItem item) {
    if (!isAssetDownloaded(item)) return null;
    final parentDir = item.folder == 'Gifs' ? _gifsFolder : _iconsFolder;
    if (parentDir == null) return null;
    final filePath = '${parentDir.path}\\${item.fileName}';
    if (File(filePath).existsSync()) return filePath;
    return null;
  }

  /// Returns filtered list of assets for Gifs.
  List<CloudAssetItem> getGifs() {
    final items = _assets.where((a) => a.folder == 'Gifs').toList();
    if (items.isNotEmpty) return items;
    return List<CloudAssetItem>.unmodifiable(
      _bundledAssets.where((a) => a.folder == 'Gifs'),
    );
  }

  /// Returns filtered list of assets for Icons (PNG & SVG).
  List<CloudAssetItem> getIcons() {
    final items = _assets.where((a) => a.folder == 'Icons').toList();
    if (items.isNotEmpty) return items;
    return List<CloudAssetItem>.unmodifiable(
      _bundledAssets.where((a) => a.folder == 'Icons'),
    );
  }

  /// Returns all downloaded asset local paths.
  List<String> getDownloadedAssetPaths({CloudAssetType? type}) {
    final results = <String>[];
    for (final asset in _assets) {
      if (type != null && asset.assetType != type) continue;
      final path = getAssetLocalPath(asset);
      if (path != null) results.add(path);
    }
    return results;
  }

  /// Check remote GitHub repository for new GIFs or Icons.
  Future<bool> checkForUpdates({bool silent = false}) async {
    if (_isCheckingUpdates) return _hasUpdateAvailable;
    _isCheckingUpdates = true;
    if (!silent) notifyListeners();

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);

      final newItems = <CloudAssetItem>[];

      // 1. Fetch Gifs remote folder contents
      try {
        final gifsReq = await client.getUrl(Uri.parse(githubGifsApiUrl));
        gifsReq.headers.set('User-Agent', 'WallSync-Pro/1.0');
        gifsReq.headers.set('Accept', 'application/vnd.github.v3+json');
        final gifsRes = await gifsReq.close();
        if (gifsRes.statusCode == 200) {
          final body = await gifsRes.transform(utf8.decoder).join();
          final list = jsonDecode(body) as List<dynamic>;
          for (final item in list) {
            if (item is Map<String, dynamic> && item['type'] == 'file') {
              newItems.add(CloudAssetItem.fromGitHubJson(item, 'Gifs'));
            }
          }
        }
      } catch (e) {
        logWarning('CustomAssetService', 'Failed to fetch remote Gifs listing: $e');
      }

      // 2. Fetch Icons remote folder contents
      try {
        final iconsReq = await client.getUrl(Uri.parse(githubIconsApiUrl));
        iconsReq.headers.set('User-Agent', 'WallSync-Pro/1.0');
        iconsReq.headers.set('Accept', 'application/vnd.github.v3+json');
        final iconsRes = await iconsReq.close();
        if (iconsRes.statusCode == 200) {
          final body = await iconsRes.transform(utf8.decoder).join();
          final list = jsonDecode(body) as List<dynamic>;
          for (final item in list) {
            if (item is Map<String, dynamic> && item['type'] == 'file') {
              newItems.add(CloudAssetItem.fromGitHubJson(item, 'Icons'));
            }
          }
        }
      } catch (e) {
        logWarning('CustomAssetService', 'Failed to fetch remote Icons listing: $e');
      }

      client.close();

      if (newItems.isNotEmpty) {
        final existingKeys = {for (var a in _assets) '${a.folder}/${a.fileName}'};
        int newlyAdded = 0;
        final merged = List<CloudAssetItem>.from(_assets);

        for (final item in newItems) {
          final key = '${item.folder}/${item.fileName}';
          if (!existingKeys.contains(key)) {
            merged.add(item);
            newlyAdded++;
          }
        }

        if (newlyAdded > 0) {
          _assets = merged;
          _hasUpdateAvailable = true;
          _newAssetsCount = newlyAdded;
          await _saveAssetManifest();
        }
      }

      _lastCheckedAt = DateTime.now();
      _isCheckingUpdates = false;
      notifyListeners();
      return _hasUpdateAvailable;
    } catch (e, st) {
      logError('CustomAssetService', 'Error checking for asset updates', e, st);
      _isCheckingUpdates = false;
      notifyListeners();
      return false;
    }
  }

  /// Downloads a single asset to its local folder.
  /// Usability enforcement: widgets can only use downloaded files!
  Future<bool> downloadAsset(
    CloudAssetItem item, {
    void Function(double fraction)? onProgress,
  }) async {
    if (!_isInitialized) await init();

    final targetDir = item.folder == 'Gifs' ? _gifsFolder : _iconsFolder;
    if (targetDir == null) return false;

    final targetFile = File('${targetDir.path}\\${item.fileName}');
    final tempFile = File('${targetDir.path}\\${item.fileName}.tmp');

    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(item.downloadUrl));
      req.headers.set('User-Agent', 'WallSync-Pro/1.0');
      final res = await req.close();

      if (res.statusCode != 200) {
        client.close();
        logWarning('CustomAssetService', 'Failed to download ${item.fileName}: HTTP ${res.statusCode}');
        return false;
      }

      final contentLength = res.contentLength;
      int received = 0;

      final sink = tempFile.openWrite();
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          final fraction = (received / contentLength).clamp(0.0, 1.0);
          onProgress?.call(fraction);
        }
      }
      await sink.flush();
      await sink.close();
      client.close();

      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await tempFile.rename(targetFile.path);

      _downloadedKeys.add('${item.folder}/${item.fileName}');
      notifyListeners();
      return true;
    } catch (e, st) {
      logError('CustomAssetService', 'Error downloading ${item.fileName}', e, st);
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      return false;
    }
  }

  /// Batch download all assets of a specified type or all available assets.
  Future<void> downloadAllAssets({CloudAssetType? type}) async {
    if (_batchProgress.isDownloading) return;
    _cancelRequested = false;

    final targetList = _assets.where((a) {
      if (type != null && a.assetType != type) return false;
      return !isAssetDownloaded(a);
    }).toList();

    if (targetList.isEmpty) return;

    _batchProgress = CloudAssetBatchProgress(
      totalFiles: targetList.length,
      completedFiles: 0,
      currentFileName: targetList.first.fileName,
      fraction: 0.0,
      isDownloading: true,
    );
    notifyListeners();

    int completed = 0;
    for (int i = 0; i < targetList.length; i++) {
      if (_cancelRequested) {
        _batchProgress = _batchProgress.copyWith(
          isDownloading: false,
          isCancelled: true,
        );
        notifyListeners();
        return;
      }

      final item = targetList[i];
      _batchProgress = _batchProgress.copyWith(
        currentFileName: item.fileName,
        completedFiles: completed,
        fraction: completed / targetList.length,
      );
      notifyListeners();

      final success = await downloadAsset(item);
      if (success) completed++;
    }

    _batchProgress = _batchProgress.copyWith(
      completedFiles: completed,
      fraction: 1.0,
      isDownloading: false,
    );
    notifyListeners();
  }

  /// Request cancellation of the active batch download.
  void cancelBatchDownload() {
    _cancelRequested = true;
    _batchProgress = _batchProgress.copyWith(isCancelled: true);
    notifyListeners();
  }

  /// Deletes a downloaded asset from disk.
  Future<bool> deleteAsset(CloudAssetItem item) async {
    final parentDir = item.folder == 'Gifs' ? _gifsFolder : _iconsFolder;
    if (parentDir == null) return false;

    final file = File('${parentDir.path}\\${item.fileName}');
    if (await file.exists()) {
      try {
        await file.delete();
        _downloadedKeys.remove('${item.folder}/${item.fileName}');
        notifyListeners();
        return true;
      } catch (e) {
        logWarning('CustomAssetService', 'Failed to delete ${item.fileName}: $e');
        return false;
      }
    }
    return false;
  }
}
