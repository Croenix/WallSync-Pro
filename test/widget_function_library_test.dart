import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/media_session_service.dart';
import 'package:wall_sync/services/settings_service.dart';
import 'package:wall_sync/services/system_metrics_service.dart';
import 'package:wall_sync/services/widget_function_library.dart';

void main() {
  group('CustomWidgetElement Categorization & Properties', () {
    test('automatically categorizes elements into text, icon, image, container', () {
      final textElement = CustomWidgetElement(id: '1', type: 'custom_text', text: 'Hello');
      final hoursElement = CustomWidgetElement(id: '2', type: 'hours');
      final weatherTempElement = CustomWidgetElement(id: '3', type: 'weather_temp');
      final mediaTitleElement = CustomWidgetElement(id: '4', type: 'media_title');

      expect(textElement.category, equals(CustomWidgetElementCategory.text));
      expect(hoursElement.category, equals(CustomWidgetElementCategory.text));
      expect(weatherTempElement.category, equals(CustomWidgetElementCategory.text));
      expect(mediaTitleElement.category, equals(CustomWidgetElementCategory.text));

      final customIconElement = CustomWidgetElement(id: '5', type: 'custom_icon', iconCodePoint: 0xe871);
      final weatherIconElement = CustomWidgetElement(id: '6', type: 'weather_icon');
      final wifiIconElement = CustomWidgetElement(id: '7', type: 'wifi_icon');
      final bluetoothIconElement = CustomWidgetElement(id: '8', type: 'bluetooth_icon');

      expect(customIconElement.category, equals(CustomWidgetElementCategory.icon));
      expect(weatherIconElement.category, equals(CustomWidgetElementCategory.icon));
      expect(wifiIconElement.category, equals(CustomWidgetElementCategory.icon));
      expect(bluetoothIconElement.category, equals(CustomWidgetElementCategory.icon));

      final customImageElement = CustomWidgetElement(id: '9', type: 'custom_image', imagePath: 'C:/wallpapers/art.png');
      final albumArtElement = CustomWidgetElement(id: '10', type: 'custom_image', dataBinding: 'media.cover_art');

      expect(customImageElement.category, equals(CustomWidgetElementCategory.image));
      expect(albumArtElement.category, equals(CustomWidgetElementCategory.image));

      final neonBoxElement = CustomWidgetElement(id: '11', type: 'neon_box');
      final mediaPillElement = CustomWidgetElement(id: '12', type: 'media_pill');

      expect(neonBoxElement.category, equals(CustomWidgetElementCategory.container));
      expect(mediaPillElement.category, equals(CustomWidgetElementCategory.container));
    });

    test('serializes and deserializes new tailored control properties', () {
      final original = CustomWidgetElement(
        id: 'elem_test_1',
        type: 'custom_text',
        text: 'Telemetry Data',
        dataBinding: 'system.ram_percent',
        bindingFormat: 'prefix:RAM ;suffix:%',
        isItalic: true,
        textAlign: 'center',
        lineHeight: 1.4,
        iconCodePoint: 0xe871,
        iconFontFamily: 'MaterialIcons',
        imagePath: 'C:/assets/cover.png',
        imageFit: 'contain',
        cornerRadius: 16.0,
      );

      final json = original.toJson();
      final restored = CustomWidgetElement.fromJson(json);

      expect(restored.id, equals('elem_test_1'));
      expect(restored.type, equals('custom_text'));
      expect(restored.dataBinding, equals('system.ram_percent'));
      expect(restored.bindingFormat, equals('prefix:RAM ;suffix:%'));
      expect(restored.isItalic, isTrue);
      expect(restored.textAlign, equals('center'));
      expect(restored.lineHeight, closeTo(1.4, 0.001));
      expect(restored.iconCodePoint, equals(0xe871));
      expect(restored.iconFontFamily, equals('MaterialIcons'));
      expect(restored.imagePath, equals('C:/assets/cover.png'));
      expect(restored.imageFit, equals('contain'));
      expect(restored.cornerRadius, equals(16.0));
    });

    test('copyWith preserves and overrides new properties correctly', () {
      final element = CustomWidgetElement(
        id: '1',
        type: 'custom_text',
        dataBinding: 'system.cpu_percent',
        isItalic: false,
        textAlign: 'left',
      );

      final modified = element.copyWith(
        dataBinding: 'system.ram_percent',
        isItalic: true,
        textAlign: 'right',
        lineHeight: 1.6,
      );

      expect(modified.dataBinding, equals('system.ram_percent'));
      expect(modified.isItalic, isTrue);
      expect(modified.textAlign, equals('right'));
      expect(modified.lineHeight, closeTo(1.6, 0.001));
      expect(element.dataBinding, equals('system.cpu_percent'));
    });
  });

  group('LiveWidgetFunctionLibrary Functional Logic', () {
    test('contains comprehensive pre-defined library covering system, weather, time, and media', () {
      final definitions = LiveWidgetFunctionLibrary.definitions;
      expect(definitions.length, greaterThanOrEqualTo(25));

      final systemFuncs = LiveWidgetFunctionLibrary.getByCategory(LiveFunctionCategory.system);
      final weatherFuncs = LiveWidgetFunctionLibrary.getByCategory(LiveFunctionCategory.weather);
      final timeFuncs = LiveWidgetFunctionLibrary.getByCategory(LiveFunctionCategory.time);
      final mediaFuncs = LiveWidgetFunctionLibrary.getByCategory(LiveFunctionCategory.media);

      expect(systemFuncs.map((f) => f.id), containsAll(['system.ram_percent', 'system.cpu_percent', 'system.disk_used_percent', 'system.battery_percent']));
      expect(weatherFuncs.map((f) => f.id), containsAll(['weather.temp', 'weather.condition', 'weather.location', 'weather.apparent_temp', 'weather.humidity']));
      expect(timeFuncs.map((f) => f.id), containsAll(['time.hours_12', 'time.hours_24', 'time.minutes', 'time.seconds', 'time.ampm', 'time.full_date']));
      expect(mediaFuncs.map((f) => f.id), containsAll(['media.title', 'media.artist', 'media.album', 'media.status', 'media.cover_art']));
    });

    test('resolves system metrics correctly with live and fallback values', () {
      final ramFunc = LiveWidgetFunctionLibrary.getById('system.ram_percent')!;
      final cpuFunc = LiveWidgetFunctionLibrary.getById('system.cpu_percent')!;
      final batteryFunc = LiveWidgetFunctionLibrary.getById('system.battery_percent')!;
      final batteryStatusFunc = LiveWidgetFunctionLibrary.getById('system.battery_status')!;

      final resolvedRam = ramFunc.resolveText(
        dateTime: DateTime.now(),
        ramUsage: 64.2,
      );
      expect(resolvedRam, equals('64%'));

      final resolvedCpu = cpuFunc.resolveText(
        dateTime: DateTime.now(),
        cpuUsage: 18.7,
      );
      expect(resolvedCpu, equals('19%'));

      const battery = BatterySnapshot(
        percentage: 85,
        isCharging: true,
        isAcConnected: true,
        isAvailable: true,
        remainingSeconds: 3600,
      );

      final resolvedBattery = batteryFunc.resolveText(
        dateTime: DateTime.now(),
        batteryInfo: battery,
      );
      expect(resolvedBattery, equals('85%'));

      final resolvedBatteryStatus = batteryStatusFunc.resolveText(
        dateTime: DateTime.now(),
        batteryInfo: battery,
      );
      expect(resolvedBatteryStatus, equals('Charging'));
    });

    test('resolves weather data with Celsius, Fahrenheit, and formatting', () {
      final tempFunc = LiveWidgetFunctionLibrary.getById('weather.temp')!;
      final statusFunc = LiveWidgetFunctionLibrary.getById('weather.condition')!;
      final locationFunc = LiveWidgetFunctionLibrary.getById('weather.location')!;
      final humidityFunc = LiveWidgetFunctionLibrary.getById('weather.humidity')!;

      final celsius = tempFunc.resolveText(
        dateTime: DateTime.now(),
        weatherTemp: '24',
        weatherUnit: 'C',
      );
      expect(celsius, equals('24°C'));

      final fahrenheit = tempFunc.resolveText(
        dateTime: DateTime.now(),
        weatherTemp: '24',
        weatherUnit: 'F',
      );
      // 24C = 24 * 9/5 + 32 = 43.2 + 32 = 75.2 -> 75°F
      expect(fahrenheit, equals('75°F'));

      final condition = statusFunc.resolveText(
        dateTime: DateTime.now(),
        weatherStatus: 'Partly Cloudy',
      );
      expect(condition, equals('Partly Cloudy'));

      final location = locationFunc.resolveText(
        dateTime: DateTime.now(),
        weatherLocation: 'Tokyo, Japan',
      );
      expect(location, equals('Tokyo, Japan'));

      final humidity = humidityFunc.resolveText(
        dateTime: DateTime.now(),
        weatherHumidity: '68',
      );
      expect(humidity, equals('68%'));
    });

    test('resolves time components cleanly for 12h, 24h, minutes, am/pm, and date', () {
      final testTime = DateTime(2026, 11, 7, 14, 35, 9);

      final h12Func = LiveWidgetFunctionLibrary.getById('time.hours_12')!;
      final h24Func = LiveWidgetFunctionLibrary.getById('time.hours_24')!;
      final minFunc = LiveWidgetFunctionLibrary.getById('time.minutes')!;
      final secFunc = LiveWidgetFunctionLibrary.getById('time.seconds')!;
      final ampmFunc = LiveWidgetFunctionLibrary.getById('time.ampm')!;

      expect(h12Func.resolveText(dateTime: testTime), equals('02'));
      expect(h24Func.resolveText(dateTime: testTime), equals('14'));
      expect(minFunc.resolveText(dateTime: testTime), equals('35'));
      expect(secFunc.resolveText(dateTime: testTime), equals('09'));
      expect(ampmFunc.resolveText(dateTime: testTime), equals('PM'));
    });

    test('resolves media session playback metadata', () {
      final trackFunc = LiveWidgetFunctionLibrary.getById('media.title')!;
      final artistFunc = LiveWidgetFunctionLibrary.getById('media.artist')!;
      final albumFunc = LiveWidgetFunctionLibrary.getById('media.album')!;
      final statusFunc = LiveWidgetFunctionLibrary.getById('media.status')!;

      final media = MediaInfo(
        title: 'Cyber Drift',
        artist: 'Neon Wave',
        album: 'Synth City',
        status: 'Playing',
        position: 45,
        duration: 180,
      );

      expect(trackFunc.resolveText(dateTime: DateTime.now(), mediaInfo: media), equals('Cyber Drift'));
      expect(artistFunc.resolveText(dateTime: DateTime.now(), mediaInfo: media), equals('Neon Wave'));
      expect(albumFunc.resolveText(dateTime: DateTime.now(), mediaInfo: media), equals('Synth City'));
      expect(statusFunc.resolveText(dateTime: DateTime.now(), mediaInfo: media), equals('Playing'));
    });

    test('applies custom format prefix and suffix', () {
      final ramFunc = LiveWidgetFunctionLibrary.getById('system.ram_percent')!;

      final formatted = ramFunc.resolveText(
        dateTime: DateTime.now(),
        ramUsage: 48.0,
        formatPrefix: '⚡ RAM: ',
        formatSuffix: ' (Peak)',
      );

      expect(formatted, equals('⚡ RAM: 48% (Peak)'));
    });
  });
}
