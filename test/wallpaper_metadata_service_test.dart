import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

import 'package:wall_sync/services/wallpaper_metadata_service.dart';

void main() {
  group('classifyResolution', () {
    test('classifies supported source dimensions instead of assuming 4K', () {
      expect(classifyResolution(1280, 720), 'HD');
      expect(classifyResolution(1920, 1080), 'Full HD');
      expect(classifyResolution(2560, 1440), '2K');
      expect(classifyResolution(2048, 1080), '2K');
      expect(classifyResolution(3840, 2160), '4K');
      expect(classifyResolution(4096, 2160), '4K');
      expect(classifyResolution(7680, 4320), '8K');
      expect(classifyResolution(15360, 8640), '16K');
    });

    test('reads image dimensions from original image headers', () {
      final png = Uint8List(24);
      png.setRange(0, 8, const [
        0x89,
        0x50,
        0x4e,
        0x47,
        0x0d,
        0x0a,
        0x1a,
        0x0a,
      ]);
      final header = ByteData.sublistView(png);
      header.setUint32(16, 3840, Endian.big);
      header.setUint32(20, 2160, Endian.big);

      expect(WallpaperMetadataService.readImageDimensions(png), (3840, 2160));
    });

    test(
      'preserves portrait classes and leaves other aspect ratios explicit',
      () {
        expect(classifyResolution(1080, 1920), 'Full HD');
        expect(classifyResolution(3440, 1440), 'Other');
        expect(classifyResolution(2000, 1200), 'Other');
      },
    );

    test('rejects unknown dimensions', () {
      expect(classifyResolution(0, 0), 'Resolution unavailable');
      expect(classifyResolution(-1920, 1080), 'Resolution unavailable');
    });

    test('treats malformed cached metadata as unavailable', () {
      final metadata = WallpaperMetadata.fromJson({
        'width': '3840',
        'height': 2160,
        'resolutionSource': 42,
        'resolutionVerified': true,
      });

      expect(metadata.width, 0);
      expect(metadata.height, 0);
      expect(metadata.label, 'Resolution unavailable');
      expect(metadata.source, 'unavailable');
      expect(metadata.verified, isFalse);
    });
  });
}
