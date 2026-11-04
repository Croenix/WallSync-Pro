import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/weather_service.dart';

void main() {
  test(
    'automatic location lookup coalesces requests and caches successes',
    () async {
      var requestCount = 0;
      final requestStarted = Completer<void>();
      final releaseResponse = Completer<void>();
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            requestCount++;
            if (!requestStarted.isCompleted) requestStarted.complete();
            await releaseResponse.future;
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'status': 'success',
                  'lat': 47.6,
                  'lon': -122.3,
                  'city': 'Seattle',
                  'zip': '98101',
                  'countryCode': 'US',
                },
              ),
            );
          },
        ),
      );
      final service = WeatherService.forTesting(dio);

      final firstRequest = service.autoDetectLocation();
      await requestStarted.future;
      final secondRequest = service.autoDetectLocation();
      releaseResponse.complete();

      final results = await Future.wait([firstRequest, secondRequest]);
      expect(results[0], results[1]);
      expect(requestCount, 1);
      expect(await service.autoDetectLocation(), results[0]);
      expect(requestCount, 1);
    },
  );

  test(
    'automatic location cache expires and can be refreshed explicitly',
    () async {
      var requestCount = 0;
      var now = DateTime(2026, 1, 1);
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestCount++;
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'status': 'success',
                  'lat': 47.6,
                  'lon': -122.3,
                  'city': 'Seattle',
                  'zip': '98101',
                  'countryCode': 'US',
                },
              ),
            );
          },
        ),
      );
      final service = WeatherService.forTesting(dio, clock: () => now);

      await service.autoDetectLocation();
      await service.autoDetectLocation();
      expect(requestCount, 1);

      now = now.add(WeatherService.autoLocationCacheDuration);
      await service.autoDetectLocation();
      expect(requestCount, 2);

      await service.autoDetectLocation(forceRefresh: true);
      expect(requestCount, 3);
    },
  );

  test(
    'failed location lookup uses a short cooldown instead of retrying',
    () async {
      var requestCount = 0;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requestCount++;
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 503,
                data: const {},
              ),
            );
          },
        ),
      );
      final service = WeatherService.forTesting(dio);

      expect(await service.autoDetectLocation(), isNull);
      final requestsAfterFailure = requestCount;
      expect(requestsAfterFailure, 4);

      expect(await service.autoDetectLocation(), isNull);
      expect(requestCount, requestsAfterFailure);
    },
  );
}
