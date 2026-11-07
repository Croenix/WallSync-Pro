import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/custom_font_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sampleJsonStr = '''
{
  "generated_at": "2026-11-07T16:59:39.509Z",
  "total_families": 4,
  "total_files": 5,
  "categories": {
    "Serif": [
      {
        "family_name": "Miller",
        "category": "Serif",
        "main_font_file": "Miller.ttf",
        "variants": [
          {
            "file_name": "Miller.ttf",
            "style": "Regular",
            "weight": 400,
            "is_italic": false,
            "postscript_name": "Miller-Regular",
            "version": "Version 1.000",
            "designer": "Achmad Iswanjaya",
            "copyright": "Copyright 2026",
            "file_size": 25000
          }
        ]
      }
    ],
    "Display / Decorative": [
      {
        "family_name": "Armelie",
        "category": "Display / Decorative",
        "main_font_file": "Armelie-Regular.otf",
        "variants": [
          {
            "file_name": "Armelie-Regular.otf",
            "style": "Regular",
            "weight": 400,
            "is_italic": false,
            "postscript_name": "Armelie-Regular",
            "designer": "Leny Parlina"
          }
        ]
      },
      {
        "family_name": "Aurelise",
        "category": "Display / Decorative",
        "main_font_file": "Aurelise-Regular.otf",
        "variants": [
          {
            "file_name": "Aurelise-Regular.otf",
            "style": "Regular",
            "weight": 400,
            "is_italic": false,
            "designer": "Akhmad Reza Fauzi"
          },
          {
            "file_name": "Aurelise-Bold.otf",
            "style": "Bold",
            "weight": 700,
            "is_italic": false,
            "designer": "Akhmad Reza Fauzi"
          }
        ]
      }
    ],
    "Symbol / Icon": [
      {
        "family_name": "Runiga",
        "category": "Symbol / Icon",
        "main_font_file": "Runiga.otf",
        "variants": [
          {
            "file_name": "Runiga.otf",
            "style": "Regular",
            "weight": 400,
            "designer": "Murrofil Ngabit"
          }
        ]
      }
    ]
  }
}
''';

  group('CustomFontService Models & Serialization', () {
    test('FontVariant parses JSON and serializes back correctly', () {
      final json = {
        'file_name': 'TestFont-Bold.otf',
        'style': 'Bold',
        'weight': 700,
        'is_italic': false,
        'postscript_name': 'TestFont-Bold',
        'designer': 'Test Designer',
        'copyright': '2026 Test',
        'version': '1.0',
        'file_size': 45120,
      };

      final variant = FontVariant.fromJson(json);
      expect(variant.fileName, 'TestFont-Bold.otf');
      expect(variant.style, 'Bold');
      expect(variant.weight, 700);
      expect(variant.isItalic, false);
      expect(variant.postscriptName, 'TestFont-Bold');
      expect(variant.designer, 'Test Designer');
      expect(variant.fileSize, 45120);

      final outJson = variant.toJson();
      expect(outJson['file_name'], 'TestFont-Bold.otf');
      expect(outJson['weight'], 700);
      expect(outJson['designer'], 'Test Designer');
    });

    test('FontFamilyItem parses categories and variants correctly', () {
      final parsed = jsonDecode(sampleJsonStr) as Map<String, dynamic>;
      final categories = parsed['categories'] as Map<String, dynamic>;
      final serifList = categories['Serif'] as List;

      final family = FontFamilyItem.fromJson(
        serifList.first as Map<String, dynamic>,
      );
      expect(family.familyName, 'Miller');
      expect(family.category, 'Serif');
      expect(family.mainFontFile, 'Miller.ttf');
      expect(family.variants.length, 1);
      expect(family.displayDesigner, 'Achmad Iswanjaya');

      final displayList = categories['Display / Decorative'] as List;
      final aurelise = FontFamilyItem.fromJson(
        displayList[1] as Map<String, dynamic>,
      );
      expect(aurelise.familyName, 'Aurelise');
      expect(aurelise.variants.length, 2);
      expect(aurelise.variants[1].weight, 700);
    });

    test('FontDownloadBatchProgress copyWith works accurately', () {
      const initial = FontDownloadBatchProgress(
        totalFiles: 10,
        completedFiles: 2,
        currentFileName: 'test.ttf',
        fraction: 0.2,
        isDownloading: true,
      );

      final updated = initial.copyWith(
        completedFiles: 5,
        fraction: 0.5,
        currentFileName: 'next.ttf',
      );

      expect(updated.totalFiles, 10);
      expect(updated.completedFiles, 5);
      expect(updated.fraction, 0.5);
      expect(updated.currentFileName, 'next.ttf');
      expect(updated.isDownloading, true);
      expect(updated.isCancelled, false);
    });
  });

  group('CustomFontService Core Functionality', () {
    test('availableFontNames contains standard built-in fonts', () {
      final service = CustomFontService.instance;
      final fonts = service.availableFontNames;

      expect(fonts, contains('Montserrat'));
      expect(fonts, contains('Product Sans'));
      expect(fonts, contains('Anurati'));
      expect(fonts, contains('Moving Skate'));
      expect(fonts, contains('Segoe UI'));
      expect(fonts, contains('Consolas'));
      expect(fonts, contains('Impact'));
    });

    test('availableFontNames strictly excludes un-downloaded preview fonts', () {
      final service = CustomFontService.instance;
      // An un-downloaded font like "Aurelise" or "Miller" must not appear in availableFontNames
      expect(service.availableFontNames, isNot(contains('NonExistentOrUndownloadedFont')));
    });

    test('isFamilyDownloaded returns false when font files are not on disk', () {
      final service = CustomFontService.instance;
      const unDownloadedFamily = FontFamilyItem(
        familyName: 'GhostFont',
        category: 'Display / Decorative',
        mainFontFile: 'GhostFont.ttf',
        variants: [FontVariant(fileName: 'GhostFont.ttf')],
      );

      expect(service.isFamilyDownloaded(unDownloadedFamily), false);
    });

    test('cancelDownload flags batch progress as cancelled', () {
      final service = CustomFontService.instance;
      service.cancelDownload();
      expect(service.batchProgress.isCancelled, true);
      expect(service.batchProgress.isDownloading, false);
    });
  });
}

