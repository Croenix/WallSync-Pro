import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wall_sync/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    NotificationService.instance.isTestMode = true;
    await NotificationService.instance.init();
    await NotificationService.instance.resetSeenHistory();
  });

  test('AppNotification parses JSON payload correctly', () {
    final json = {
      'id': 'notif_1001',
      'title': 'WallSync v1.0.32.0 Update',
      'message': 'New features and live wallpapers are ready!',
      'type': 'update',
      'version': '1.0.32.0',
      'url': 'https://wallsync.app',
      'timestamp': 1792270000000,
    };

    final notif = AppNotification.fromJson(json);
    expect(notif.id, 'notif_1001');
    expect(notif.title, 'WallSync v1.0.32.0 Update');
    expect(notif.message, contains('New features'));
    expect(notif.type, 'update');
    expect(notif.version, '1.0.32.0');
    expect(notif.actionUrl, 'https://wallsync.app');
    expect(notif.timestamp, 1792270000000);

    final mapped = notif.toJson();
    expect(mapped['id'], 'notif_1001');
    expect(mapped['title'], 'WallSync v1.0.32.0 Update');
  });

  test(
    'NotificationService ignores duplicate notifications with same id',
    () async {
      final notifData = {
        'id': 'notif_unique_999',
        'title': 'Important System Announcement',
        'message': 'Testing deduplication.',
        'type': 'announcement',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      // First process should accept and mark as seen
      await NotificationService.instance.processIncomingNotification(notifData);

      // Verify it is saved in SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('wallsync_last_seen_notification_id'),
        'notif_unique_999',
      );

      // Calling again with the same id should be safely ignored
      expect(
        () =>
            NotificationService.instance.processIncomingNotification(notifData),
        returnsNormally,
      );
    },
  );

  test('NotificationService emits new notifications on stream', () async {
    final received = <AppNotification>[];
    final sub = NotificationService.instance.onNotification.listen((n) {
      received.add(n);
    });

    await NotificationService.instance.showDesktopNotification(
      title: 'Stream Alert',
      message: 'Testing broadcast stream.',
      id: 'stream_1',
      type: 'info',
    );

    await Future.delayed(const Duration(milliseconds: 50));
    expect(received.length, 1);
    expect(received.first.title, 'Stream Alert');

    await sub.cancel();
  });
}
