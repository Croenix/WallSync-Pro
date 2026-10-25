import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/firebase_service.dart';

void main() {
  late HttpServer server;
  late HttpClient client;
  late FirebaseService service;
  final requests =
      <({String method, String path, Map<String, dynamic> body})>[];

  Future<void> respond(
    HttpRequest request, {
    int statusCode = HttpStatus.ok,
    String body = 'null',
  }) async {
    final requestBody = await utf8.decoder.bind(request).join();
    requests.add((
      method: request.method,
      path: request.uri.path,
      body: jsonDecode(requestBody) as Map<String, dynamic>,
    ));
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(body);
    await request.response.close();
  }

  setUp(() async {
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = HttpClient();
    service = FirebaseService.forTesting(
      endpoint: 'http://${server.address.address}:${server.port}',
      httpClient: client,
    );
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
  });

  Future<String> submit() => service.submitWallpaperReport(
    wallpaperId: 'wallpaper-123',
    wallpaperTitle: 'Aurora',
    wallpaperType: 'static',
    wallpaperResolution: '3840 × 2160 · 4K',
    userEmail: 'person@example.com',
    description: 'The source image is broken.',
  );

  test(
    'writes report with PUT to generated Firebase child and accepts null',
    () async {
      server.listen((request) => respond(request));

      final reportId = await submit();
      expect(reportId, matches(RegExp(r'^[a-f0-9]{32}$')));
      expect(requests, hasLength(1));
      expect(requests.single.method, 'PUT');
      expect(requests.single.path, '/wallpaperReports/$reportId.json');
      expect(requests.single.body, containsPair('reportId', reportId));
      expect(
        requests.single.body,
        containsPair('wallpaperId', 'wallpaper-123'),
      );
      expect(requests.single.body, containsPair('status', 'pending'));
      expect(
        requests.single.body,
        containsPair('userEmail', 'person@example.com'),
      );
      expect(
        requests.single.body,
        containsPair('description', 'The source image is broken.'),
      );
      expect(requests.single.body['createdAt'], {'.sv': 'timestamp'});
      expect(requests.single.body['updatedAt'], {'.sv': 'timestamp'});
    },
  );

  test(
    'surfaces Firebase permission errors without retrying another path',
    () async {
      server.listen(
        (request) => respond(
          request,
          statusCode: HttpStatus.unauthorized,
          body: '{"error":"Permission denied."}',
        ),
      );

      await expectLater(
        submit(),
        throwsA(
          isA<HttpException>()
              .having((error) => error.message, 'message', contains('401'))
              .having(
                (error) => error.message,
                'message',
                contains('Permission denied'),
              ),
        ),
      );
      expect(requests, hasLength(1));
      expect(requests.single.path, startsWith('/wallpaperReports/'));
    },
  );

  test(
    'surfaces server rejection of PUT with Firebase response detail',
    () async {
      server.listen(
        (request) => respond(
          request,
          statusCode: HttpStatus.methodNotAllowed,
          body: '{"error":"PUT is not allowed"}',
        ),
      );

      await expectLater(
        submit(),
        throwsA(
          isA<HttpException>()
              .having((error) => error.message, 'message', contains('405'))
              .having(
                (error) => error.message,
                'message',
                contains('PUT is not allowed'),
              ),
        ),
      );
      expect(requests.single.method, 'PUT');
    },
  );

  test('surfaces network errors without repeating the write', () async {
    await server.close(force: true);

    await expectLater(submit(), throwsA(isA<SocketException>()));
    expect(requests, isEmpty);
  });

  test(
    'coalesces duplicate concurrent submissions into one database write',
    () async {
      final releaseResponse = Completer<void>();
      final requestArrived = Completer<void>();
      server.listen((request) async {
        final requestBody = await utf8.decoder.bind(request).join();
        requests.add((
          method: request.method,
          path: request.uri.path,
          body: jsonDecode(requestBody) as Map<String, dynamic>,
        ));
        if (!requestArrived.isCompleted) requestArrived.complete();
        await releaseResponse.future;
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write('null');
        await request.response.close();
      });

      final first = submit();
      final duplicate = submit();
      expect(identical(first, duplicate), isTrue);
      await requestArrived.future.timeout(const Duration(seconds: 5));
      expect(requests, hasLength(1));

      releaseResponse.complete();
      expect(await first, await duplicate);
      expect(requests, hasLength(1));
    },
  );
}
