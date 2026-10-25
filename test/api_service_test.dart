import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wall_sync/config/api.dart';
import 'package:wall_sync/services/api_service.dart';
import 'package:wall_sync/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    ApiService.instance.stopHeartbeat();
  });

  test('ApiConfig provides well-formed endpoints and default server URL', () {
    expect(ApiConfig.defaultServerUrl, 'http://127.0.0.1:3000');
    expect(ApiConfig.statusEndpoint, contains('/api/status'));
    expect(ApiConfig.heartbeatEndpoint, contains('/api/sync/heartbeat'));
    expect(ApiConfig.statsEndpoint, contains('/api/users/stats'));
    expect(ApiConfig.wallpapersEndpoint, contains('/api/wallpapers'));
    expect(ApiConfig.heartbeatInterval.inSeconds, 15);
  });

  test('RTDB server URL lookup uses bounded retry backoff', () {
    expect(ApiConfig.serverUrlRetryDelayForFailureCount(0), Duration.zero);
    expect(
      ApiConfig.serverUrlRetryDelayForFailureCount(1),
      const Duration(seconds: 30),
    );
    expect(
      ApiConfig.serverUrlRetryDelayForFailureCount(2),
      const Duration(seconds: 60),
    );
    expect(
      ApiConfig.serverUrlRetryDelayForFailureCount(3),
      const Duration(seconds: 120),
    );
    expect(
      ApiConfig.serverUrlRetryDelayForFailureCount(8),
      const Duration(seconds: 120),
    );
  });

  test(
    'ApiConfig normalizes URLs correctly with scheme and strips trailing slashes',
    () {
      expect(
        ApiConfig.normalizeUrl('192.168.1.50:3000'),
        'http://192.168.1.50:3000',
      );
      expect(
        ApiConfig.normalizeUrl('http://192.168.1.50:3000/'),
        'http://192.168.1.50:3000',
      );
      expect(
        ApiConfig.normalizeUrl('https://api.wallsync.app/'),
        'https://api.wallsync.app',
      );
      expect(ApiConfig.normalizeUrl(''), ApiConfig.defaultServerUrl);
    },
  );

  test(
    'ApiConfig setServerUrl updates endpoints and notifies subscribers',
    () async {
      String? notifiedUrl;
      final sub = ApiConfig.onServerUrlChanged.listen((url) {
        notifiedUrl = url;
      });

      await ApiConfig.setServerUrl('192.168.1.88:4000');
      expect(ApiConfig.serverUrl, 'http://192.168.1.88:4000');
      expect(ApiConfig.statusEndpoint, 'http://192.168.1.88:4000/api/status');
      expect(notifiedUrl, 'http://192.168.1.88:4000');

      await sub.cancel();
      // Reset to default
      await ApiConfig.setServerUrl(ApiConfig.defaultServerUrl);
    },
  );

  test('ApiService generates and persists a valid unique clientId', () async {
    final clientId1 = await ApiService.instance.getClientId();
    expect(clientId1, isNotEmpty);
    expect(clientId1, startsWith('user_'));

    // Second call should return the exact same cached/persisted ID
    final clientId2 = await ApiService.instance.getClientId();
    expect(clientId2, clientId1);
  });

  test('ApiService generates and persists a valid unique deviceId', () async {
    final deviceId1 = await ApiService.instance.getDeviceId();
    expect(deviceId1, isNotEmpty);
    expect(deviceId1, startsWith('dev_'));

    // Second call should return the exact same device ID
    final deviceId2 = await ApiService.instance.getDeviceId();
    expect(deviceId2, deviceId1);
  });

  test(
    'ApiService can start and stop heartbeat cleanly without throwing',
    () async {
      final settings = WidgetSettings();
      ApiService.instance.startHeartbeat(settings: settings);

      // Update settings triggers a ping without throwing
      expect(
        () => ApiService.instance.updateSettings(settings),
        returnsNormally,
      );

      ApiService.instance.stopHeartbeat();
    },
  );

  test('heartbeat retry policy retries only transient HTTP responses', () {
    expect(ApiService.maxHeartbeatAttempts, 2);
    expect(ApiService.shouldRetryHeartbeatResponse(408), isTrue);
    expect(ApiService.shouldRetryHeartbeatResponse(429), isTrue);
    expect(ApiService.shouldRetryHeartbeatResponse(503), isTrue);
    expect(ApiService.shouldRetryHeartbeatResponse(404), isFalse);
  });

  test('heartbeat attempt retries use a bounded exponential backoff', () {
    expect(
      ApiService.heartbeatAttemptBackoff(1),
      const Duration(milliseconds: 500),
    );
    expect(ApiService.heartbeatAttemptBackoff(2), const Duration(seconds: 1));
    expect(ApiService.heartbeatAttemptBackoff(3), const Duration(seconds: 2));
    expect(ApiService.heartbeatAttemptBackoff(10), const Duration(seconds: 2));
  });

  test('heartbeat retry jitter stays bounded around exponential backoff', () {
    final random = Random(1);
    final first = ApiService.heartbeatRetryDelay(1, random: random);
    final second = ApiService.heartbeatRetryDelay(2, random: Random(1));

    expect(first.inMilliseconds, inInclusiveRange(500, 600));
    expect(second.inMilliseconds, inInclusiveRange(1000, 1200));
  });

  test('heartbeat exponential backoff calculates bounded intervals', () {
    expect(
      ApiService.heartbeatIntervalForFailureCount(0),
      const Duration(seconds: 15),
    );
    expect(
      ApiService.heartbeatIntervalForFailureCount(-1),
      const Duration(seconds: 15),
    );
    expect(
      ApiService.heartbeatIntervalForFailureCount(1),
      const Duration(seconds: 30),
    );
    expect(
      ApiService.heartbeatIntervalForFailureCount(2),
      const Duration(seconds: 60),
    );
    expect(
      ApiService.heartbeatIntervalForFailureCount(3),
      const Duration(seconds: 120),
    );
    expect(
      ApiService.heartbeatIntervalForFailureCount(10),
      const Duration(seconds: 120),
    );
  });

  test(
    'heartbeat timeout retries and recovers without overlapping requests',
    () async {
      ApiService.instance.setHeartbeatAttemptOverrideForTesting(null);
      addTearDown(
        () => ApiService.instance.setHeartbeatAttemptOverrideForTesting(null),
      );
      addTearDown(() => ApiConfig.setServerUrl(ApiConfig.defaultServerUrl));
      await ApiConfig.setServerUrl('http://127.0.0.1:65431');
      var attemptCount = 0;
      ApiService.instance.setHeartbeatAttemptOverrideForTesting(() async {
        attemptCount++;
        if (attemptCount == 1) {
          throw TimeoutException('temporary heartbeat timeout');
        }
        return true;
      });

      final first = ApiService.instance.sendHeartbeat();
      final concurrent = ApiService.instance.sendHeartbeat();
      expect(await first, isTrue);
      expect(await concurrent, isTrue);
      expect(attemptCount, 2);
      expect(ApiService.instance.isServerReachable, isTrue);
    },
  );
}
