import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/app_runtime_service.dart';

void main() {
  test('AppRuntimeService coalesces concurrent preparation requests', () async {
    final service = AppRuntimeService();
    final first = service.prepareRuntime('OverlayRuntime');
    final second = service.prepareRuntime('OverlayRuntime');

    expect(identical(first, second), isTrue);
    final result = await Future.wait([first, second]);
    expect(result[0].path, result[1].path);
    expect(await File('${result[0].path}\\runtime.manifest').exists(), isTrue);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('AppRuntimeService reuses prepared runtime via manifest', () async {
    final service = AppRuntimeService();
    final dir = await service.prepareRuntime('OverlayRuntime');
    final manifestFile = File('${dir.path}\\runtime.manifest');
    expect(await manifestFile.exists(), isTrue);

    final secondDir = await service.prepareRuntime('OverlayRuntime');
    expect(secondDir.path, dir.path);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
