import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/api.dart';
import 'notification_service.dart';
import 'settings_service.dart';

/// Direct API and heartbeat synchronization service between WallSync application
/// and the Node.js backend server for real-time live presence tracking.
class ApiService {
  static const int maxHeartbeatAttempts = 2;
  static Duration heartbeatAttemptBackoff(int completedAttempt) {
    final shift = completedAttempt <= 1
        ? 0
        : completedAttempt == 2
        ? 1
        : 2;
    return Duration(milliseconds: 500 * (1 << shift));
  }

  static Duration heartbeatRetryDelay(int completedAttempt, {Random? random}) {
    final backoff = heartbeatAttemptBackoff(completedAttempt);
    final jitterLimit = backoff.inMilliseconds ~/ 5;
    final jitter = (random ?? Random()).nextInt(jitterLimit + 1);
    return backoff + Duration(milliseconds: jitter);
  }

  static bool shouldRetryHeartbeatResponse(int statusCode) =>
      statusCode == 408 || statusCode == 429 || statusCode >= 500;

  ApiService._();
  static final ApiService instance = ApiService._();

  Timer? _heartbeatTimer;
  StreamSubscription<String>? _urlSubscription;
  WidgetSettings? _currentSettings;
  String? _cachedClientId;
  String? _cachedDeviceId;
  bool _isServerReachable = false;
  final Map<String, Future<bool>> _heartbeatInFlight = {};
  int _heartbeatGeneration = 0;
  int _consecutiveFailures = 0;
  bool _heartbeatActive = false;
  Future<bool> Function()? _heartbeatAttemptOverride;

  bool get isServerReachable => _isServerReachable;
  int get consecutiveFailures => _consecutiveFailures;

  @visibleForTesting
  void setHeartbeatAttemptOverrideForTesting(
    Future<bool> Function()? override,
  ) {
    _heartbeatAttemptOverride = override;
  }

  static Duration heartbeatIntervalForFailureCount(int failures) {
    if (failures <= 0) return ApiConfig.heartbeatInterval;
    final multiplier = 1 << failures.clamp(1, 3);
    return Duration(
      seconds: ApiConfig.heartbeatInterval.inSeconds * multiplier,
    );
  }

  /// Retrieves or generates a persistent unique hardware/OS device identifier.
  /// On Windows, uses the permanent MachineGuid from the registry so a single
  /// physical machine is always recognized as one individual device.
  Future<String> getDeviceId() async {
    if (_cachedDeviceId != null && _cachedDeviceId!.isNotEmpty) {
      return _cachedDeviceId!;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString('wallsync_device_id');
      if (id != null && id.isNotEmpty) {
        _cachedDeviceId = id;
        return id;
      }

      final localAppData =
          Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'] ??
          Directory.systemTemp.path;
      final idFile = File('$localAppData\\WallSync\\device_id.txt');
      if (await idFile.exists()) {
        id = (await idFile.readAsString()).trim();
        if (id.isNotEmpty) {
          _cachedDeviceId = id;
          await prefs.setString('wallsync_device_id', id);
          return id;
        }
      }

      if (Platform.isWindows) {
        try {
          final res = await Process.run('reg', [
            'query',
            r'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography',
            '/v',
            'MachineGuid',
          ]);
          if (res.exitCode == 0) {
            final match = RegExp(
              r'MachineGuid\s+REG_SZ\s+([a-zA-Z0-9\-]+)',
            ).firstMatch(res.stdout.toString());
            if (match != null && match.group(1) != null) {
              final guid = match.group(1)!.trim();
              final host = Platform.localHostname
                  .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')
                  .toLowerCase();
              final deviceId = 'dev_${host}_$guid';
              _cachedDeviceId = deviceId;
              await prefs.setString('wallsync_device_id', deviceId);
              try {
                await idFile.parent.create(recursive: true);
                await idFile.writeAsString(deviceId, flush: true);
              } catch (_) {}
              return deviceId;
            }
          }
        } catch (_) {}
      }

      final randomHex = Random()
          .nextInt(0xFFFFFF)
          .toRadixString(16)
          .padLeft(6, '0');
      final host = Platform.localHostname
          .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')
          .toLowerCase();
      final newId = 'dev_${host}_$randomHex';
      _cachedDeviceId = newId;

      await prefs.setString('wallsync_device_id', newId);
      try {
        await idFile.parent.create(recursive: true);
        await idFile.writeAsString(newId, flush: true);
      } catch (_) {}

      return newId;
    } catch (_) {
      final fallback = 'dev_${Platform.localHostname.toLowerCase()}';
      _cachedDeviceId = fallback;
      return fallback;
    }
  }

