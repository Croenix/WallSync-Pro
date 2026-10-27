import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'settings_service.dart';

class HourlyForecast {
  final String time;
  final double temperature;
  final String status;
  final int weatherCode;

  HourlyForecast({
    required this.time,
    required this.temperature,
    required this.status,
    required this.weatherCode,
  });

  Map<String, dynamic> toJson() => {
    'time': time,
    'temp': temperature.toStringAsFixed(1),
    'status': status,
    'code': weatherCode,
  };

  factory HourlyForecast.fromJson(Map<String, dynamic> json) => HourlyForecast(
    time: json['time'] as String? ?? '',
    temperature: double.tryParse(json['temp']?.toString() ?? '') ?? 0.0,
    status: json['status'] as String? ?? 'Cloudy',
    weatherCode: json['code'] as int? ?? 0,
  );
}

class WeatherInfo {
  final double temperature;
  final String status;
  final IconData icon;
  final String locationName;
  final int weatherCode;
  final double apparentTemp;
  final int humidity;
  final List<HourlyForecast> hourly;
  final String forecastJson;

  WeatherInfo({
    required this.temperature,
    required this.status,
    required this.icon,
    required this.locationName,
    this.weatherCode = 0,
    this.apparentTemp = 0.0,
    this.humidity = 0,
    this.hourly = const [],
    this.forecastJson = '',
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
      headers: {
        'User-Agent': 'WallSyncPro/1.0 (Windows NT 10.0; Win64; x64)',
      },
    ),
  );

  final Map<String, Map<String, dynamic>> _geocodingCache = {};
  final Map<String, Future<Map<String, dynamic>?>> _inFlightGeocoding = {};
  final Map<String, Future<WeatherInfo?>> _inFlightWeather = {};

  /// Map WMO weather codes to user-friendly descriptions and icons.
  static final Map<int, ({String status, IconData icon})> _weatherCodeMap = {
    0: (status: 'Clear Sky', icon: Icons.wb_sunny_rounded),
    1: (status: 'Mainly Clear', icon: Icons.wb_sunny_outlined),
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

  /// Returns appropriate weather icon matching any status text string.
  static IconData getIconForStatus(String status) {
    final s = status.toLowerCase();
    if (s.contains('thunder') || s.contains('storm') || s.contains('hail')) {
      return Icons.thunderstorm_rounded;
    }
    if (s.contains('snow') || s.contains('ice') || s.contains('frost') || s.contains('blizzard')) {
      return Icons.ac_unit_rounded;
    }
    if (s.contains('drizzle') || s.contains('grain')) {
      return Icons.grain_rounded;
    }
    if (s.contains('rain') || s.contains('shower')) {
      return Icons.water_drop_rounded;
    }
    if (s.contains('fog') || s.contains('mist') || s.contains('haze')) {
      return Icons.filter_drama_rounded;
    }
    if (s.contains('overcast')) {
      return Icons.wb_cloudy_rounded;
    }
    if (s.contains('partly') || s.contains('cloud')) {
      return Icons.cloud_queue_rounded;
    }
    if (s.contains('clear') || s.contains('sunny')) {
      return Icons.wb_sunny_rounded;
    }
    return Icons.cloud_queue_rounded;
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

  /// Resolves a location name or pincode to latitude, longitude, and user-friendly name.
  /// Uses OpenStreetMap Nominatim for accurate worldwide city & pincode resolution,
  /// with Open-Meteo as a reliable fallback.
  Future<Map<String, dynamic>?> searchLocation(String query) {
    final cleanKey = query.trim().toLowerCase();
    if (cleanKey.isEmpty) {
      logInfo(
        'WeatherService',
        'searchLocation received empty query. Bypassing search.',
      );
      return Future.value(null);
    }

    final cached = _geocodingCache[cleanKey];
    if (cached != null) {
      logInfo('WeatherService', 'Returning cached geocoding result for "$cleanKey": $cached');
      return Future.value(cached);
    }

    final inFlight = _inFlightGeocoding[cleanKey];
    if (inFlight != null) {
      logInfo('WeatherService', 'Joining in-flight geocoding request for "$cleanKey"');
      return inFlight;
    }

    final future = _searchLocationInternal(query.trim());
    _inFlightGeocoding[cleanKey] = future;
    return future.then((res) {
      if (res != null) {
        _geocodingCache[cleanKey] = res;
      }
      return res;
    }).whenComplete(() => _inFlightGeocoding.remove(cleanKey));
  }

  Future<Map<String, dynamic>?> _searchLocationInternal(String cleanQuery) async {

    // 1. Try Nominatim (Best for postal codes/pincodes and exact local towns)
    try {
      logInfo('WeatherService', 'Trying Nominatim search for: "$cleanQuery"...');
      final nomRes = await _dio.get(
        'https://nominatim.openstreetmap.org/search',
        queryParameters: {
          'q': cleanQuery,
          'format': 'json',
          'limit': 1,
          'addressdetails': 1,
        },
        options: Options(receiveTimeout: const Duration(seconds: 4)),
      );

      if (nomRes.statusCode == 200 && nomRes.data is List && (nomRes.data as List).isNotEmpty) {
        final item = (nomRes.data as List).first;
        final lat = double.tryParse(item['lat']?.toString() ?? '');
        final lon = double.tryParse(item['lon']?.toString() ?? '');
        if (lat != null && lon != null) {
          String resolvedName = cleanQuery;
          final address = item['address'];
          if (address is Map) {
            final city = address['city'] ??
                address['town'] ??
                address['village'] ??
                address['municipality'] ??
                address['suburb'] ??
                address['county'] ??
                item['name'];
            final state = address['state'];
            final country = address['country'];
            final parts = <String>[];
            if (city != null) parts.add(city.toString());
            if (state != null && state != city) parts.add(state.toString());
            if (country != null) parts.add(country.toString());
            if (parts.isNotEmpty) {
              resolvedName = parts.join(', ');
            }
          } else if (item['display_name'] != null) {
            final split = item['display_name'].toString().split(',');
            resolvedName = split.take(3).map((s) => s.trim()).join(', ');
          }

          final result = {
            'lat': lat,
            'lon': lon,
            'name': resolvedName,
          };
          logInfo('WeatherService', 'Nominatim resolved "$cleanQuery" to: $result');
          return result;
        }
      }
    } catch (e) {
      logWarning('WeatherService', 'Nominatim lookup error: $e. Falling back to Open-Meteo...');
    }

    // 2. Fallback to Open-Meteo Geocoding
    try {
      logInfo(
        'WeatherService',
        'Searching location coordinates via Open-Meteo for: "$cleanQuery"...',
      );
      final response = await _dio.get(
        'https://geocoding-api.open-meteo.com/v1/search',
        queryParameters: {
          'name': cleanQuery,
          'count': 5,
          'language': 'en',
          'format': 'json',
        },
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
            if (admin1 != null && admin1 != name) admin1,
            ?country,
          ].join(', ');

          final result = {
            'lat': (first['latitude'] as num).toDouble(),
            'lon': (first['longitude'] as num).toDouble(),
            'name': resolvedName,
          };
          logInfo(
            'WeatherService',
            'Resolved query "$cleanQuery" via Open-Meteo to: $result',
          );
          return result;
        }
      }
    } catch (e, st) {
      logError(
        'WeatherService',
        'Open-Meteo geocoding search failed: $e',
        e,
        st,
      );
    }
    return null;
  }

