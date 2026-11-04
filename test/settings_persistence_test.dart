import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/settings_service.dart';

void main() {
  test('startup is enabled for fresh settings and saved opt-outs persist', () {
    expect(WidgetSettings().startOnBoot, isTrue);
    expect(
      WidgetSettings.fromJson({'startOnBoot': false}).startOnBoot,
      isFalse,
    );
    expect(
      WidgetSettings.fromJson({}).startOnBoot,
      isFalse,
      reason: 'Older saved settings without the key keep the previous default.',
    );
  });

  test(
    'saved wallpaper and explicit widget opt-out survive restoration loads',
    () {
      final settings = WidgetSettings(
        activeWallpaperType: 'video',
        activeWallpaperPath: r'C:\Wallpapers\saved-video.mp4',
        exitOverlay: true,
        startOnBoot: false,
      );

      final restored = WidgetSettings.fromJson(settings.toJson());

      expect(restored.activeWallpaperType, 'video');
      expect(restored.activeWallpaperPath, settings.activeWallpaperPath);
      expect(restored.exitOverlay, isTrue);
      expect(restored.startOnBoot, isFalse);
    },
  );

  test('widget customizations survive template changes and persistence', () {
    final original = WidgetSettings(
      widgetTemplate: 'classic',
      elementColors: {ElementKey.hours: 0xFF123456},
      elementFonts: {ElementKey.hours: 'Consolas'},
      elementSizes: {ElementKey.hours: 1.4},
      elementTranslateX: {ElementKey.hours: 12.0},
      elementRotateZ: {ElementKey.hours: 8.0},
      colorPalette: [0xFF123456, 0xFF654321],
      customGradientColors: [0xFF112233, 0xFF445566],
      separatorWidth: 96.0,
      separatorHeight: 3.0,
    );

    final selectedTemplate = original.copyWith(
      widgetTemplate: 'minimal',
      width: 300.0,
      height: 100.0,
      sizeFactor: 1.0,
    );
    final restored = WidgetSettings.fromJson(selectedTemplate.toJson());

    expect(restored.widgetTemplate, 'minimal');
    expect(restored.elementColors, original.elementColors);
    expect(restored.elementFonts, original.elementFonts);
    expect(restored.elementSizes, original.elementSizes);
    expect(restored.elementTranslateX, original.elementTranslateX);
    expect(restored.elementRotateZ, original.elementRotateZ);
    expect(restored.colorPalette, original.colorPalette);
    expect(restored.customGradientColors, original.customGradientColors);
    expect(restored.separatorWidth, original.separatorWidth);
    expect(restored.separatorHeight, original.separatorHeight);
  });

  test('editing the active custom layout does not overwrite saved designs', () {
    final savedDesign = SavedCustomWidget(
      id: 'saved-clock',
      name: 'Saved Clock',
      elements: [
        CustomWidgetElement(
          id: 'saved-hours',
          type: 'hours',
          text: 'original',
          color: 0xFFFFFFFF,
        ),
      ],
    );
    final activeElements =
        savedDesign.elements.map((element) => element.copyWith()).toList()
          ..first.text = 'edited';
    final editedSettings = WidgetSettings(
      widgetTemplate: 'custom',
      customElements: activeElements,
      savedCustomWidgets: [savedDesign],
    );
    final currentOnlyUpdate = editedSettings.copyWith(
      customElements: activeElements,
    );
    final restored = WidgetSettings.fromJson(currentOnlyUpdate.toJson());

    expect(restored.customElements.single.text, 'edited');
    expect(restored.savedCustomWidgets.single.id, savedDesign.id);
    expect(restored.savedCustomWidgets.single.elements.single.text, 'original');
  });

  test('custom element active and disabled colors persist independently', () {
    final element = CustomWidgetElement(
      id: 'wifi',
      type: 'wifi_icon',
      color: 0xFFFFFFFF,
      activeColor: 0xFF00FF00,
      disabledColor: 0xFFFF0000,
    );
    final restored = CustomWidgetElement.fromJson(element.toJson());
    final copied = restored.copyWith(color: 0xFF123456);

    expect(restored.activeColor, 0xFF00FF00);
    expect(restored.disabledColor, 0xFFFF0000);
    expect(copied.color, 0xFF123456);
    expect(copied.activeColor, restored.activeColor);
    expect(copied.disabledColor, restored.disabledColor);
  });

  test('recent wallpapers serialize and deserialize correctly', () {
    final original = WidgetSettings(
      recentWallpapers: [
        RecentWallpaperItem(
          id: 'vid_1',
          name: 'Neon Cyber City',
          pathOrUrl: 'https://example.com/neon.mp4',
          type: 'video',
          thumbnailUrl: 'https://example.com/neon.jpg',
          timestamp: 1729000000000,
        ),
        RecentWallpaperItem(
          id: 'static_1',
          name: 'Aurora Borealis',
          pathOrUrl: r'C:\Wallpapers\aurora.png',
          type: 'static',
          thumbnailUrl: null,
          timestamp: 1729000005000,
        ),
      ],
    );

    final json = original.toJson();
    final restored = WidgetSettings.fromJson(json);

    expect(restored.recentWallpapers.length, 2);
    expect(restored.recentWallpapers[0].id, 'vid_1');
    expect(restored.recentWallpapers[0].name, 'Neon Cyber City');
    expect(restored.recentWallpapers[0].isVideo, true);
    expect(restored.recentWallpapers[0].isLocal, false);
    expect(restored.recentWallpapers[1].id, 'static_1');
    expect(restored.recentWallpapers[1].name, 'Aurora Borealis');
    expect(restored.recentWallpapers[1].isVideo, false);
    expect(restored.recentWallpapers[1].isLocal, true);
  });

  test('atomic_clock template defaults and font resolution', () {
    final defaults = WidgetSettings.templateDefaults['atomic_clock'];
    expect(defaults, isNotNull);
    expect(defaults!['width'], 440.0);
    expect(defaults['height'], 220.0);

    final settings = WidgetSettings(widgetTemplate: 'atomic_clock');
    expect(settings.fontFor(ElementKey.day), 'Anurati');
    expect(settings.fontFor(ElementKey.date), 'Anurati');
    expect(settings.fontFor(ElementKey.hours), 'Anurati');

    final customized = settings.copyWith(
      elementColors: {
        ElementKey.hours: 0xFF123456,
        ElementKey.minutes: 0xFF654321,
      },
      elementFonts: {ElementKey.hours: 'Segoe UI'},
      elementSizes: {ElementKey.minutes: 1.4},
    );
    expect(customized.fontFor(ElementKey.hours), 'Segoe UI');
    expect(customized.sizeFor(ElementKey.minutes, 16), 22.4);
    expect(customized.colorFor(ElementKey.hours), 0xFF123456);

    final json = customized.toJson();
    final restored = WidgetSettings.fromJson(json);
    expect(restored.widgetTemplate, 'atomic_clock');
    expect(restored.colorFor(ElementKey.minutes), 0xFF654321);
    expect(restored.fontFor(ElementKey.hours), 'Segoe UI');
    expect(restored.sizeFor(ElementKey.minutes, 16), 22.4);
  });

  test('retired taskbar widgets migrate to standard widget state', () {
    final restored = WidgetSettings.fromJson({
      'widgetTemplate': 'taskbar_dock',
      'activeWidgetIds': ['taskbar_dock', 'classic'],
    });

    expect(restored.widgetTemplate, 'classic');
    expect(restored.activeWidgetIds, ['classic']);

    final dockOnly = WidgetSettings.fromJson({
      'widgetTemplate': 'taskbar_dock',
      'activeWidgetIds': ['taskbar_dock'],
    });
    expect(dockOnly.widgetTemplate, 'classic');
    expect(dockOnly.activeWidgetIds, isEmpty);
  });

  test(
    'element and global gradient settings serialize, deserialize, and resolve correctly',
    () {
      final settings = WidgetSettings(
        elementGradients: {
          ElementKey.hours: [0xFF00F0FF, 0xFFD946EF],
        },
        useGlobalGradient: true,
        globalGradientColors: [0xFFFF512F, 0xFFDD2476],
      );

      // Specific element gradient overrides global gradient
      expect(settings.gradientFor(ElementKey.hours), [0xFF00F0FF, 0xFFD946EF]);

      // Other typography elements inherit global gradient
      expect(settings.gradientFor(ElementKey.minutes), [
        0xFFFF512F,
        0xFFDD2476,
      ]);
      expect(settings.gradientFor(ElementKey.day), [0xFFFF512F, 0xFFDD2476]);

      // Container frames do not inherit global text gradient automatically
      expect(settings.gradientFor(ElementKey.neonBox), isNull);
      expect(settings.gradientFor(ElementKey.innerBackground), isNull);

      // Serialization & Deserialization
      final json = settings.toJson();
      final restored = WidgetSettings.fromJson(json);

      expect(restored.useGlobalGradient, true);
      expect(restored.globalGradientColors, [0xFFFF512F, 0xFFDD2476]);
      expect(restored.elementGradients[ElementKey.hours], [
        0xFF00F0FF,
        0xFFD946EF,
      ]);
      expect(restored.gradientFor(ElementKey.hours), [0xFF00F0FF, 0xFFD946EF]);
    },
  );

  test('SettingsService getAppDirectory is memoized', () async {
    final service = SettingsService();
    final dir1 = await service.getAppDirectory();
    final dir2 = await service.getAppDirectory();
    expect(identical(dir1, dir2), isTrue);
  });

  test(
    'widget template defaults contain valid dimensions for all templates',
    () {
      final defaults = WidgetSettings.templateDefaults;

      for (final entry in defaults.entries) {
        final key = entry.key;
        final val = entry.value;
        expect(val['width'], isNotNull, reason: '$key has width');
        expect(val['height'], isNotNull, reason: '$key has height');
        expect(val['sizeFactor'], isNotNull, reason: '$key has sizeFactor');
        expect(val['width']! > 0, isTrue);
        expect(val['height']! > 0, isTrue);

        if (key.startsWith('taskbar_')) {
          expect(
            val['height']! <= 50.0,
            isTrue,
            reason: '$key compact taskbar height',
          );
          expect(
            val['height']! >= 36.0,
            isTrue,
            reason: '$key taskbar height minimum',
          );
        }
      }
    },
  );

  test(
    'SettingsService saveSettings updates in-memory cache immediately and coalesces debounced writes',
    () async {
      final service = SettingsService(instanceId: 'test_debounce_coalesce');
      final s1 = WidgetSettings(
        startOnBoot: false,
        activeWallpaperPath: 'path1',
      );
      final s2 = WidgetSettings(
        startOnBoot: false,
        activeWallpaperPath: 'path2',
      );

      // Calling saveSettings updates cache synchronously in memory
      final f1 = service.saveSettings(s1);
      expect((await service.loadSettings()).activeWallpaperPath, 'path1');

      final f2 = service.saveSettings(s2);
      expect((await service.loadSettings()).activeWallpaperPath, 'path2');

      // Flush pending saves immediately
      await SettingsService.flushPendingSaves();
      await Future.wait([f1, f2]);

      expect((await service.loadSettings()).activeWallpaperPath, 'path2');
    },
  );
}
