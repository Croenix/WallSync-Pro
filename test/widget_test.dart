// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wall_sync/main.dart';
import 'package:wall_sync/services/settings_service.dart';

void main() {
  testWidgets('Clock overlay smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(DashboardApp(settings: WidgetSettings()));

    // Verify that the main app widget exists.
    expect(find.byType(DashboardApp), findsOneWidget);
  });

  testWidgets('widget catalog builds offscreen previews lazily', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      DashboardApp(
        settings: WidgetSettings(),
        startMinimized: true,
        initialTab: 'widgets',
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    final catalog = find.byKey(const ValueKey('desktop_widget_library_grid'));
    final lastPreview = find.byKey(
      const ValueKey('desktop_widget_card_starter_holo_telemetry'),
    );
    expect(catalog, findsOneWidget);
    expect(lastPreview, findsNothing);

    for (final key in [
      'starter_fluent_calendar',
      'starter_weather_report',
      'starter_system_pulse',
      'starter_media_player',
      'starter_holo_telemetry',
    ]) {
      final card = find.byKey(ValueKey('desktop_widget_card_$key'));
      await tester.scrollUntilVisible(
        card,
        300,
        scrollable: find.descendant(
          of: catalog,
          matching: find.byType(Scrollable),
        ),
      );
      expect(card, findsOneWidget, reason: '$key is listed in Desktop Widgets');
      if (key.startsWith('starter_')) {
        expect(
          find.descendant(of: card, matching: find.text('Turn ON')),
          findsOneWidget,
          reason: '$key must have the same install action as built-in widgets',
        );
        expect(
          find.descendant(
            of: card,
            matching: find.byTooltip('Customize Layout & 3D'),
          ),
          findsOneWidget,
          reason: '$key keeps a separate customization action',
        );
      }
    }
    expect(lastPreview, findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 901));
  });

  testWidgets('custom widget starter opens its preloaded Studio design', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      DashboardApp(
        settings: WidgetSettings(),
        startMinimized: true,
        initialTab: 'widgets',
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Custom Studio').first);
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('STARTER WIDGETS'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('widget_starter_fluent_calendar')),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Fluent Calendar'), findsWidgets);
    expect(find.text('November 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 901));
  });

  testWidgets('Launch New Custom opens a genuinely empty canvas', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      DashboardApp(
        settings: WidgetSettings(
          customElements: CustomWidgetElement.defaultCustomLayout(),
        ),
        startMinimized: true,
        initialTab: 'widgets',
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Custom Studio').first);
    await tester.pump(const Duration(milliseconds: 220));

    await tester.tap(find.text('Launch New Custom'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining('0 Elements on Canvas'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 901));
  });

  for (final size in <Size>[
    const Size(640, 480),
    const Size(700, 500),
    const Size(850, 600),
  ]) {
    testWidgets(
      'Dashboard fits supported ${size.width.toInt()}x${size.height.toInt()} window',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          DashboardApp(settings: WidgetSettings(), startMinimized: true),
        );

        expect(find.byType(DashboardApp), findsOneWidget);
        expect(tester.takeException(), isNull);
        // Drain startup callbacks so their delayed timers and logging flush are
        // complete before the test binding checks for pending timers.
        await tester.pump(const Duration(milliseconds: 701));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 101));
      },
    );
  }

  for (final configuration in <({Size size, double devicePixelRatio})>[
    (size: const Size(360, 640), devicePixelRatio: 1),
    (size: const Size(640, 480), devicePixelRatio: 1.25),
    (size: const Size(960, 600), devicePixelRatio: 1.5),
    (size: const Size(1440, 900), devicePixelRatio: 2),
  ]) {
    testWidgets(
      'Dashboard navigation stays within ${configuration.size.width.toInt()} logical pixels at ${configuration.devicePixelRatio}x DPI',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = configuration.devicePixelRatio;
        tester.view.physicalSize =
            configuration.size * configuration.devicePixelRatio;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          DashboardApp(
            settings: WidgetSettings(),
            startMinimized: true,
            initialTab: 'widgets',
          ),
        );
        expect(tester.takeException(), isNull, reason: 'initial dashboard');

        final labels = [
          'Wallpapers',
          'Widgets',
          'Studio',
          'Templates',
          'Optimization',
          'Diagnostics',
          'Bug Report',
          'About',
        ];
        for (final label in labels) {
          final finder = configuration.size.width < 1180
              ? find.byTooltip(label)
              : find.text(label);
          expect(finder, findsWidgets, reason: '$label navigation control');
          await tester.tap(finder.first);
          await tester.pump(const Duration(milliseconds: 400));
          final exception = tester.takeException();
          expect(
            exception,
            isNull,
            reason: '$label at ${configuration.size.width} logical pixels',
          );
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 901));
      },
    );
  }

  testWidgets(
    'Template footer card inside 220px width renders without RenderFlex overflow',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 220,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Text(
                          'Custom Widget Studio',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.pink.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'ACTIVE',
                          style: TextStyle(
                            color: Colors.pink,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // Verify the widget rendered cleanly and text is found
      expect(find.text('Custom Widget Studio'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Taskbar preview containers render inside FittedBox without hasSize or layout failure',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 220,
                height: 150,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Container(
                    width: 190,
                    height: 36,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.access_time_rounded, size: 10),
                        const SizedBox(width: 4),
                        const Text('12:45'),
                        Expanded(
                          child: Row(
                            children: const [
                              Expanded(
                                child: Text(
                                  'Nightcall',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Nightcall'), findsOneWidget);
    },
  );
}
