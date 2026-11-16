import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/custom_asset_service.dart';
import 'package:wall_sync/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CloudAssetItem Model & Properties', () {
    test('parses GitHub JSON correctly for Gifs', () {
      final json = {
        'name': 'cloud.gif',
        'path': 'Gifs/cloud.gif',
        'sha': '6e024070ab0dfccd3749e16dd179bf719a6eaed9',
        'size': 141643,
        'download_url': 'https://raw.githubusercontent.com/Croenix/Font/main/Gifs/cloud.gif',
        'type': 'file',
      };

      final item = CloudAssetItem.fromGitHubJson(json, 'Gifs');
      expect(item.fileName, 'cloud.gif');
      expect(item.folder, 'Gifs');
      expect(item.assetType, CloudAssetType.gif);
      expect(item.isGif, isTrue);
      expect(item.isPng, isFalse);
      expect(item.isSvg, isFalse);
      expect(item.fileExtension, 'gif');
      expect(item.displayName, 'Cloud');
      expect(item.formattedSize, '138.3 KB');
      expect(item.category, 'Clouds & Skies');
    });

    test('parses GitHub JSON correctly for Icons (PNG & SVG)', () {
      final json = {
        'name': 'windy-rain.png',
        'path': 'Icons/windy-rain.png',
        'sha': '2daf757d7d7e664e782bfec32d78804dcc298b2b',
        'size': 25678,
        'download_url': 'https://raw.githubusercontent.com/Croenix/Font/main/Icons/windy-rain.png',
        'type': 'file',
      };

      final item = CloudAssetItem.fromGitHubJson(json, 'Icons');
      expect(item.fileName, 'windy-rain.png');
      expect(item.folder, 'Icons');
      expect(item.assetType, CloudAssetType.icon);
      expect(item.isGif, isFalse);
      expect(item.isPng, isTrue);
      expect(item.isSvg, isFalse);
      expect(item.displayName, 'Windy Rain');
      expect(item.formattedSize, '25.1 KB');
    });

    test('parses SVG icon properly', () {
      final json = {
        'name': 'compass-pointer.svg',
        'folder': 'Icons',
        'sha': '12345',
        'file_size': 4096,
        'download_url': 'https://raw.githubusercontent.com/Croenix/Font/main/Icons/compass-pointer.svg',
        'asset_type': 'icon',
        'category': 'Navigation',
      };

      final item = CloudAssetItem.fromJson(json);
      expect(item.isSvg, isTrue);
      expect(item.isPng, isFalse);
      expect(item.isGif, isFalse);
      expect(item.displayName, 'Compass Pointer');
      expect(item.formattedSize, '4.0 KB');
    });

    test('toJson and fromJson cycle retains all values', () {
      const original = CloudAssetItem(
        fileName: 'outline moon stars.gif',
        folder: 'Gifs',
        sha: '0805da970fbb94ebc7e65ffd1ec43555806ccf8c',
        fileSize: 229351,
        downloadUrl: 'https://raw.githubusercontent.com/Croenix/Font/main/Gifs/outline%20moon%20stars.gif',
        assetType: CloudAssetType.gif,
        category: 'Celestial & Night',
      );

      final json = original.toJson();
      final restored = CloudAssetItem.fromJson(json);

      expect(restored.fileName, original.fileName);
      expect(restored.folder, original.folder);
      expect(restored.sha, original.sha);
      expect(restored.fileSize, original.fileSize);
      expect(restored.assetType, original.assetType);
      expect(restored.category, original.category);
      expect(restored.displayName, 'Outline Moon Stars');
    });
  });

  group('CustomAssetService Bundled Catalog & Gating', () {
    test('initializes with all remote repository Gifs and Icons in fallback catalog', () async {
      final service = CustomAssetService.instance;
      await service.init();

      final gifs = service.getGifs();
      final icons = service.getIcons();

      expect(gifs.length, greaterThanOrEqualTo(6));
      expect(icons.length, greaterThanOrEqualTo(5));

      final gifNames = gifs.map((g) => g.fileName).toSet();
      expect(gifNames.contains('cloud.gif'), isTrue);
      expect(gifNames.contains('outline cloud.gif'), isTrue);
      expect(gifNames.contains('outline moon stars.gif'), isTrue);
      expect(gifNames.contains('rain drop.gif'), isTrue);
      expect(gifNames.contains('stars hover.gif'), isTrue);
      expect(gifNames.contains('Woman enjoying Rain Day.gif'), isTrue);

      final iconNames = icons.map((i) => i.fileName).toSet();
      expect(iconNames.contains('rain.png'), isTrue);
      expect(iconNames.contains('sun.png'), isTrue);
      expect(iconNames.contains('thunder.png'), isTrue);
      expect(iconNames.contains('windy-rain.png'), isTrue);
      expect(iconNames.contains('windy.png'), isTrue);
    });

    test('resetLocalState clears stale on-disk downloads before catalog initialization', () async {
      final service = CustomAssetService.instance;
      final appDir = await SettingsService().getAppDirectory();
      final customAssetsDir = Directory('${appDir.path}\\custom_assets');
      final gifsDir = Directory('${customAssetsDir.path}\\Gifs');
      await gifsDir.create(recursive: true);
      await File('${gifsDir.path}\\cloud.gif').writeAsString('stale test payload');

      await service.init(resetLocalState: true);

      expect(service.getGifs().every((g) => !g.isDownloaded), isTrue);
      expect(service.getIcons().every((i) => !i.isDownloaded), isTrue);
    });

    test('usability rule: un-downloaded items have isDownloaded=false and localPath=null', () {
      const nonExistentItem = CloudAssetItem(
        fileName: 'never_downloaded_test_file_9999.gif',
        folder: 'Gifs',
        downloadUrl: 'https://example.com/test.gif',
        assetType: CloudAssetType.gif,
      );

      expect(CustomAssetService.instance.isAssetDownloaded(nonExistentItem), isFalse);
      expect(CustomAssetService.instance.getAssetLocalPath(nonExistentItem), isNull);
    });

    test('batch progress copyWith and cancel logic works as expected', () {
      final progress = const CloudAssetBatchProgress(
        totalFiles: 10,
        completedFiles: 3,
        currentFileName: 'cloud.gif',
        fraction: 0.3,
        isDownloading: true,
      );

      final cancelled = progress.copyWith(isCancelled: true, isDownloading: false);
      expect(cancelled.isCancelled, isTrue);
      expect(cancelled.isDownloading, isFalse);
      expect(cancelled.totalFiles, 10);
      expect(cancelled.completedFiles, 3);
    });
  });
}
