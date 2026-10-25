import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:wall_sync/services/system_connectivity_service.dart';
import 'package:wall_sync/services/settings_service.dart';
import 'package:wall_sync/widgets/custom_widget_renderer.dart';

void main() {
  test('parses available Wi-Fi and Bluetooth adapter state', () {
    final snapshot = SystemConnectivitySnapshot.fromJsonText(
      '{"wifi":true,"bluetooth":false}',
    );

    expect(snapshot.wifiEnabled, isTrue);
    expect(snapshot.bluetoothEnabled, isFalse);
  });

  test('preserves unavailable adapter state instead of inventing a value', () {
    final snapshot = SystemConnectivitySnapshot.fromJsonText(
      '{"wifi":null,"bluetooth":null}',
    );

    expect(snapshot.wifiEnabled, isNull);
    expect(snapshot.bluetoothEnabled, isNull);
  });

  test('rejects malformed adapter status output', () {
    expect(
      () => SystemConnectivitySnapshot.fromJsonText('not-json'),
      throwsFormatException,
    );
  });

  test('coalesces concurrent refreshes into one read', () async {
    final response = Completer<SystemConnectivitySnapshot>();
    var readCount = 0;
    final service = SystemConnectivityService.forTesting(
      readStatus: () {
        readCount++;
        return response.future;
      },
    );
    addTearDown(service.dispose);

    final first = service.refresh();
    final second = service.refresh();
    expect(readCount, 1);

    response.complete(
      const SystemConnectivitySnapshot(
        wifiEnabled: true,
        bluetoothEnabled: false,
      ),
    );
    await Future.wait([first, second]);
    expect(service.current.wifiEnabled, isTrue);
    expect(service.current.bluetoothEnabled, isFalse);
  });

  test(
    'retries a failed read once and publishes the recovered state',
    () async {
      var readCount = 0;
      final service = SystemConnectivityService.forTesting(
        retryDelay: Duration.zero,
        readStatus: () async {
          readCount++;
          if (readCount == 1) throw const SocketException('temporary failure');
          return const SystemConnectivitySnapshot(wifiEnabled: true);
        },
      );
      addTearDown(service.dispose);

      await service.refresh();

      expect(readCount, 2);
      expect(service.current.wifiEnabled, isTrue);
    },
  );

  test(
    'recovers after a timed-out refresh without overlapping polls',
    () async {
      var readCount = 0;
      final service = SystemConnectivityService.forTesting(
        retryDelay: Duration.zero,
        readStatus: () async {
          readCount++;
          if (readCount == 1) {
            throw TimeoutException('temporary timeout');
          }
          return const SystemConnectivitySnapshot(wifiEnabled: false);
        },
      );
      addTearDown(service.dispose);

      final first = service.refresh();
      final overlapping = service.refresh();
      await Future.wait([first, overlapping]);

      expect(readCount, 2);
      expect(service.current.wifiEnabled, isFalse);
    },
  );

  test('preserves the last known state when all reads fail', () async {
    var readCount = 0;
    final service = SystemConnectivityService.forTesting(
      retryDelay: Duration.zero,
      readStatus: () async {
        readCount++;
        if (readCount == 1) {
          return const SystemConnectivitySnapshot(wifiEnabled: true);
        }
        throw const SocketException('adapter query timed out');
      },
    );
    addTearDown(service.dispose);

    await service.refresh();
    await service.refresh();

    expect(readCount, 3);
    expect(service.current.wifiEnabled, isTrue);
    expect(service.current.bluetoothEnabled, isNull);
  });

  testWidgets('custom Wi-Fi element reflects disabled color and icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            height: 80,
            child: CustomWidgetRenderer(
              elements: [
                CustomWidgetElement(
                  id: 'wifi',
                  type: 'wifi_icon',
                  color: 0xFFFFFFFF,
                  activeColor: 0xFF00FF00,
                  disabledColor: 0xFFFF0000,
                ),
              ],
              dateTime: DateTime(2026),
              wifiEnabled: false,
            ),
          ),
        ),
      ),
    );

    final wifiIcon = tester.widget<Icon>(find.byIcon(Icons.wifi_off_rounded));
    expect(wifiIcon.color, const Color(0xFFFF0000));
  });

  testWidgets('custom Bluetooth element uses neutral color when unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            height: 80,
            child: CustomWidgetRenderer(
              elements: [
                CustomWidgetElement(
                  id: 'bluetooth',
                  type: 'bluetooth_icon',
                  color: 0xFF123456,
                  activeColor: 0xFF00FF00,
                  disabledColor: 0xFFFF0000,
                ),
              ],
              dateTime: DateTime(2026),
              bluetoothEnabled: null,
            ),
          ),
        ),
      ),
    );

    final icon = tester.widget<Icon>(find.byIcon(Icons.bluetooth_rounded));
    expect(icon.color, const Color(0xFF123456));
  });

  testWidgets('custom Wi-Fi element invokes the requested adapter state', (
    tester,
  ) async {
    bool? requestedState;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            height: 80,
            child: CustomWidgetRenderer(
              elements: [CustomWidgetElement(id: 'wifi', type: 'wifi_icon')],
              dateTime: DateTime(2026),
              wifiEnabled: true,
              onWifiToggle: (enabled) async {
                requestedState = enabled;
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.wifi_rounded));
    expect(requestedState, isFalse);
  });
}
