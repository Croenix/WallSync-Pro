import 'dart:io';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/settings_service.dart';
import 'package:wall_sync/services/system_optimizer_service.dart';
import 'package:wall_sync/services/device_optimization_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late SettingsService settingsService;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'wallsync_device_opt_test_',
    );
    settingsService = SettingsService(instanceId: 'test_opt_instance');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('WidgetSettings Device Optimization & Sizing Properties', () {
    test('Default values are initialized correctly', () {
      final settings = WidgetSettings();

      expect(settings.autoSizing, isTrue);
      expect(settings.isLocked, isFalse);
      expect(settings.performanceProfile, equals('balanced'));
      expect(settings.wallpaperFpsLimit, equals(60));
      expect(settings.widgetRefreshIntervalMs, equals(1000));
      expect(settings.pauseInactiveAnimations, isTrue);
      expect(settings.imageCacheLimitMb, equals(24));
      expect(settings.optimizationHistory, isEmpty);
    });

    test('toJson and fromJson preserves all optimization fields', () {
      final initial = WidgetSettings(
        autoSizing: false,
        isLocked: true,
        performanceProfile: 'performance',
        wallpaperFpsLimit: 120,
        widgetRefreshIntervalMs: 500,
        pauseInactiveAnimations: false,
        imageCacheLimitMb: 48,
        optimizationHistory: [
          {
            'success': true,
            'ramFreedMb': 42.5,
            'beforeWorkingSetMb': 250.0,
            'afterWorkingSetMb': 207.5,
            'actionsTaken': ['Trimmed working set'],
            'timestamp': '2026-10-31T12:00:00.000',
          },
        ],
      );

      final json = initial.toJson();
      final restored = WidgetSettings.fromJson(json);

      expect(restored.autoSizing, isFalse);
      expect(restored.isLocked, isTrue);
      expect(restored.performanceProfile, equals('performance'));
      expect(restored.wallpaperFpsLimit, equals(120));
      expect(restored.widgetRefreshIntervalMs, equals(500));
      expect(restored.pauseInactiveAnimations, isFalse);
      expect(restored.imageCacheLimitMb, equals(48));
      expect(restored.optimizationHistory.length, equals(1));
      expect(restored.optimizationHistory.first['ramFreedMb'], equals(42.5));
    });

    test('copyWith properly updates specific optimization properties', () {
      final original = WidgetSettings();
      final updated = original.copyWith(
        autoSizing: false,
        isLocked: true,
        performanceProfile: 'power_saver',
        wallpaperFpsLimit: 30,
      );

      expect(updated.autoSizing, isFalse);
      expect(updated.isLocked, isTrue);
      expect(updated.performanceProfile, equals('power_saver'));
      expect(updated.wallpaperFpsLimit, equals(30));
      // Unmodified properties should remain intact
      expect(updated.widgetRefreshIntervalMs, equals(1000));
      expect(updated.imageCacheLimitMb, equals(24));
    });
  });

  group('DeviceOptimizationService Profiles and Actions', () {
    test('image cache bounds follow the selected memory limit', () {
      final service = DeviceOptimizationService.instance;
      service.applyImageCacheLimit(12);

      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        equals(12 * 1024 * 1024),
      );
      expect(PaintingBinding.instance.imageCache.maximumSize, equals(12));

      service.applyImageCacheLimit(80);
      expect(
        PaintingBinding.instance.imageCache.maximumSizeBytes,
        equals(64 * 1024 * 1024),
      );
      expect(PaintingBinding.instance.imageCache.maximumSize, equals(64));
      service.applyImageCacheLimit(24);
    });

    test('PerformanceProfileConfig contains all 4 standard profiles', () {
      final profiles = PerformanceProfileConfig.profiles;
      expect(profiles.containsKey('balanced'), isTrue);
      expect(profiles.containsKey('performance'), isTrue);
      expect(profiles.containsKey('power_saver'), isTrue);
      expect(profiles.containsKey('high_quality'), isTrue);

      final balanced = profiles['balanced']!;
      expect(balanced.wallpaperFpsLimit, equals(60));
      expect(balanced.widgetRefreshIntervalMs, equals(1000));
      expect(balanced.imageCacheLimitMb, equals(24));

      final perf = profiles['performance']!;
      expect(perf.wallpaperFpsLimit, equals(120));
      expect(perf.widgetRefreshIntervalMs, equals(500));
      expect(perf.boostPriority, isTrue);

      final power = profiles['power_saver']!;
      expect(power.wallpaperFpsLimit, equals(30));
      expect(power.widgetRefreshIntervalMs, equals(2000));
      expect(power.lowPowerMode, isTrue);
    });

    test('applyProfile updates settings and persists configuration', () async {
      final current = await settingsService.loadSettings();
      final updated = await DeviceOptimizationService.instance.applyProfile(
        profileId: 'power_saver',
        currentSettings: current,
        settingsService: settingsService,
      );

      expect(updated.performanceProfile, equals('power_saver'));
      expect(updated.wallpaperFpsLimit, equals(30));
      expect(updated.widgetRefreshIntervalMs, equals(2000));
      expect(updated.imageCacheLimitMb, equals(12));

      // Verify persistence by reloading
      final reloaded = await settingsService.loadSettings();
      expect(reloaded.performanceProfile, equals('power_saver'));
      expect(reloaded.wallpaperFpsLimit, equals(30));
    });

    test('restoreDefaults resets to balanced baseline', () async {
      await settingsService.updateSettings(
        (c) => c.copyWith(
          performanceProfile: 'custom',
          wallpaperFpsLimit: 15,
          widgetRefreshIntervalMs: 5000,
          autoSizing: false,
        ),
      );

      final restored = await DeviceOptimizationService.instance.restoreDefaults(
        settingsService: settingsService,
      );

      expect(restored.performanceProfile, equals('balanced'));
      expect(restored.wallpaperFpsLimit, equals(60));
      expect(restored.widgetRefreshIntervalMs, equals(1000));
      expect(restored.autoSizing, isTrue);
    });

    test('overall optimization records entry in optimizationHistory', () async {
      final current = await settingsService.loadSettings();
      final result = await DeviceOptimizationService.instance
          .optimizeOverallPerformance(
            currentSettings: current,
            settingsService: settingsService,
          );

      expect(result.success, isTrue);
      expect(result.ramFreedMb, isNonNegative);
      expect(result.actionsTaken, isNotEmpty);

      final reloaded = await settingsService.loadSettings();
      expect(reloaded.optimizationHistory, isNotEmpty);
      expect(
        reloaded.optimizationHistory.first['ramFreedMb'],
        equals(result.ramFreedMb),
      );
    });
  });

  group('Native Model Mapping', () {
    test('WindowsVersionInfo maps fields correctly', () {
      final map = <Object?, Object?>{
        'productName': 'Windows 11 Pro',
        'displayVersion': '23H2',
        'build': 22631,
        'ubr': 4317,
        'isWindows11': true,
        'supportsEcoQoS': true,
        'processorCount': 16,
      };

      final info = WindowsVersionInfo.fromMap(map);
      expect(info.productName, equals('Windows 11 Pro'));
      expect(info.displayVersion, equals('23H2'));
      expect(info.build, equals(22631));
      expect(info.ubr, equals(4317));
      expect(info.isWindows11, isTrue);
      expect(info.supportsEcoQoS, isTrue);
      expect(info.processorCount, equals(16));
    });

    test('WindowsProcessInfo maps fields correctly', () {
      final map = <Object?, Object?>{
        'pid': 1234,
        'name': 'WallSync.exe',
        'threads': 24,
        'workingSetMb': 64.5,
        'privateMb': 128.0,
        'isWallSync': true,
        'isCurrentProcess': true,
      };

      final proc = WindowsProcessInfo.fromMap(map);
      expect(proc.pid, equals(1234));
      expect(proc.name, equals('WallSync.exe'));
      expect(proc.threads, equals(24));
      expect(proc.workingSetMb, equals(64.5));
      expect(proc.privateMb, equals(128.0));
      expect(proc.isWallSync, isTrue);
      expect(proc.isCurrentProcess, isTrue);
    });
  });
}
