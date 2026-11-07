import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'settings_service.dart';

/// Represents a single font file variant (weight, style, file name).
class FontVariant {
  final String fileName;
  final String style;
  final int weight;
  final bool isItalic;
  final String postscriptName;
  final String designer;
  final String copyright;
  final String version;
  final int fileSize;

  const FontVariant({
    required this.fileName,
    this.style = 'Regular',
    this.weight = 400,
    this.isItalic = false,
    this.postscriptName = '',
    this.designer = '',
    this.copyright = '',
    this.version = '',
    this.fileSize = 0,
  });

  factory FontVariant.fromJson(Map<String, dynamic> json) {
    return FontVariant(
      fileName: json['file_name']?.toString() ?? '',
      style: json['style']?.toString() ?? 'Regular',
      weight: (json['weight'] as num?)?.toInt() ?? 400,
      isItalic: json['is_italic'] == true,
      postscriptName: json['postscript_name']?.toString() ?? '',
      designer: json['designer']?.toString() ?? '',
      copyright: json['copyright']?.toString() ?? '',
      version: json['version']?.toString() ?? '',
      fileSize: (json['file_size'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'file_name': fileName,
    'style': style,
    'weight': weight,
    'is_italic': isItalic,
    'postscript_name': postscriptName,
    'designer': designer,
    'copyright': copyright,
    'version': version,
    'file_size': fileSize,
  };
}

/// Represents a font family grouping multiple variants under a common name.
class FontFamilyItem {
  final String familyName;
  final String category;
  final String mainFontFile;
  final List<FontVariant> variants;

  const FontFamilyItem({
    required this.familyName,
    required this.category,
    required this.mainFontFile,
    required this.variants,
  });

  factory FontFamilyItem.fromJson(Map<String, dynamic> json) {
    final rawVariants = json['variants'] as List<dynamic>? ?? [];
    return FontFamilyItem(
      familyName: json['family_name']?.toString() ?? 'Unnamed Font',
      category: json['category']?.toString() ?? 'Display / Decorative',
      mainFontFile: json['main_font_file']?.toString() ?? '',
      variants: rawVariants
          .whereType<Map<String, dynamic>>()
          .map(FontVariant.fromJson)
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'family_name': familyName,
    'category': category,
    'main_font_file': mainFontFile,
    'variants': variants.map((v) => v.toJson()).toList(),
  };

  bool get isDownloaded => CustomFontService.instance.isFamilyDownloaded(this);
  bool get isLoaded => CustomFontService.instance.isFamilyLoaded(familyName);
  String? get localPath => CustomFontService.instance.getFamilyLocalPath(this);

  String get displayDesigner {
    for (final v in variants) {
      if (v.designer.trim().isNotEmpty) return v.designer.trim();
    }
    return '';
  }
}

/// Batch download progress snapshot.
class FontDownloadBatchProgress {
  final int totalFiles;
  final int completedFiles;
  final String currentFileName;
  final double fraction;
  final bool isDownloading;
  final bool isCancelled;
  final String? error;

  const FontDownloadBatchProgress({
    this.totalFiles = 0,
    this.completedFiles = 0,
    this.currentFileName = '',
    this.fraction = 0.0,
    this.isDownloading = false,
    this.isCancelled = false,
    this.error,
  });

  FontDownloadBatchProgress copyWith({
    int? totalFiles,
    int? completedFiles,
    String? currentFileName,
    double? fraction,
    bool? isDownloading,
    bool? isCancelled,
    String? error,
  }) {
    return FontDownloadBatchProgress(
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

/// Core service that manages custom font assets, dynamically loads fonts into
/// Flutter at runtime, synchronizes with the remote GitHub repository,
/// checks for new font releases on app startup, and powers the font preview and picker.
class CustomFontService extends ChangeNotifier {
  static final CustomFontService instance = CustomFontService._internal();
  factory CustomFontService() => instance;
  CustomFontService._internal();

  static const String repoUrl = 'https://github.com/Croenix/Font.git';
  static const String rawBaseUrl =
      'https://raw.githubusercontent.com/Croenix/Font/main';
  static const String categoriesJsonUrl = '$rawBaseUrl/font_categories.json';
  static const String fontsRawBaseUrl = '$rawBaseUrl/Fonts';
  static const String githubCommitApiUrl =
      'https://api.github.com/repos/Croenix/Font/commits/main';

  static const List<String> builtInFonts = [
    'Montserrat',
    'Product Sans',
    'Anurati',
    'Moving Skate',
    'Segoe UI',
    'Consolas',
    'Impact',
    'Arial',
    'Georgia',
  ];

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  Directory? _customFontsDirectory;
  Directory? _fontsFolder;
  Directory? _previewFolder;

  final Set<String> _loadingPreviewFamilies = <String>{};
  bool isFamilyPreviewLoading(String familyName) =>
      _loadingPreviewFamilies.contains(familyName);

  List<FontFamilyItem> _families = [];
  List<FontFamilyItem> get families => List.unmodifiable(_families);

  final Set<String> _downloadedFileNames = <String>{};
  final Set<String> _loadedFamilies = <String>{};
  Set<String> get loadedFamilies => Set.unmodifiable(_loadedFamilies);

  String? _lastLocalCommitSha;
  String? get lastLocalCommitSha => _lastLocalCommitSha;

  DateTime? _lastCheckedAt;
  DateTime? get lastCheckedAt => _lastCheckedAt;

  bool _hasUpdateAvailable = false;
  bool get hasUpdateAvailable => _hasUpdateAvailable;

  int _newFontsCount = 0;
  int get newFontsCount => _newFontsCount;

  bool _isCheckingUpdates = false;
  bool get isCheckingUpdates => _isCheckingUpdates;

  FontDownloadBatchProgress _batchProgress = const FontDownloadBatchProgress();
  FontDownloadBatchProgress get batchProgress => _batchProgress;

  bool _cancelRequested = false;

  /// Returns distinct list of all fonts that are installed and usable for widgets.
  /// (Built-in fonts + downloaded fonts ONLY. Preview-only fonts are excluded until downloaded).
  List<String> get availableFontNames {
    final downloadedFamilyNames = _families
        .where((f) => isFamilyDownloaded(f))
        .map((f) => f.familyName);
    final set = <String>{...builtInFonts, ...downloadedFamilyNames};
    return set.toList();
  }

  /// Initialize local font cache directory, load categories, and register downloaded fonts.
  Future<void> init() async {
    if (_isInitialized) return;

    try {
      final appDir = await SettingsService().getAppDirectory();
      _customFontsDirectory = Directory('${appDir.path}\\custom_fonts');
      _fontsFolder = Directory('${_customFontsDirectory!.path}\\Fonts');

      if (!await _customFontsDirectory!.exists()) {
        await _customFontsDirectory!.create(recursive: true);
      }
      if (!await _fontsFolder!.exists()) {
        await _fontsFolder!.create(recursive: true);
      }
      _previewFolder = Directory('${_customFontsDirectory!.path}\\.previews');
      if (!await _previewFolder!.exists()) {
        await _previewFolder!.create(recursive: true);
      }

      await _readSyncMetadata();
      await _loadLocalOrBundledCategories();
      await _scanAndLoadDownloadedFonts();

      _isInitialized = true;
      logInfo(
        'CustomFontService',
        'CustomFontService initialized: ${_families.length} families, '
            '${_downloadedFileNames.length} files downloaded, ${_loadedFamilies.length} loaded into engine.',
      );
      notifyListeners();
    } catch (e, st) {
      logError('CustomFontService', 'Failed to initialize CustomFontService', e, st);
    }
  }

  /// Checks for repository changes or new fonts on app startup (in background).
  Future<bool> checkForUpdatesOnStartup() async {
    try {
      if (!_isInitialized) {
        await init();
      }
      return await checkForUpdates(silent: true);
    } catch (e) {
      logWarning('CustomFontService', 'Startup font update check skipped: $e');
      return false;
    }
  }

  /// Verifies if there are any new commits or font category changes on GitHub.
  Future<bool> checkForUpdates({bool silent = false}) async {
    if (_isCheckingUpdates) return _hasUpdateAvailable;
    _isCheckingUpdates = true;
    if (!silent) notifyListeners();

    try {
      final remoteSha = await _fetchLatestCommitSha();
      final hasShaDiff = remoteSha != null &&
          remoteSha.isNotEmpty &&
          remoteSha != _lastLocalCommitSha;

      final remoteJsonStr = await _fetchRemoteText(categoriesJsonUrl);
      if (remoteJsonStr != null && remoteJsonStr.trim().isNotEmpty) {
        final Map<String, dynamic> parsed = jsonDecode(remoteJsonStr);
        final remoteFamilies = _parseFamiliesFromJson(parsed);

        // Count how many font files or families in remote are not locally present
        int diffCount = 0;
        final currentFileNames = _families
            .expand((f) => f.variants.map((v) => v.fileName))
            .toSet();

        for (final fam in remoteFamilies) {
          for (final variant in fam.variants) {
            if (!currentFileNames.contains(variant.fileName) ||
                !_downloadedFileNames.contains(variant.fileName)) {
              diffCount++;
            }
          }
        }

        if (hasShaDiff || diffCount > 0 || _families.isEmpty) {
          _hasUpdateAvailable = true;
          _newFontsCount = diffCount;
          _families = remoteFamilies;

          // Save the fresh categories json locally
          if (_customFontsDirectory != null) {
            final localJson = File(
              '${_customFontsDirectory!.path}\\font_categories.json',
            );
            await localJson.writeAsString(remoteJsonStr);
          }
        } else {
          _hasUpdateAvailable = false;
          _newFontsCount = 0;
        }

        if (remoteSha != null && remoteSha.isNotEmpty) {
          _lastLocalCommitSha = remoteSha;
        }
      }

      _lastCheckedAt = DateTime.now();
      await _writeSyncMetadata();

      logInfo(
        'CustomFontService',
        'Font update check completed: hasUpdate=$_hasUpdateAvailable (newFonts=$_newFontsCount)',
      );
      return _hasUpdateAvailable;
    } catch (e) {
      logWarning('CustomFontService', 'Check for font updates failed: $e');
      return false;
    } finally {
      _isCheckingUpdates = false;
      notifyListeners();
    }
  }

  /// Synchronize categories json from GitHub repository.
  Future<bool> syncCategoriesJson() async {
    try {
      final remoteJsonStr = await _fetchRemoteText(categoriesJsonUrl);
      if (remoteJsonStr == null || remoteJsonStr.isEmpty) return false;

      final Map<String, dynamic> parsed = jsonDecode(remoteJsonStr);
      _families = _parseFamiliesFromJson(parsed);

      if (_customFontsDirectory != null) {
        final localJson = File(
          '${_customFontsDirectory!.path}\\font_categories.json',
        );
        await localJson.writeAsString(remoteJsonStr);
      }

      _refreshDownloadedFileNames();
      notifyListeners();
      return true;
    } catch (e) {
      logWarning('CustomFontService', 'Failed to sync categories JSON: $e');
      return false;
    }
  }

  /// Downloads all variants of a single font family and loads it into Flutter.
  Future<bool> downloadFontFamily(
    FontFamilyItem family, {
    void Function(double progress)? onProgress,
  }) async {
    if (_fontsFolder == null) await init();
    try {
      final variantsToDownload = family.variants.isNotEmpty
          ? family.variants
          : [FontVariant(fileName: family.mainFontFile)];

      int downloaded = 0;
      final total = variantsToDownload.length;

      for (final variant in variantsToDownload) {
        if (variant.fileName.isEmpty) continue;
        final targetFile = File('${_fontsFolder!.path}\\${variant.fileName}');
        final previewFile = _previewFolder != null
            ? File('${_previewFolder!.path}\\${variant.fileName}')
            : null;
        if (previewFile != null &&
            await previewFile.exists() &&
            (await previewFile.length()) > 0 &&
            (!await targetFile.exists() || (await targetFile.length()) == 0)) {
          await previewFile.copy(targetFile.path);
        } else if (!await targetFile.exists() || (await targetFile.length()) == 0) {
          final url = '$fontsRawBaseUrl/${Uri.encodeComponent(variant.fileName)}';
          final success = await _downloadFileDirect(url, targetFile);
          if (!success) {
            logWarning('CustomFontService', 'Failed to download ${variant.fileName}');
            return false;
          }
        }
        _downloadedFileNames.add(variant.fileName);
        downloaded++;
        onProgress?.call(downloaded / total);
      }

      // Load into engine immediately
      await loadFamilyIntoEngine(family.familyName);
      await _writeSyncMetadata();
      notifyListeners();
      return true;
    } catch (e) {
      logError('CustomFontService', 'Error downloading family ${family.familyName}', e);
      return false;
    }
  }

  /// Downloads preview bytes on demand for a family so user can see its design
  /// before downloading. Does NOT mark the font as downloaded/usable for widgets.
  Future<bool> ensurePreviewLoaded(FontFamilyItem family) async {
    if (_loadedFamilies.contains(family.familyName)) return true;
    if (_fontsFolder == null) await init();
    if (_previewFolder == null) {
      _previewFolder = Directory('${_customFontsDirectory!.path}\\.previews');
      if (!await _previewFolder!.exists()) {
        await _previewFolder!.create(recursive: true);
      }
    }

    final mainFile = family.mainFontFile.isNotEmpty
        ? family.mainFontFile
        : (family.variants.isNotEmpty ? family.variants.first.fileName : '');
    if (mainFile.isEmpty) return false;

    if (_loadingPreviewFamilies.contains(family.familyName)) return false;
    _loadingPreviewFamilies.add(family.familyName);

    try {
      // 1. Check if permanent file exists
      final permanentFile = File('${_fontsFolder!.path}\\$mainFile');
      if (await permanentFile.exists() && (await permanentFile.length()) > 0) {
        final success = await loadFamilyIntoEngine(family.familyName);
        if (success) {
          notifyListeners();
          return true;
        }
      }

      // 2. Check if cached preview file exists
      final previewFile = File('${_previewFolder!.path}\\$mainFile');
      if (!await previewFile.exists() || (await previewFile.length()) == 0) {
        final url = '$fontsRawBaseUrl/${Uri.encodeComponent(mainFile)}';
        final downloaded = await _downloadFileDirect(url, previewFile);
        if (!downloaded) {
          return false;
        }
      }

      // 3. Load preview bytes into Flutter engine via FontLoader
      final bytes = await previewFile.readAsBytes();
      final loader = FontLoader(family.familyName);
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      _loadedFamilies.add(family.familyName);
      notifyListeners();
      return true;
    } catch (e) {
      logWarning(
        'CustomFontService',
        'Could not load preview for ${family.familyName}: $e',
      );
      return false;
    } finally {
      _loadingPreviewFamilies.remove(family.familyName);
    }
  }

  /// Batch preload previews for a list of families.
  Future<void> preloadVisiblePreviews(
    List<FontFamilyItem> families, {
    int max = 8,
  }) async {
    final toLoad = families
        .where(
          (f) =>
              !_loadedFamilies.contains(f.familyName) &&
              !_loadingPreviewFamilies.contains(f.familyName),
        )
        .take(max)
        .toList();

    if (toLoad.isEmpty) return;

    await Future.wait(toLoad.map((f) => ensurePreviewLoaded(f)));
  }

  /// Downloads all fonts from the repository with progress updates and cancel support.
  Future<void> downloadAllFonts({
    void Function(FontDownloadBatchProgress progress)? onProgress,
  }) async {
    if (_batchProgress.isDownloading) return;
    if (_fontsFolder == null) await init();

    _cancelRequested = false;

    // Gather all distinct files to download
    final allFiles = <String>{};
    for (final fam in _families) {
      if (fam.variants.isNotEmpty) {
        for (final v in fam.variants) {
          if (v.fileName.isNotEmpty) allFiles.add(v.fileName);
        }
      } else if (fam.mainFontFile.isNotEmpty) {
        allFiles.add(fam.mainFontFile);
      }
    }

    final pendingFiles = allFiles
        .where((file) => !_downloadedFileNames.contains(file))
        .toList();

    if (pendingFiles.isEmpty) {
      _batchProgress = FontDownloadBatchProgress(
        totalFiles: allFiles.length,
        completedFiles: allFiles.length,
        fraction: 1.0,
        isDownloading: false,
      );
      notifyListeners();
      onProgress?.call(_batchProgress);
      return;
    }

    _batchProgress = FontDownloadBatchProgress(
      totalFiles: pendingFiles.length,
      completedFiles: 0,
      isDownloading: true,
      fraction: 0.0,
    );
    notifyListeners();
    onProgress?.call(_batchProgress);

    int completed = 0;

    for (final fileName in pendingFiles) {
      if (_cancelRequested) {
        _batchProgress = _batchProgress.copyWith(
          isDownloading: false,
          isCancelled: true,
        );
        notifyListeners();
        onProgress?.call(_batchProgress);
        return;
      }

      _batchProgress = _batchProgress.copyWith(
        currentFileName: fileName,
        completedFiles: completed,
        fraction: completed / pendingFiles.length,
      );
      notifyListeners();
      onProgress?.call(_batchProgress);

      final targetFile = File('${_fontsFolder!.path}\\$fileName');
      final url = '$fontsRawBaseUrl/${Uri.encodeComponent(fileName)}';

      final ok = await _downloadFileDirect(url, targetFile);
      if (ok) {
        _downloadedFileNames.add(fileName);

        // Find which families this file belongs to and load them
        for (final fam in _families) {
          if (fam.mainFontFile == fileName ||
              fam.variants.any((v) => v.fileName == fileName)) {
            unawaited(loadFamilyIntoEngine(fam.familyName));
          }
        }
      }

      completed++;
      _batchProgress = _batchProgress.copyWith(
        completedFiles: completed,
        fraction: completed / pendingFiles.length,
      );
      notifyListeners();
      onProgress?.call(_batchProgress);
    }

    _batchProgress = _batchProgress.copyWith(
      isDownloading: false,
      fraction: 1.0,
      currentFileName: 'All fonts downloaded successfully!',
    );
    _hasUpdateAvailable = false;
    _newFontsCount = 0;
    await _writeSyncMetadata();
    notifyListeners();
    onProgress?.call(_batchProgress);
  }

  /// Cancels any active batch download.
  void cancelDownload() {
    _cancelRequested = true;
    _batchProgress = _batchProgress.copyWith(
      isDownloading: false,
      isCancelled: true,
    );
    notifyListeners();
  }

  /// Checks if a font family is already downloaded locally.
  bool isFamilyDownloaded(FontFamilyItem family) {
    if (_fontsFolder == null) return false;
    if (family.variants.isNotEmpty) {
      return family.variants.every((v) => _downloadedFileNames.contains(v.fileName));
    }
    return _downloadedFileNames.contains(family.mainFontFile);
  }

  /// Checks if a font family is loaded in the Flutter engine.
  bool isFamilyLoaded(String familyName) {
    return _loadedFamilies.contains(familyName);
  }

  /// Resolves the absolute local file path of a family's main font file.
  String? getFamilyLocalPath(FontFamilyItem family) {
    if (_fontsFolder == null) return null;
    final file = File('${_fontsFolder!.path}\\${family.mainFontFile}');
    return file.existsSync() ? file.path : null;
  }

  /// Dynamically registers a font family with Flutter's runtime engine using FontLoader.
  Future<bool> loadFamilyIntoEngine(String familyName) async {
    if (_loadedFamilies.contains(familyName)) return true;
    if (_fontsFolder == null) return false;

    final family = _families.firstWhere(
      (f) => f.familyName.toLowerCase() == familyName.toLowerCase(),
      orElse: () => FontFamilyItem(
        familyName: familyName,
        category: 'Display / Decorative',
        mainFontFile: '',
        variants: const [],
      ),
    );

    final fontFiles = <File>[];
    if (family.variants.isNotEmpty) {
      for (final v in family.variants) {
        final f = File('${_fontsFolder!.path}\\${v.fileName}');
        if (f.existsSync()) fontFiles.add(f);
      }
    } else if (family.mainFontFile.isNotEmpty) {
      final f = File('${_fontsFolder!.path}\\${family.mainFontFile}');
      if (f.existsSync()) fontFiles.add(f);
    }

    if (fontFiles.isEmpty) {
      // Check if file exists matching family name directly
      final directFileTtf = File('${_fontsFolder!.path}\\$familyName.ttf');
      final directFileOtf = File('${_fontsFolder!.path}\\$familyName.otf');
      if (directFileTtf.existsSync()) fontFiles.add(directFileTtf);
      if (directFileOtf.existsSync()) fontFiles.add(directFileOtf);
    }

    if (fontFiles.isEmpty) return false;

    try {
      final loader = FontLoader(familyName);
      for (final file in fontFiles) {
        final bytes = await file.readAsBytes();
        loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      }
      await loader.load();
      _loadedFamilies.add(familyName);
      notifyListeners();
      logInfo('CustomFontService', 'Dynamically registered font family "$familyName" into engine.');
      return true;
    } catch (e) {
      logWarning('CustomFontService', 'Failed to load font family "$familyName": $e');
      return false;
    }
  }

  /// Deletes downloaded font files for a specific family.
  Future<void> deleteFontFamily(FontFamilyItem family) async {
    if (_fontsFolder == null) return;
    try {
      final filesToDelete = family.variants.isNotEmpty
          ? family.variants.map((v) => v.fileName).toList()
          : [family.mainFontFile];

      for (final name in filesToDelete) {
        final f = File('${_fontsFolder!.path}\\$name');
        if (await f.exists()) {
          await f.delete();
        }
        _downloadedFileNames.remove(name);
      }
      notifyListeners();
    } catch (e) {
      logWarning('CustomFontService', 'Failed to delete font files for ${family.familyName}: $e');
    }
  }

  // ── Internal Helpers ────────────────────────────────────────────────────────

  Future<void> _loadLocalOrBundledCategories() async {
    String? content;

    // 1. Try local cached json
    if (_customFontsDirectory != null) {
      final localJson = File('${_customFontsDirectory!.path}\\font_categories.json');
      if (await localJson.exists()) {
        try {
          content = await localJson.readAsString();
        } catch (_) {}
      }
    }

    // 2. Try bundled assets fallback
    if (content == null || content.trim().isEmpty) {
      try {
        content = await rootBundle.loadString('assets/font_categories.json');
      } catch (_) {}
    }

    if (content != null && content.trim().isNotEmpty) {
      try {
        final Map<String, dynamic> parsed = jsonDecode(content);
        _families = _parseFamiliesFromJson(parsed);
      } catch (e) {
        logWarning('CustomFontService', 'Error parsing font_categories.json: $e');
      }
    }
  }

  Future<void> _scanAndLoadDownloadedFonts() async {
    if (_fontsFolder == null) return;
    _refreshDownloadedFileNames();

    for (final family in _families) {
      if (isFamilyDownloaded(family)) {
        await loadFamilyIntoEngine(family.familyName);
      }
    }
  }

  void _refreshDownloadedFileNames() {
    _downloadedFileNames.clear();
    if (_fontsFolder == null || !_fontsFolder!.existsSync()) return;

    for (final entity in _fontsFolder!.listSync()) {
      if (entity is File) {
        final name = entity.uri.pathSegments.last;
        if (entity.lengthSync() > 0) {
          _downloadedFileNames.add(name);
        }
      }
    }
  }

  List<FontFamilyItem> _parseFamiliesFromJson(Map<String, dynamic> json) {
    final list = <FontFamilyItem>[];
    final categoriesMap = json['categories'] as Map<String, dynamic>? ?? {};

    categoriesMap.forEach((categoryName, familiesList) {
      if (familiesList is List) {
        for (final item in familiesList) {
          if (item is Map<String, dynamic>) {
            final fam = FontFamilyItem.fromJson(item);
            list.add(fam);
          }
        }
      }
    });

    return list;
  }

  Future<String?> _fetchLatestCommitSha() async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(Uri.parse(githubCommitApiUrl));
      request.headers.set('User-Agent', 'WallSyncPro/1.0');
      final response = await request.close().timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final text = await response.transform(utf8.decoder).join();
        final Map<String, dynamic> json = jsonDecode(text);
        return json['sha']?.toString();
      }
    } catch (_) {
      // Fallback or offline
    } finally {
      client?.close(force: true);
    }
    return null;
  }

  Future<String?> _fetchRemoteText(String url) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'WallSyncPro/1.0');
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        return await response.transform(utf8.decoder).join();
      }
    } catch (_) {
    } finally {
      client?.close(force: true);
    }
    return null;
  }

