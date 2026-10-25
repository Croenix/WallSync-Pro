import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'settings_service.dart';

class WeatherInfo {
  final double temperature;
  final String status;
  final IconData icon;
  final String locationName;

  WeatherInfo({
    required this.temperature,
    required this.status,
    required this.icon,
    required this.locationName,
  });
}

class WeatherService {
  static final WeatherService _instance = WeatherService._internal();
  factory WeatherService() => _instance;

  WeatherService._internal() {
    final adapter = IOHttpClientAdapter();
    adapter.createHttpClient = () {
      final client = HttpClient();
      // Bypass system proxy resolution to avoid PlatformException on Windows when channels are unavailable
      client.findProxy = (uri) => 'DIRECT';

      client.connectionFactory =
          (Uri uri, String? proxyHost, int? proxyPort) async {
            final host = proxyHost ?? uri.host;
            final port = proxyPort ?? uri.port;
            try {
              final addresses = await InternetAddress.lookup(
                host,
                type: InternetAddressType.IPv4,
              );
              if (addresses.isNotEmpty) {
                final rawSocket = await Socket.connect(addresses.first, port);
                if (uri.scheme == 'https') {
                  final secureSocket = await SecureSocket.secure(
                    rawSocket,
                    host: host,
                  );
                  return ConnectionTask.fromSocket(
                    Future.value(secureSocket),
                    () => secureSocket.destroy(),
                  );
                } else {
                  return ConnectionTask.fromSocket(
                    Future.value(rawSocket),
                    () => rawSocket.destroy(),
                  );
                }
              }
            } catch (e) {
              // Fallback to default resolution if manual IPv4 lookup fails/throws
            }

            if (uri.scheme == 'https') {
              final secureSocket = await SecureSocket.connect(host, port);
              return ConnectionTask.fromSocket(
                Future.value(secureSocket),
                () => secureSocket.destroy(),
              );
            } else {
              final rawSocket = await Socket.connect(host, port);
              return ConnectionTask.fromSocket(
                Future.value(rawSocket),
                () => rawSocket.destroy(),
              );
            }
          };

      return client;
    };
    _dio.httpClientAdapter = adapter;
  }

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      validateStatus: (status) => true,
    ),
  );

  /// Map WMO weather codes to user-friendly descriptions and icons.
  static final Map<int, ({String status, IconData icon})> _weatherCodeMap = {
    0: (status: 'Clear Sky', icon: Icons.wb_sunny_rounded),
    1: (status: 'Mainly Clear', icon: Icons.wb_cloudy_outlined),
    2: (status: 'Partly Cloudy', icon: Icons.cloud_queue_rounded),
    3: (status: 'Overcast', icon: Icons.wb_cloudy_rounded),
    45: (status: 'Foggy', icon: Icons.filter_drama_rounded),
    48: (status: 'Depositing Rime Fog', icon: Icons.filter_drama_rounded),
    51: (status: 'Light Drizzle', icon: Icons.grain_rounded),
    53: (status: 'Moderate Drizzle', icon: Icons.grain_rounded),
    55: (status: 'Dense Drizzle', icon: Icons.grain_rounded),
    56: (status: 'Light Freezing Drizzle', icon: Icons.ac_unit_rounded),
    57: (status: 'Dense Freezing Drizzle', icon: Icons.ac_unit_rounded),
    61: (status: 'Slight Rain', icon: Icons.water_drop_rounded),
    63: (status: 'Moderate Rain', icon: Icons.water_drop_rounded),
    65: (status: 'Heavy Rain', icon: Icons.water_drop_rounded),
    66: (status: 'Light Freezing Rain', icon: Icons.ac_unit_rounded),
    67: (status: 'Heavy Freezing Rain', icon: Icons.ac_unit_rounded),
    71: (status: 'Slight Snowfall', icon: Icons.ac_unit_rounded),
    73: (status: 'Moderate Snowfall', icon: Icons.ac_unit_rounded),
    75: (status: 'Heavy Snowfall', icon: Icons.ac_unit_rounded),
    77: (status: 'Snow Grains', icon: Icons.ac_unit_rounded),
    80: (status: 'Slight Rain Showers', icon: Icons.water_drop_rounded),
    81: (status: 'Moderate Rain Showers', icon: Icons.water_drop_rounded),
    82: (status: 'Violent Rain Showers', icon: Icons.thunderstorm_rounded),
    85: (status: 'Slight Snow Showers', icon: Icons.ac_unit_rounded),
    86: (status: 'Heavy Snow Showers', icon: Icons.ac_unit_rounded),
    95: (status: 'Thunderstorm', icon: Icons.thunderstorm_rounded),
    96: (status: 'Thunderstorm with Hail', icon: Icons.thunderstorm_rounded),
    99: (
      status: 'Thunderstorm with Heavy Hail',
      icon: Icons.thunderstorm_rounded,
    ),
  };

  static IconData getIconForCode(int code) {
    return _weatherCodeMap[code]?.icon ?? Icons.wb_cloudy_rounded;
  }

  static String getStatusForCode(int code) {
    return _weatherCodeMap[code]?.status ?? 'Cloudy';
  }

  /// Automatically detects user's location via IP Geolocation APIs.
  Future<Map<String, dynamic>?> autoDetectLocation() async {
    logInfo('WeatherService', 'Starting autoDetectLocation process...');

    // 1. ip-api.com
    try {
      logInfo('WeatherService', 'Attempting geolocation via ip-api.com...');
      final response = await _dio.get('http://ip-api.com/json/');
      logInfo(
        'WeatherService',
        'ip-api.com response code: ${response.statusCode}, payload: ${response.data}',
      );
      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        if (data['status'] == 'success') {
          final result = {
            'lat': (data['lat'] as num).toDouble(),
            'lon': (data['lon'] as num).toDouble(),
            'city': data['city'] as String,
            'zip': data['zip'] as String,
            'countryCode': data['countryCode'] as String,
          };
          logInfo(
            'WeatherService',
            'Successfully geocoded via ip-api.com: $result',
          );
          return result;
        } else {
          logError(
            'WeatherService',
            'ip-api.com returned unsuccessful status: ${data['status']} | msg: ${data['message']}',
          );
        }
      } else {
        logError(
          'WeatherService',
          'ip-api.com failed with status code: ${response.statusCode}',
        );
      }
    } catch (e, st) {
      logError(
        'WeatherService',
        'ip-api.com error: $e. Trying ipwho.is as fallback...',
        e,
        st,
      );
    }

    // 2. ipwho.is
    try {
      logInfo('WeatherService', 'Attempting geolocation via ipwho.is...');
      final response = await _dio.get('https://ipwho.is/');
      logInfo(
        'WeatherService',
        'ipwho.is response code: ${response.statusCode}, payload: ${response.data}',
      );
      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        if (data['success'] == true) {
          final result = {
            'lat': (data['latitude'] as num).toDouble(),
            'lon': (data['longitude'] as num).toDouble(),
            'city': data['city'] as String,
            'zip': data['postal'] as String,
            'countryCode': data['country_code'] as String,
          };
          logInfo(
            'WeatherService',
            'Successfully geocoded via ipwho.is: $result',
          );
          return result;
        } else {
          logError(
            'WeatherService',
            'ipwho.is returned unsuccessful result: success=false | reason: ${data['message']}',
          );
        }
      } else {
        logError(
          'WeatherService',
          'ipwho.is failed with status code: ${response.statusCode}',
        );
      }
    } catch (e, st) {
      logError(
        'WeatherService',
        'ipwho.is error: $e. Trying freeipapi.com as fallback...',
        e,
        st,
      );
    }

    // 3. freeipapi.com
    try {
      logInfo('WeatherService', 'Attempting geolocation via freeipapi.com...');
      final response = await _dio.get('https://freeipapi.com/api/json');
      logInfo(
        'WeatherService',
        'freeipapi.com response code: ${response.statusCode}, payload: ${response.data}',
      );
      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        final result = {
          'lat': (data['latitude'] as num).toDouble(),
          'lon': (data['longitude'] as num).toDouble(),
          'city': data['cityName'] as String,
          'zip': data['zipCode'] as String,
          'countryCode': data['countryCode'] as String,
        };
        logInfo(
          'WeatherService',
          'Successfully geocoded via freeipapi.com: $result',
        );
        return result;
      } else {
        logError(
          'WeatherService',
          'freeipapi.com failed with status code: ${response.statusCode}',
        );
      }
    } catch (e, st) {
      logError(
        'WeatherService',
        'freeipapi.com error: $e. Trying ipapi.co as fallback...',
        e,
        st,
      );
    }

    // 4. ipapi.co
    try {
      logInfo('WeatherService', 'Attempting geolocation via ipapi.co...');
      final response = await _dio.get('https://ipapi.co/json/');
      logInfo(
        'WeatherService',
        'ipapi.co response code: ${response.statusCode}, payload: ${response.data}',
      );
      if (response.statusCode == 200 && response.data != null) {
        final data = response.data;
        if (data['error'] == true) {
          logError(
            'WeatherService',
            'ipapi.co returned error: ${data['reason']}',
          );
        } else {
          final result = {
            'lat': (data['latitude'] as num).toDouble(),
            'lon': (data['longitude'] as num).toDouble(),
            'city': data['city'] as String,
            'zip': data['postal'] as String,
            'countryCode': data['country_code'] as String,
          };
          logInfo(
            'WeatherService',
            'Successfully geocoded via ipapi.co: $result',
          );
          return result;
        }
      } else {
        logError(
          'WeatherService',
          'ipapi.co failed with status code: ${response.statusCode}',
        );
      }
    } catch (e, st) {
      logError('WeatherService', 'ipapi.co fallback also failed: $e', e, st);
    }

    logError(
      'WeatherService',
      'All IP geolocation services failed. Location auto-detection returning null.',
    );
    return null;
  }

  /// Resolves a location name or pincode to latitude, longitude, and name.
  Future<Map<String, dynamic>?> searchLocation(String query) async {
    if (query.trim().isEmpty) {
      logInfo(
        'WeatherService',
        'searchLocation received empty query. Bypassing search.',
      );
      return null;
    }
    try {
      logInfo(
        'WeatherService',
        'Searching location coordinates for query: "$query"...',
      );
      final response = await _dio.get(
        'https://geocoding-api.open-meteo.com/v1/search',
        queryParameters: {
          'name': query,
          'count': 1,
          'language': 'en',
          'format': 'json',
        },
      );

      logInfo(
        'WeatherService',
        'Geocoding search response code: ${response.statusCode}, payload: ${response.data}',
      );

      if (response.statusCode == 200 && response.data != null) {
        final results = response.data['results'];
        if (results != null && results is List && results.isNotEmpty) {
          final first = results.first;
          final String name = first['name'] ?? '';
          final String? admin1 = first['admin1'] as String?;
          final String? country = first['country'] as String?;

          final resolvedName = [
            name,
            if (admin1 != name) ?admin1,
            ?country,
          ].join(', ');

          final result = {
            'lat': (first['latitude'] as num).toDouble(),
            'lon': (first['longitude'] as num).toDouble(),
            'name': resolvedName,
          };
          logInfo(
            'WeatherService',
            'Resolved query "$query" successfully to: $result',
          );
          return result;
        } else {
          logInfo(
            'WeatherService',
            'No geocoding results found for query: "$query"',
          );
        }
      } else {
        logError(
          'WeatherService',
          'Geocoding search failed with status code: ${response.statusCode}',
        );
      }
    } catch (e, st) {
      logError(
        'WeatherService',
        'Geocoding search failed with exception: $e',
        e,
        st,
      );
    }
    return null;
  }

  /// Fetches live weather for coordinates.
  Future<WeatherInfo?> fetchWeather(
    double lat,
    double lon,
    String locationName,
  ) async {
    try {
      logInfo(
        'WeatherService',
        'Fetching weather metrics for location: "$locationName" at ($lat, $lon)...',
      );
      final sw = Stopwatch()..start();
      final response = await _dio.get(
        'https://api.open-meteo.com/v1/forecast',
        queryParameters: {
          'latitude': lat,
          'longitude': lon,
          'current': 'temperature_2m,weather_code',
        },
      );
      final durationMs = sw.elapsedMilliseconds;
      if (durationMs > 2500) {
        logWarning(
          'WeatherService',
          '[OVERWAIT WARNING] Weather API request took ${durationMs}ms for "$locationName"',
        );
      } else {
        logPerf(
          'WeatherService',
          'Weather API completed in ${durationMs}ms for "$locationName"',
        );
      }

      logDebug(
        'WeatherService',
        'Weather fetch response code: ${response.statusCode}, payload: ${response.data}',
      );

      if (response.statusCode == 200 && response.data != null) {
        final current = response.data['current'];
        if (current != null) {
          final double temp = (current['temperature_2m'] as num).toDouble();
          final int code = current['weather_code'] as int;
          final mapItem = _weatherCodeMap[code];
          final weatherStatus = mapItem?.status ?? 'Cloudy';

          final info = WeatherInfo(
            temperature: temp,
            status: weatherStatus,
            icon: mapItem?.icon ?? Icons.wb_cloudy_rounded,
            locationName: locationName,
          );
          logInfo(
            'WeatherService',
            'Parsed weather metrics: locationName="${info.locationName}", temp=${info.temperature} °C, status="$weatherStatus" (code=$code)',
          );
          return info;
        } else {
          logError(
            'WeatherService',
            'No "current" section found in Open-Meteo response payload.',
          );
        }
      } else {
        logError(
          'WeatherService',
          'Weather fetch failed with status code: ${response.statusCode}',
        );
      }
    } catch (e, st) {
      logError(
        'WeatherService',
        'Weather fetch failed with exception: $e',
        e,
        st,
      );
    }
    return null;
  }
}
