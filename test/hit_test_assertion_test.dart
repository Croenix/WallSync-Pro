import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Priority 0: AnimatedSwitcher Hit Test & Layout Race Tests', () {
    testWidgets('Rapid pointer events during SlideTransition animation do not assert debugNeedsLayout', (tester) async {
      int activeTab = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Column(
                  children: [
                    ElevatedButton(
                      key: const ValueKey('switch_tab_btn'),
                      onPressed: () => setState(() => activeTab = (activeTab + 1) % 2),
                      child: const Text('Switch Tab'),
                    ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 350),
                        layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
                          return Stack(
                            alignment: Alignment.topLeft,
                            children: <Widget>[
                              ...previousChildren.map((w) => IgnorePointer(key: w.key, ignoring: true, child: w)),
                              ?currentChild,
                            ],
                          );
                        },
                        transitionBuilder: (child, animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(
                              transformHitTests: false,
                              position: Tween<Offset>(
                                begin: const Offset(0.0, 0.04),
                                end: Offset.zero,
                              ).animate(
                                CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeOutCubic,
                                ),
                              ),
                              child: child,
                            ),
                          );
                        },
                        child: activeTab == 0
                            ? Container(
                                key: const ValueKey('tab_0'),
                                color: Colors.blue,
                                child: ListView.builder(
                                  itemCount: 50,
                                  itemBuilder: (ctx, i) => ListTile(
                                    key: ValueKey('tab0_item_$i'),
                                    title: Text('Item $i'),
                                  ),
                                ),
                              )
                            : Container(
                                key: const ValueKey('tab_1'),
                                color: Colors.green,
                                child: ListView.builder(
                                  itemCount: 50,
                                  itemBuilder: (ctx, i) => ListTile(
                                    key: ValueKey('tab1_item_$i'),
                                    title: Text('New Tab Item $i'),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Trigger switch tab
      await tester.tap(find.byKey(const ValueKey('switch_tab_btn')));
      // Pump partially into animation (50ms into 350ms transition)
      await tester.pump(const Duration(milliseconds: 50));

      // Dispatch rapid pointer hover and move events right over the transitioning Stack
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(100, 200));
      await gesture.moveTo(const Offset(150, 250));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.moveTo(const Offset(200, 300));
      await tester.pump(const Duration(milliseconds: 16));

      // Trigger another rapid tab switch mid-animation
      await tester.tap(find.byKey(const ValueKey('switch_tab_btn')));
      await tester.pump(const Duration(milliseconds: 30));

      // Hover during second mid-flight transition
      await gesture.moveTo(const Offset(250, 350));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.removePointer();

      // Settle completely
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}