  Future<bool> _downloadFileDirect(String url, File destination) async {
    HttpClient? client;
    IOSink? sink;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 12);
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('User-Agent', 'WallSyncPro/1.0');
      final response = await request.close().timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) return false;

      final tempFile = File('${destination.path}.tmp');
      sink = tempFile.openWrite();
      await response.pipe(sink);
      await sink.flush();
      await sink.close();
      sink = null;

      if (await destination.exists()) {
        await destination.delete();
      }
      await tempFile.rename(destination.path);
      return true;
    } catch (e) {
      try {
        final tempFile = File('${destination.path}.tmp');
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
      return false;
    } finally {
      await sink?.close();
      client?.close(force: true);
    }
  }

  Future<void> _readSyncMetadata() async {
    if (_customFontsDirectory == null) return;
    final file = File('${_customFontsDirectory!.path}\\font_sync_meta.json');
    if (!await file.exists()) return;

    try {
      final json = jsonDecode(await file.readAsString());
      _lastLocalCommitSha = json['commitSha']?.toString();
      if (json['lastCheckedAt'] != null) {
        _lastCheckedAt = DateTime.tryParse(json['lastCheckedAt'].toString());
      }
    } catch (_) {}
  }

  Future<void> _writeSyncMetadata() async {
    if (_customFontsDirectory == null) return;
    final file = File('${_customFontsDirectory!.path}\\font_sync_meta.json');
    try {
      final data = {
        'commitSha': _lastLocalCommitSha,
        'lastCheckedAt': _lastCheckedAt?.toIso8601String(),
        'downloadedCount': _downloadedFileNames.length,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }
}
