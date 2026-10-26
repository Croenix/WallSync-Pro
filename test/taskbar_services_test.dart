import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/discord_ipc_service.dart';
import 'package:wall_sync/services/steam_monitor_service.dart';
import 'package:wall_sync/services/settings_service.dart';

void main() {
  group('DiscordIpcService Tests', () {
    test('Singleton exists and produces valid snapshot', () {
      final service = DiscordIpcService.instance;
      expect(service, isNotNull);
      final snap = service.current;
      expect(snap, isA<DiscordVoiceSnapshot>());
    });

    test('toggleMute updates snapshot mute state', () {
      final service = DiscordIpcService.instance;
      final initialMute = service.current.isMuted;
      service.toggleMute();
      expect(service.current.isMuted, !initialMute);
      service.toggleMute();
      expect(service.current.isMuted, initialMute);
    });

    test('setMockChannel updates voice presence', () {
      final service = DiscordIpcService.instance;
      service.setMockChannel('Squad Voice', ping: 22, speaking: true);
      expect(service.current.isConnectedToVoice, isTrue);
      expect(service.current.channelName, 'Squad Voice');
      expect(service.current.pingMs, 22);
      expect(service.current.isSpeaking, isTrue);
    });
  });

  group('SteamMonitorService Tests', () {
    test('Singleton exists and produces valid snapshot', () {
      final service = SteamMonitorService.instance;
      expect(service, isNotNull);
      final snap = service.current;
      expect(snap, isA<SteamDownloadSnapshot>());
    });

    test('setMockDownload updates download snapshot', () {
      final service = SteamMonitorService.instance;
      service.setMockDownload(
        title: 'Cyberpunk 2077',
        speedMBs: 48.5,
        progress: 0.85,
      );
      expect(service.current.isDownloading, isTrue);
      expect(service.current.gameTitle, 'Cyberpunk 2077');
      expect(service.current.downloadSpeedMBs, 48.5);
      expect(service.current.progressPercent, 0.85);
    });

    test('resetToIdle resets download status', () {
      final service = SteamMonitorService.instance;
      service.resetToIdle();
      expect(service.current.isDownloading, isFalse);
    });
  });

  group('Taskbar Template Presets Tests', () {
    final expectedTemplates = [
      'taskbar_dock',
      'taskbar_media',
      'taskbar_system',
      'taskbar_steam',
      'taskbar_discord',
      'taskbar_weather',
      'taskbar_parking_lot',
    ];

    for (final template in expectedTemplates) {
      test('WidgetSettings.templateDefaults contains $template', () {
        expect(WidgetSettings.templateDefaults.containsKey(template), isTrue);
        final defaults = WidgetSettings.templateDefaults[template]!;
        expect(defaults['width'], isNotNull);
        expect(defaults['height'], isNotNull);
        expect(defaults['sizeFactor'], isNotNull);
        expect(defaults['height'], inInclusiveRange(36.0, 60.0));
      });
    }
  });
}
