import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/custom_asset_service.dart';
import 'package:wall_sync/services/custom_font_service.dart';
import 'package:wall_sync/widgets/font_download_dialog.dart';

final Uint8List _transparentPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

class _TestHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _MockHttpClient();
  }
}

class _MockHttpClient implements HttpClient {
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;

  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) {}
  @override
  void addProxyCredentials(String host, int port, String realm, HttpClientCredentials credentials) {}
  @override
  set authenticate(Future<bool> Function(Uri url, String scheme, String? realm)? f) {}
  @override
  set authenticateProxy(Future<bool> Function(String host, int port, String scheme, String? realm)? f) {}
  @override
  set badCertificateCallback(bool Function(X509Certificate cert, String host, int port)? callback) {}
  @override
  set findProxy(String Function(Uri url)? f) {}

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _MockHttpRequest(url);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async => _MockHttpRequest(url);
  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpRequest implements HttpClientRequest {
  final Uri url;
  _MockHttpRequest(this.url);

  @override
  final HttpHeaders headers = _MockHttpHeaders();

  @override
  Future<HttpClientResponse> close() async {
    final isApi = url.host.contains('api.github.com');
    final bytes = isApi ? Uint8List.fromList('[]'.codeUnits) : _transparentPng;
    return _MockHttpResponse(bytes);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpResponse extends Stream<List<int>> implements HttpClientResponse {
  final Uint8List bytes;
  _MockHttpResponse(this.bytes);

  @override
  int get statusCode => 200;
  @override
  int get contentLength => bytes.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.value(bytes).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    HttpOverrides.global = _TestHttpOverrides();
    await CustomFontService.instance.init();
  });

  setUp(() async {
    await CustomAssetService.instance.init(resetLocalState: true);
  });

  group('Cloud Asset & Font Studio Dialog Tests', () {
    testWidgets('renders all 3 tabs: Fonts, Animated GIFs, Icons PNG/SVG',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FontDownloadDialog(
                initialTab: CloudStudioTab.fonts,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Fonts'), findsOneWidget);
      expect(find.text('Animated GIFs'), findsOneWidget);
      expect(find.text('Icons PNG/SVG'), findsOneWidget);
      expect(find.text('Cloud Studio'), findsOneWidget);
      expect(find.text('Download All Fonts'), findsOneWidget);
    });

    testWidgets('switching to Animated GIFs tab displays GIF items and usability buttons',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FontDownloadDialog(
                initialTab: CloudStudioTab.gifs,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Download All GIFs'), findsOneWidget);
      expect(find.text('Clouds & Skies'), findsWidgets);
      expect(find.text('Rain & Weather'), findsWidgets);
      expect(find.text('⬇ Download to Use'), findsWidgets);
    });

    testWidgets('switching to Icons tab displays PNG/SVG items and usability buttons',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FontDownloadDialog(
                initialTab: CloudStudioTab.icons,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Download All Icons'), findsOneWidget);
      expect(find.text('Sun & Daylight'), findsWidgets);
      expect(find.text('Storm & Lightning'), findsWidgets);
      expect(find.text('Wind & Air'), findsWidgets);
      expect(find.text('⬇ Download to Use'), findsWidgets);
    });

    testWidgets('switching tabs via pill buttons updates view smoothly',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FontDownloadDialog(
                initialTab: CloudStudioTab.fonts,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Initially on Fonts tab
      expect(find.text('Download All Fonts'), findsOneWidget);

      // Tap on Animated GIFs tab pill
      await tester.ensureVisible(find.byKey(const ValueKey('tab_gifs')));
      await tester.tap(find.byKey(const ValueKey('tab_gifs')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Now on GIFs tab
      expect(find.text('Download All GIFs'), findsOneWidget);

      // Tap on Icons PNG/SVG tab pill
      await tester.ensureVisible(find.byKey(const ValueKey('tab_icons')));
      await tester.tap(find.byKey(const ValueKey('tab_icons')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Now on Icons tab
      expect(find.text('Download All Icons'), findsOneWidget);
    });
  });
}
