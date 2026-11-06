import 'dart:convert';
import 'dart:io';

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

  test('Always on Top can be disabled and survives settings round-trip', () {
    final settings = WidgetSettings(
      alwaysOnTop: true,
    ).copyWith(alwaysOnTop: false);
    final restored = WidgetSettings.fromJson(settings.toJson());

    expect(restored.alwaysOnTop, isFalse);
  });

  test('weather detail values persist for custom widget elements', () {
    final settings = WidgetSettings(
      weatherTemp: '24.5',
      weatherStatus: 'Clear',
      weatherApparentTemp: '26.0',
      weatherHumidity: 58,
      weatherLocationResolved: 'Seattle, Washington',
      weatherForecastJson:
          '[{"time":"14:00","temp":"24.0","status":"Clear","code":0}]',
    );

    final restored = WidgetSettings.fromJson(settings.toJson());

    expect(restored.weatherApparentTemp, '26.0');
    expect(restored.weatherHumidity, 58);
    expect(restored.weatherLocationResolved, 'Seattle, Washington');
    expect(restored.weatherForecastJson, settings.weatherForecastJson);
  });

  test('invalid saved widget dimensions recover to template defaults', () {
    final settings = WidgetSettings(
      widgetTemplate: 'cyber',
      width: 220.0,
      height: 44.0,
    );

    final recovered = settings.normalizedWindowSize();

    expect(recovered.width, 220.0);
    expect(recovered.height, 280.0);
  });

  test('valid custom widget dimensions are preserved', () {
    final settings = WidgetSettings(
      widgetTemplate: 'atomic_clock',
      width: 220.0,
      height: 100.0,
    );

    final normalized = settings.normalizedWindowSize();

    expect(identical(normalized, settings), isTrue);
    expect(normalized.width, 220.0);
    expect(normalized.height, 100.0);
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

  test('intentionally empty custom canvases survive settings round-trip', () {
    final settings = WidgetSettings(
      widgetTemplate: 'custom',
      customElements: [],
      savedCustomWidgets: [
        SavedCustomWidget(
          id: 'empty-design',
          name: 'Blank Design',
          elements: [],
        ),
      ],
    );

    final restored = WidgetSettings.fromJson(settings.toJson());

    expect(restored.customElements, isEmpty);
    expect(restored.savedCustomWidgets.single.elements, isEmpty);
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

  test('custom element studio transforms and styling round-trip', () {
    final element = CustomWidgetElement(
      id: 'styled-title',
      type: 'custom_text',
      rotationX: 24,
      rotationY: -18,
      rotation: 12,
      scaleX: 1.2,
      scaleY: 0.8,
      depth: 16,
      cornerRadius: 9,
      strokeWidth: 2,
      strokeColor: 0xFF123456,
      shadowColor: 0xFF654321,
      shadowBlur: 11,
      shadowOffsetX: 3,
      shadowOffsetY: 5,
      gradientRadial: true,
      gradientColors: [0xFF112233, 0xFF445566, 0xFF778899],
      animationType: 'pulse',
      weatherUnit: 'F',
    );

    final restored = CustomWidgetElement.fromJson(element.toJson());
    final copied = restored.copyWith(rotationX: 40);

    expect(restored.rotationX, 24);
    expect(restored.rotationY, -18);
    expect(restored.rotation, 12);
    expect(restored.scaleX, 1.2);
    expect(restored.scaleY, 0.8);
    expect(restored.depth, 16);
    expect(restored.cornerRadius, 9);
    expect(restored.strokeWidth, 2);
    expect(restored.strokeColor, 0xFF123456);
    expect(restored.shadowColor, 0xFF654321);
    expect(restored.shadowBlur, 11);
    expect(restored.shadowOffsetX, 3);
    expect(restored.shadowOffsetY, 5);
    expect(restored.gradientRadial, isTrue);
    expect(restored.gradientColors, [0xFF112233, 0xFF445566, 0xFF778899]);
    expect(restored.animationType, 'pulse');
    expect(restored.weatherUnit, 'F');
    expect(copied.rotationX, 40);
    expect(copied.animationType, 'pulse');
  });

  test('older custom elements use safe studio defaults', () {
    final element = CustomWidgetElement.fromJson({
      'id': 'legacy',
      'type': 'custom_text',
    });

    expect(element.rotationX, 0);
    expect(element.rotationY, 0);
    expect(element.scaleX, 1);
    expect(element.scaleY, 1);
    expect(element.depth, 0);
    expect(element.cornerRadius, 0);
    expect(element.strokeWidth, 0);
    expect(element.animationType, 'none');
    expect(element.weatherUnit, 'C');
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

  test('settings watcher accepts atomic replacement events only', () {
    expect(
      SettingsService.matchesSettingsFileWatchEvent(
        r'C:\Wallsync\overlay_settings_classic.json',
        'overlay_settings_classic.json',
      ),
      isTrue,
    );
    expect(
      SettingsService.matchesSettingsFileWatchEvent(
        r'C:\Wallsync\overlay_settings_classic.json.123.456.tmp',
        'overlay_settings_classic.json',
      ),
      isTrue,
    );
    expect(
      SettingsService.matchesSettingsFileWatchEvent(
        r'C:\Wallsync\overlay_settings_other.json.123.456.tmp',
        'overlay_settings_classic.json',
      ),
      isFalse,
    );
    expect(
      SettingsService.matchesSettingsFileWatchEvent(
        r'C:\Wallsync\overlay_classic.pid',
        'overlay_settings_classic.json',
      ),
      isFalse,
    );
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
      final settingsFile = await service.settingsFile;
      final persisted =
          jsonDecode(await settingsFile.readAsString()) as Map<String, dynamic>;
      expect(persisted['activeWallpaperPath'], 'path2');
    },
  );

  test(
    'settings writes for different widget records do not block each other',
    () async {
      final blockedService = SettingsService(instanceId: 'test_blocked_write');
      final independentService = SettingsService(
        instanceId: 'test_independent_write',
      );
      final blockedFile = await blockedService.settingsFile;
      final independentFile = await independentService.settingsFile;
      final blockedLockFile = await blockedService.lockFile;
      final blockedLock = await blockedLockFile.open(mode: FileMode.append);

      try {
        await blockedLock.lock(FileLock.exclusive);
        final blockedWrite = blockedService.saveSettings(
          WidgetSettings(activeWallpaperPath: 'blocked'),
          immediate: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        await independentService
            .saveSettings(
              WidgetSettings(activeWallpaperPath: 'independent'),
              immediate: true,
            )
            .timeout(const Duration(seconds: 1));
        expect(await independentFile.exists(), isTrue);

        await blockedLock.unlock();
        await blockedWrite.timeout(const Duration(seconds: 10));
        expect(await blockedFile.exists(), isTrue);
      } finally {
        try {
          await blockedLock.unlock();
        } on FileSystemException {
          // The lock was already released before the pending write completed.
        }
        await blockedLock.close();
        if (await blockedFile.exists()) await blockedFile.delete();
        if (await blockedLockFile.exists()) await blockedLockFile.delete();
        if (await independentFile.exists()) await independentFile.delete();
        final independentLockFile = await independentService.lockFile;
        if (await independentLockFile.exists()) {
          await independentLockFile.delete();
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'concurrent settings updates preserve independent customization and bounds changes',
    () async {
      const instanceId = 'test_atomic_settings_update';
      final settingsService = SettingsService(instanceId: instanceId);
      final customizationWriter = SettingsService(instanceId: instanceId);
      final overlayWriter = SettingsService(instanceId: instanceId);
      final settingsFile = await settingsService.settingsFile;
      final settingsLockFile = File(
        '${settingsFile.parent.path}\\overlay_settings_$instanceId.lock',
      );
      try {
        await settingsService.saveSettings(
          WidgetSettings(widgetTemplate: 'robik'),
          immediate: true,
        );

        await Future.wait([
          customizationWriter.updateSettings(
            (current) =>
                current.copyWith(elementColors: {ElementKey.hours: 0xFF123456}),
          ),
          overlayWriter.updateSettings(
            (current) => current.copyWith(posX: 321.0, posY: 123.0),
          ),
        ]);

        final restored = WidgetSettings.fromJson(
          jsonDecode(await settingsFile.readAsString()) as Map<String, dynamic>,
        );
        expect(restored.elementColors[ElementKey.hours], 0xFF123456);
        expect(restored.posX, 321.0);
        expect(restored.posY, 123.0);
      } finally {
        if (await settingsFile.exists()) await settingsFile.delete();
        if (await settingsLockFile.exists()) await settingsLockFile.delete();
      }
    },
  );
}
