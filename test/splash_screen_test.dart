import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/widgets/splash_screen.dart';

void main() {
  testWidgets('shows the animated splash and supports skipping', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1389, 781);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: AnimatedSplashScreen(onComplete: () => completed = true),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1500));

    expect(find.text('PREPARING YOUR DESKTOP'), findsOneWidget);
    expect(find.text('CYBERPUNK SKYLINE'), findsOneWidget);
    expect(find.byKey(const ValueKey('splash-atmosphere')), findsOneWidget);
    expect(find.text('SKIP  ›'), findsOneWidget);

    await tester.tap(find.text('SKIP  ›'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(completed, isTrue);
  });
}
