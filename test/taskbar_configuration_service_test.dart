import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/taskbar_configuration_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('wallsync/test_taskbar_appbar');
  final calls = <MethodCall>[];

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'applies configuration and verifies native ownership and revision',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            final args = Map<String, dynamic>.from(call.arguments as Map);
            return {
              'success': true,
              'hwnd': 1234,
              'ownerPid': pid,
              'appliedRevision': args['revision'],
              'left': 0,
              'top': 100,
              'right': 640,
              'bottom': 148,
            };
          });

      final service = TaskbarConfigurationService(channel: channel);
      final result = await service.applyNativeDock(
        edge: 'top',
        thickness: 48,
        length: 640,
        autoHide: false,
        revision: 1,
      );

      expect(calls, hasLength(1));
      expect(calls.single.method, 'configureTaskbarAppBar');
      expect(result.hwnd, 1234);
      expect(result.ownerPid, pid);
      expect(result.left, 0);
      expect(result.top, 100);
      expect(result.right, 640);
      expect(result.bottom, 148);
    },
  );

  test('rejects native acknowledgment for a different process', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          return {
            'success': true,
            'hwnd': 1234,
            'ownerPid': pid + 1,
            'appliedRevision': args['revision'],
            'left': 0,
            'top': 100,
            'right': 640,
            'bottom': 148,
          };
        });

    final service = TaskbarConfigurationService(channel: channel);
    await expectLater(
      service.applyNativeDock(
        edge: 'bottom',
        thickness: 48,
        length: 640,
        autoHide: false,
        revision: 2,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('accepts a full-monitor AppBar length', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          final args = Map<String, dynamic>.from(call.arguments as Map);
          return {
            'success': true,
            'hwnd': 1234,
            'ownerPid': pid,
            'appliedRevision': args['revision'],
            'left': 0,
            'top': 1032,
            'right': 1920,
            'bottom': 1080,
          };
        });

    final service = TaskbarConfigurationService(channel: channel);
    final result = await service.applyNativeDock(
      edge: 'bottom',
      thickness: 48,
      length: 0,
      autoHide: false,
      revision: 4,
    );

    expect((calls.single.arguments as Map)['length'], 0);
    expect(result.right - result.left, 1920);
  });

  test('rejects unsupported edges before making a native call', () async {
    final service = TaskbarConfigurationService(channel: channel);
    await expectLater(
      service.applyNativeDock(
        edge: 'diagonal',
        thickness: 48,
        length: 640,
        autoHide: false,
        revision: 3,
      ),
      throwsArgumentError,
    );
    expect(calls, isEmpty);
  });

  test('tracks fullscreen visibility for a monitor AppBar', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'isFullscreenForegroundWindowOnMonitor') {
            return true;
          }
          return {'success': true};
        });

    final service = TaskbarConfigurationService(channel: channel);
    expect(await service.isFullscreenOnMonitor('DISPLAY1'), isTrue);
    await service.setVisible(false);

    expect(calls.map((call) => call.method), [
      'isFullscreenForegroundWindowOnMonitor',
      'setTaskbarAppBarVisible',
    ]);
    expect(calls.last.arguments, {'visible': false});
  });
}
