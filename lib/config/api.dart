import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Configuration file for WallSync Node.js backend server and direct API connection.
/// Dynamically fetches and synchronizes the active server URL/IP from Firebase
/// Realtime Database to effortlessly support dynamic IP and remote server setups.
class ApiConfig {
  /// Default local Node.js server URL used as initial fallback.
  static const String defaultServerUrl = 'http://127.0.0.1:3000';

  /// Default Firebase Realtime Database endpoint for dynamic config synchronization.
  static const String defaultRtdbUrl =
      'https://wallsync-e043c-default-rtdb.firebaseio.com';

  /// Currently active server URL. Dynamically resolved from Realtime Database or cache.
  static String _serverUrl = defaultServerUrl;
  static String get serverUrl => _serverUrl;
  static set serverUrl(String value) {
    _serverUrl = normalizeUrl(value);
  }

  /// SharedPreferences key for caching the resolved dynamic server URL.
  static const String prefsServerUrlKey = 'wallsync_resolved_server_url';
  static const String prefsLastSyncKey = 'wallsync_server_url_last_sync';

  /// Priority Realtime Database endpoints to probe for the dynamic server URL or IP.
  static const List<String> rtdbCandidatePaths = [
    'update_pro/serverUrl.json',
    'update_pro.json',
    'serverUrl.json',
    'server.json',
    'server_config.json',
    'config/serverUrl.json',
    'config.json',
    'update/serverUrl.json',
    'update.json',
  ];

  /// Dynamic endpoint paths derived from active serverUrl.
  static String get statusEndpoint => '$_serverUrl/api/status';
  static String get heartbeatEndpoint => '$_serverUrl/api/sync/heartbeat';
  static String get statsEndpoint => '$_serverUrl/api/users/stats';
  static String get devicesEndpoint => '$_serverUrl/api/devices';
  static String get devicesStatsEndpoint => '$_serverUrl/api/devices/stats';
  static String get clearDevicesEndpoint => '$_serverUrl/api/devices/clear';
  static String get notificationsEndpoint => '$_serverUrl/api/notifications';
  static String get sendNotificationEndpoint =>
      '$_serverUrl/api/notifications/send';
  static String get latestNotificationEndpoint =>
      '$_serverUrl/api/notifications/latest';
  static String get wallpapersEndpoint => '$_serverUrl/api/wallpapers';
  static String get popupEndpoint => '$_serverUrl/api/popup_pro';
  static String get popupLegacyEndpoint => '$_serverUrl/api/popup';

  /// Heartbeat frequency for reporting live user presence.
  static const Duration heartbeatInterval = Duration(seconds: 15);

  /// Interval to refresh server URL from Realtime Database in background.
  static const Duration rtdbRefreshInterval = Duration(minutes: 5);
  static DateTime? _lastFetchTime;
  static bool _isFetching = false;
  static int _serverUrlFetchFailures = 0;

  static Duration serverUrlRetryDelayForFailureCount(int failures) {
    if (failures <= 0) return Duration.zero;
    final boundedStep = failures > 3 ? 3 : failures;
    return Duration(seconds: 30 * (1 << (boundedStep - 1)));
  }

  /// Stream controller for notifying subscribers when serverUrl dynamically changes.
  static final StreamController<String> _urlChangeController =
      StreamController<String>.broadcast();
  static Stream<String> get onServerUrlChanged => _urlChangeController.stream;

  /// Initializes ApiConfig: loads cached URL from SharedPreferences, then reads active server URL from RTDB.
  /// Note: The application only reads from RTDB; it NEVER writes to RTDB.
  static Future<void> init({String? rtdbBaseUrl}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(prefsServerUrlKey);
      if (cached != null && cached.trim().isNotEmpty) {
        _serverUrl = normalizeUrl(cached);
        debugPrint('[ApiConfig] Loaded cached server URL: $_serverUrl');
      }
    } catch (e) {
      debugPrint('[ApiConfig] Error reading cached server URL: $e');
    }