  /// Retrieves or generates a persistent unique client identifier.
  Future<String> getClientId() async {
    if (_cachedClientId != null && _cachedClientId!.isNotEmpty) {
      return _cachedClientId!;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString('wallsync_client_id');
      if (id != null && id.isNotEmpty) {
        _cachedClientId = id;
        return id;
      }

      final localAppData =
          Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'] ??
          Directory.systemTemp.path;
      final idFile = File('$localAppData\\WallSync\\client_id.txt');
      if (await idFile.exists()) {
        id = (await idFile.readAsString()).trim();
        if (id.isNotEmpty) {
          _cachedClientId = id;
          await prefs.setString('wallsync_client_id', id);
          return id;
        }
      }

      final randomHex = Random()
          .nextInt(0xFFFFFF)
          .toRadixString(16)
          .padLeft(6, '0');
      final host = Platform.localHostname
          .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')
          .toLowerCase();
      final newId = 'user_${host}_$randomHex';
      _cachedClientId = newId;

      await prefs.setString('wallsync_client_id', newId);
      try {
        await idFile.parent.create(recursive: true);
        await idFile.writeAsString(newId, flush: true);
      } catch (_) {}

      return newId;
    } catch (_) {
      final fallback = 'user_${Platform.localHostname.toLowerCase()}';
      _cachedClientId = fallback;
      return fallback;
    }
  }

  /// Starts periodic background heartbeat synchronization to the Node.js server.
  void startHeartbeat({WidgetSettings? settings}) {
    final generation = ++_heartbeatGeneration;
    if (settings != null) {
      _currentSettings = settings;
    }

    _heartbeatActive = true;
    _consecutiveFailures = 0;

    // Listen to dynamic server URL changes from RTDB
    _urlSubscription?.cancel();
    _urlSubscription = ApiConfig.onServerUrlChanged.listen((newUrl) {
      logInfo(
        'ApiService',
        'Server URL dynamically updated: $newUrl. Retrying heartbeat...',
      );
      _consecutiveFailures = 0;
      unawaited(sendHeartbeat());
    });

    // Trigger dynamic RTDB server URL fetch, then immediate heartbeat
    unawaited(
      ApiConfig.fetchServerUrlFromDatabase().then((_) {
        if (generation == _heartbeatGeneration) unawaited(sendHeartbeat());
      }),
    );

    _scheduleNextHeartbeat();

    logInfo(
      'ApiService',
      'Heartbeat sync started (interval: ${ApiConfig.heartbeatInterval.inSeconds}s)',
    );
  }

  void _scheduleNextHeartbeat() {
    _heartbeatTimer?.cancel();
    if (!_heartbeatActive) return;
    final interval = heartbeatIntervalForFailureCount(_consecutiveFailures);
    _heartbeatTimer = Timer(interval, () {
      if (_heartbeatActive) {
        unawaited(sendHeartbeat());
      }
    });
  }

  /// Updates current active settings and triggers a heartbeat immediately.
  void updateSettings(WidgetSettings settings) {
    _currentSettings = settings;
    unawaited(sendHeartbeat());
  }

  /// Stops periodic background heartbeat synchronization.
  void stopHeartbeat() {
    _heartbeatGeneration++;
    _heartbeatActive = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _urlSubscription?.cancel();
    _urlSubscription = null;
    _consecutiveFailures = 0;
    logInfo('ApiService', 'Heartbeat sync stopped');
  }

  /// Sends a single heartbeat telemetry payload to the Node.js backend.
  Future<bool> sendHeartbeat() {
    final endpoint = ApiConfig.heartbeatEndpoint;
    final current = _heartbeatInFlight[endpoint];
    if (current != null) return current;
    final request = _sendHeartbeatWithRetry(endpoint);
    _heartbeatInFlight[endpoint] = request;
    return request.whenComplete(() {
      if (identical(_heartbeatInFlight[endpoint], request)) {
        _heartbeatInFlight.remove(endpoint);
      }
      if (_heartbeatActive) {
        _scheduleNextHeartbeat();
      }
    });
  }

