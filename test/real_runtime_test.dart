import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wall_sync/services/mpv_runtime_resolver.dart';
import 'package:wall_sync/services/video_thumbnail_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('validates real bundled MPV distribution and generates authentic video thumbnail', () async {
    SharedPreferences.setMockInitialValues({});
    final resolver = MpvRuntimeResolver.instance;
    resolver.invalidateCache();

    final info = await resolver.resolve(refresh: true);
    expect(info.path, endsWith(r'plugins\mpv\mpv.exe'));
    expect(File(info.path).existsSync(), isTrue);
    expect(info.architecture, 'x64');
    expect(info.hasD3DCompiler, isTrue);
    expect(info.fileSizeBytes, greaterThan(100 * 1024 * 1024));

    final testVideo = File(
      r'C:\Users\achub\AppData\Roaming\com.example\wallsync\video_wallpapers\9b1a8ba82d1f492efea6df2b2cac52623105435e3305f3129b505841c0254321.mp4',
    );
    if (await testVideo.exists()) {
      final thumb = await VideoThumbnailService.instance.getThumbnailFile(
        testVideo.path,
        forceRegenerate: true,
      );
      expect(thumb, isNotNull);
      expect(await thumb!.exists(), isTrue);
      final length = await thumb.length();
      expect(length, greaterThan(1000));

      final bytes = await thumb.readAsBytes();
      // JPEG magic bytes: 0xFF, 0xD8
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xD8);
    }
  });
}
