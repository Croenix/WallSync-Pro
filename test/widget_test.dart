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

  for (final size in <Size>[const Size(700, 500), const Size(850, 600)]) {
    testWidgets(
      'Dashboard fits supported ${size.width.toInt()}x${size.height.toInt()} window',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          DashboardApp(
            settings: WidgetSettings(),
            startMinimized: true,
          ),
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
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        const Icon(Icons.access_time_rounded, size: 10),
                        const SizedBox(width: 4),
                        const Text('12:45'),
                        Expanded(
                          child: Row(
                            children: const [
                              Expanded(child: Text('Nightcall', overflow: TextOverflow.ellipsis)),
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