  Future<bool> _sendHeartbeatWithRetry(String endpoint) async {
    final uri = Uri.parse(endpoint);
    final deviceId = await getDeviceId();
    final clientId = await getClientId();
    final wallpaperPath = _currentSettings?.activeWallpaperPath ?? '';
    final wallpaperType =
        _currentSettings?.activeWallpaperType ??
        _currentSettings?.backgroundType ??
        'color';
    final payload = {
      'deviceId': deviceId,
      'clientId': clientId,
      'hostname': Platform.localHostname,
      'platform': Platform.operatingSystem,
      'appVersion': '1.0.32.0',
      'activeWallpaper': wallpaperPath,
      'activeWallpaperType': wallpaperType,
      'timestamp': DateTime.now().toIso8601String(),
    };

    for (var attempt = 1; attempt <= maxHeartbeatAttempts; attempt++) {
      HttpClient? client;
      try {
        final attemptOverride = _heartbeatAttemptOverride;
        if (attemptOverride != null) {
          final success = await attemptOverride();
          if (!success) {
            throw const SocketException(
              'Injected heartbeat attempt reported unavailable.',
            );
          }
          _consecutiveFailures = 0;
          _isServerReachable = true;
          return true;
        }
        client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
        final sw = Stopwatch()..start();
        final request = await client
            .postUrl(uri)
            .timeout(const Duration(seconds: 4));
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(payload));

        final response = await request.close().timeout(
          const Duration(seconds: 4),
        );
        final success = response.statusCode >= 200 && response.statusCode < 300;
        if (success) {
          logPerf(
            'ApiService',
            'Heartbeat sync acknowledged by server in ${sw.elapsedMilliseconds} ms (status ${response.statusCode})',
          );
          try {
            final bodyStr = await response
                .transform(utf8.decoder)
                .join()
                .timeout(const Duration(seconds: 4));
            final data = jsonDecode(bodyStr);
            if (data is Map<String, dynamic> &&
                data['latestNotification'] != null) {
              unawaited(
                NotificationService.instance.processIncomingNotification(
                  Map<String, dynamic>.from(data['latestNotification'] as Map),
                ),
              );
            }
          } catch (_) {}
        } else {
          logWarning(
            'ApiService',
            'Heartbeat HTTP response ${response.statusCode} from server in ${sw.elapsedMilliseconds} ms',
          );
          await response.drain();
          if (attempt < maxHeartbeatAttempts &&
              shouldRetryHeartbeatResponse(response.statusCode)) {
            _isServerReachable = false;
            final delay = heartbeatRetryDelay(attempt);
            logInfo(
              'ApiService',
              'Retrying heartbeat after HTTP ${response.statusCode} in '
                  '${delay.inMilliseconds}ms (attempt ${attempt + 1}/'
                  '$maxHeartbeatAttempts).',
            );
            await Future.delayed(delay);
            continue;
          }
        }

        if (success) {
          _consecutiveFailures = 0;
        } else {
          _consecutiveFailures++;
        }
        _isServerReachable = success;
        return success;
      } catch (error) {
        final transient = error is TimeoutException || error is SocketException;
        final dnsFailure =
            error is SocketException &&
            (error.message.toLowerCase().contains('lookup') ||
                error.message.toLowerCase().contains('host'));
        final socketDetail = error is SocketException
            ? ' host=${uri.host}, osError=${error.osError ?? "unavailable"}'
            : '';
        final diagnostic =
            'Heartbeat attempt $attempt/$maxHeartbeatAttempts failed'
            ' (endpoint=${uri.host}, elapsed timeout bounds: 4s connect/response)'
            '$socketDetail: $error';
        if (dnsFailure) {
          logWarning('ApiService', 'DNS lookup failed; $diagnostic');
        } else {
          logDebug('ApiService', diagnostic);
        }
        if (attempt < maxHeartbeatAttempts && transient) {
          final delay = heartbeatRetryDelay(attempt);
          logInfo(
            'ApiService',
            'Retrying transient heartbeat failure in '
                '${delay.inMilliseconds}ms (attempt ${attempt + 1}/'
                '$maxHeartbeatAttempts).',
          );
          await Future.delayed(delay);
          continue;
        }
        _consecutiveFailures++;
        _isServerReachable = false;
        logWarning(
          'ApiService',
          'Heartbeat is offline after $attempt attempt(s); next periodic '
              'retry is scheduled with '
              '${heartbeatIntervalForFailureCount(_consecutiveFailures).inSeconds}s backoff.',
        );
        unawaited(ApiConfig.fetchServerUrlFromDatabase());
        return false;
      } finally {
        client?.close(force: true);
      }
    }

    _consecutiveFailures++;
    _isServerReachable = false;
    return false;
  }

  /// Queries user count statistics from the Node backend directly.
  Future<Map<String, dynamic>?> fetchStats() async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      final uri = Uri.parse(ApiConfig.statsEndpoint);
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 4));
      final response = await request.close().timeout(
        const Duration(seconds: 4),
      );

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final json = jsonDecode(body) as Map<String, dynamic>;
        _isServerReachable = true;
        return json;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }
}
