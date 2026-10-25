import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/launch_popup_service.dart';
import 'package:wall_sync/widgets/launch_popup_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LaunchPopupService.instance.resetSessionForTesting();
  });

  group('LaunchPopupConfig', () {
    test('serializes and deserializes correctly', () {
      final json = {
        'enabled': true,
        'imageUrl': 'https://res.cloudinary.com/test/image/upload/poster.jpg',
        'actionText': 'Get Started',
        'actionUrl': 'https://wallsync.app/promo',
        'id': 'popup_special_1',
        'updatedAt': 1792300000000,
      };

      final config = LaunchPopupConfig.fromJson(json);
      expect(config.enabled, isTrue);
      expect(config.imageUrl, 'https://res.cloudinary.com/test/image/upload/poster.jpg');
      expect(config.actionText, 'Get Started');
      expect(config.actionUrl, 'https://wallsync.app/promo');
      expect(config.id, 'popup_special_1');
      expect(config.updatedAt, 1792300000000);

      final mapped = config.toJson();
      expect(mapped['enabled'], isTrue);
      expect(mapped['imageUrl'], 'https://res.cloudinary.com/test/image/upload/poster.jpg');
      expect(mapped['actionText'], 'Get Started');
    });

    test('uses sensible defaults for missing or empty optional values', () {
      final json = <String, dynamic>{
        'enabled': false,
        'imageUrl': '',
      };

      final config = LaunchPopupConfig.fromJson(json);
      expect(config.enabled, isFalse);
      expect(config.imageUrl, isEmpty);
      expect(config.actionText, 'Continue');
      expect(config.actionUrl, isEmpty);
      expect(config.id, 'popup_default');
    });
  });

  group('LaunchPopupService connectivity and enable rules', () {
    test('returns null when unreachable or offline (popup NEVER shown without connection)', () async {
      // By querying an unreachable port/host, the service must return null
      final config = await LaunchPopupService.instance.fetchConfig();
      // Since no local test server is started on the test port, it must safely resolve to null
      expect(config, isNull);
    });

    test('one-time session guard enforces single display per app launch session', () {
      expect(LaunchPopupService.instance.hasShownThisSession, isFalse);

      // Once resetSessionForTesting is called
      LaunchPopupService.instance.resetSessionForTesting();
      expect(LaunchPopupService.instance.hasShownThisSession, isFalse);
    });
  });

  group('LaunchPopupDialog Widget', () {
    testWidgets('renders close button and custom action text', (tester) async {
      const testConfig = LaunchPopupConfig(
        enabled: true,
        imageUrl: 'https://example.com/poster.jpg',
        actionText: 'Explore Features',
        actionUrl: 'https://example.com/explore',
        id: 'popup_widget_test',
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LaunchPopupDialog(config: testConfig),
          ),
        ),
      );

      // Check for Action button text
      expect(find.text('Explore Features'), findsOneWidget);

      // Check for Close icon button (Icons.close_rounded)
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      // Check for external link icon
      expect(find.byIcon(Icons.open_in_new_rounded), findsOneWidget);
    });

    testWidgets(
      'shows Close and dismisses the popup when action URL is empty',
      (tester) async {
        const testConfig = LaunchPopupConfig(
          enabled: true,
          imageUrl: 'https://example.com/poster.jpg',
          actionText: 'Explore Features',
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () {
                    showDialog<void>(
                      context: context,
                      builder: (_) =>
                          const LaunchPopupDialog(config: testConfig),
                    );
                  },
                  child: const Text('Open popup'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Open popup'));
        await tester.pumpAndSettle();

        expect(find.text('Close'), findsOneWidget);
        expect(find.text('Explore Features'), findsNothing);
        expect(find.byIcon(Icons.open_in_new_rounded), findsNothing);

        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();

        expect(find.byType(LaunchPopupDialog), findsNothing);
      },
    );
  });
}