  /// Fetches live weather and accurate hourly forecast for coordinates.
  Future<WeatherInfo?> fetchWeather(
    double lat,
    double lon,
    String locationName,
  ) {
    final key = '${lat.toStringAsFixed(2)}_${lon.toStringAsFixed(2)}';
    final inFlight = _inFlightWeather[key];
    if (inFlight != null) {
      logInfo('WeatherService', 'Joining in-flight weather request for ($key)');
      return inFlight;
    }

    final future = _fetchWeatherInternal(lat, lon, locationName);
    _inFlightWeather[key] = future;
    return future.whenComplete(() => _inFlightWeather.remove(key));
  }

  Future<WeatherInfo?> _fetchWeatherInternal(
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
          'current': 'temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,weather_code,wind_speed_10m',
          'hourly': 'temperature_2m,weather_code',
          'forecast_hours': 12,
          'timezone': 'auto',
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

      if (response.statusCode == 200 && response.data != null) {
        final current = response.data['current'];
        if (current != null) {
          final double temp = (current['temperature_2m'] as num).toDouble();
          final int code = current['weather_code'] as int;
          final mapItem = _weatherCodeMap[code];
          final weatherStatus = mapItem?.status ?? 'Cloudy';
          final apparentTemp = (current['apparent_temperature'] as num?)?.toDouble() ?? temp;
          final humidity = (current['relative_humidity_2m'] as num?)?.toInt() ?? 0;

          // Parse upcoming hourly forecasts strictly matching user local time
          final List<HourlyForecast> hourlyList = [];
          final hourlyData = response.data['hourly'];
          if (hourlyData != null && hourlyData is Map) {
            final List times = hourlyData['time'] as List? ?? [];
            final List temps = hourlyData['temperature_2m'] as List? ?? [];
            final List codes = hourlyData['weather_code'] as List? ?? [];

            final currentTimeStr = current['time']?.toString() ?? '';
            for (int i = 0; i < times.length && hourlyList.length < 3; i++) {
              final tStr = times[i].toString();
              if (currentTimeStr.isNotEmpty && tStr.compareTo(currentTimeStr) <= 0) {
                continue;
              }
              final hTemp = (temps[i] as num).toDouble();
              final hCode = codes[i] as int;
              String formattedTime = tStr;
              if (tStr.contains('T')) {
                formattedTime = tStr.split('T').last;
              }
              hourlyList.add(HourlyForecast(
                time: formattedTime,
                temperature: hTemp,
                status: _weatherCodeMap[hCode]?.status ?? 'Cloudy',
                weatherCode: hCode,
              ));
            }
          }

          final forecastJson = jsonEncode(hourlyList.map((h) => h.toJson()).toList());

          final info = WeatherInfo(
            temperature: temp,
            status: weatherStatus,
            icon: mapItem?.icon ?? Icons.wb_cloudy_rounded,
            locationName: locationName,
            weatherCode: code,
            apparentTemp: apparentTemp,
            humidity: humidity,
            hourly: hourlyList,
            forecastJson: forecastJson,
          );
          logInfo(
            'WeatherService',
            'Parsed accurate weather: loc="${info.locationName}", temp=${info.temperature}°C, status="$weatherStatus" (code=$code), hourlyCount=${hourlyList.length}',
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