    // Await reading active server URL from Firebase Realtime Database with a short timeout
    // so the desktop application connects directly to the server URL configured in RTDB.
    try {
      await fetchServerUrlFromDatabase(
        rtdbBaseUrl: rtdbBaseUrl,
        force: true,
      ).timeout(const Duration(milliseconds: 2500));
      debugPrint('[ApiConfig] Resolved live server URL from RTDB: $_serverUrl');
    } catch (e) {
      debugPrint('[ApiConfig] RTDB fetch timeout/fallback: $_serverUrl ($e)');
    }
  }

  /// Manually overrides and persists the active server URL.
  static Future<void> setServerUrl(String url) async {
    final normalized = normalizeUrl(url);
    if (normalized != _serverUrl) {
      _serverUrl = normalized;
      _urlChangeController.add(_serverUrl);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(prefsServerUrlKey, normalized);
      } catch (_) {}
    }
  }

  /// Queries Firebase Realtime Database to discover the dynamic server URL or IP.
  static Future<String> fetchServerUrlFromDatabase({
    String? rtdbBaseUrl,
    bool force = false,
  }) async {
    if (_isFetching) return _serverUrl;

    final now = DateTime.now();
    final retryDelay = _serverUrlFetchFailures == 0
        ? const Duration(minutes: 2)
        : serverUrlRetryDelayForFailureCount(_serverUrlFetchFailures);
    if (!force &&
        _lastFetchTime != null &&
        now.difference(_lastFetchTime!) < retryDelay) {
      return _serverUrl;
    }

    _isFetching = true;
    final baseUrl = (rtdbBaseUrl ?? defaultRtdbUrl).replaceAll(
      RegExp(r'/+$'),
      '',
    );

    HttpClient? client;
    Object? lastNetworkError;
    var networkFailureCount = 0;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 2);

      for (final path in rtdbCandidatePaths) {
        final uri = Uri.parse('$baseUrl/$path');
        try {
          final request = await client
              .getUrl(uri)
              .timeout(const Duration(seconds: 5));
          request.headers.set(HttpHeaders.acceptHeader, 'application/json');
          request.headers.set(
            HttpHeaders.userAgentHeader,
            'WallSync-Client/1.0',
          );

          final response = await request.close().timeout(
            const Duration(seconds: 5),
          );
          if (response.statusCode == 200) {
            final body = await response.transform(utf8.decoder).join();
            if (body.trim().isEmpty || body.trim() == 'null') {
              continue;
            }

            final dynamic data = jsonDecode(body);
            final extracted = _extractUrlFromRtdbData(data);

            if (extracted != null && extracted.isNotEmpty) {
              final normalized = normalizeUrl(extracted);
              if (normalized != _serverUrl) {
                final oldUrl = _serverUrl;
                _serverUrl = normalized;
                debugPrint(
                  '[ApiConfig] Dynamic Server URL updated from RTDB ($path): $oldUrl -> $_serverUrl',
                );
                _urlChangeController.add(_serverUrl);

                try {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(prefsServerUrlKey, normalized);
                  await prefs.setInt(
                    prefsLastSyncKey,
                    now.millisecondsSinceEpoch,
                  );
                } catch (_) {}
              }
              _lastFetchTime = now;
              _serverUrlFetchFailures = 0;
              return _serverUrl;
            }
          } else {
            await response.drain();
          }
        } catch (error) {
          if (error is SocketException || error is TimeoutException) {
            lastNetworkError = error;
            networkFailureCount++;
            if (error is SocketException) {
              break;
            }
            if (networkFailureCount >= 2) {
              break;
            }
          }
          // Continue probing next candidate path
        }
      }
    } catch (e) {
      debugPrint('[ApiConfig] Error fetching server URL from RTDB: $e');
    } finally {
      client?.close(force: true);
      _isFetching = false;
    }

    _lastFetchTime = now;
    if (networkFailureCount > 0) {
      _serverUrlFetchFailures++;
      final nextDelay = serverUrlRetryDelayForFailureCount(
        _serverUrlFetchFailures,
      );
      debugPrint(
        '[ApiConfig] Server URL lookup encountered $networkFailureCount '
        'network failure(s); last error: $lastNetworkError. '
        'Retaining $_serverUrl and retrying after ${nextDelay.inSeconds}s.',
      );
    } else {
      _serverUrlFetchFailures = 0;
    }
    return _serverUrl;
  }

  /// Extracts server URL/IP from various RTDB payload structures:
  /// - Plain String URL or IP (e.g. `"http://192.168.1.100:3000"` or `"192.168.1.100"`)
  /// - Map: `{"serverUrl": "..."}`, `{"url": "..."}`, `{"ip": "192.168.1.100", "port": 3000}`
  static String? _extractUrlFromRtdbData(dynamic data) {
    if (data == null) return null;

    if (data is String) {
      final trimmed = data.trim();
      return trimmed.isNotEmpty ? trimmed : null;
    }

    if (data is Map) {
      // Check priority keys
      final candidateKeys = [
        'serverUrl',
        'server_url',
        'url',
        'apiUrl',
        'api_url',
        'serverIp',
        'server_ip',
        'ip',
        'host',
      ];
      for (final key in candidateKeys) {
        if (data.containsKey(key) && data[key] != null) {
          final val = data[key].toString().trim();
          if (val.isNotEmpty) {
            if (data.containsKey('port') &&
                data['port'] != null &&
                !val.contains(':') &&
                !val.startsWith('http')) {
              return '$val:${data['port']}';
            }
            return val;
          }
        }
      }
    }

    return null;
  }

  /// Normalizes IP/host/URL strings with appropriate scheme and formatting.
  static String normalizeUrl(String input) {
    var raw = input.trim();
    if (raw.isEmpty) return defaultServerUrl;

    // Strip wrapping quotes if any
    if ((raw.startsWith('"') && raw.endsWith('"')) ||
        (raw.startsWith("'") && raw.endsWith("'"))) {
      raw = raw.substring(1, raw.length - 1).trim();
    }

    // Clean duplicate/nested schemes like http://https:// or https://http:// or http://http://
    final schemeRegex = RegExp(r'^(?:https?:\/\/)+', caseSensitive: false);
    final match = schemeRegex.firstMatch(raw);
    if (match != null) {
      final schemePart = match.group(0)!;
      final useHttps = schemePart.toLowerCase().contains('https');
      raw =
          (useHttps ? 'https://' : 'http://') +
          raw.substring(schemePart.length);
    } else {
      raw = 'http://$raw';
    }

    // Strip trailing slashes
    while (raw.endsWith('/')) {
      raw = raw.substring(0, raw.length - 1);
    }

    // Render cloud services: traffic only arrives on port 443/80; strip internal container ports (like :10000)
    if (raw.contains('.onrender.com')) {
      raw = raw.replaceAll(RegExp(r':\d+'), '');
      if (!raw.startsWith('https://')) {
        raw = raw.replaceFirst(RegExp(r'^http:\/\/'), 'https://');
      }
    }

    return raw;
  }
}
