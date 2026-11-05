import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/app_runtime_service.dart';

Future<({Directory root, Directory source, AppRuntimeService service})>
createRuntimeFixture() async {
  final root = await Directory.systemTemp.createTemp('wallsync-runtime-test-');
  final source = Directory('${root.path}\\source');
  final runtimeBase = Directory('${root.path}\\runtime');
  await source.create();
  await runtimeBase.create();
  await File('${source.path}\\WallSync.exe').writeAsString('executable');
  await File('${source.path}\\data.bin').writeAsString('known-good-content');
  return (
    root: root,
    source: source,
    service: AppRuntimeService(
      sourceDirectory: source,
      runtimeBaseDirectory: runtimeBase,
      executableName: 'WallSync.exe',
    ),
  );
}

void main() {
  test(
    'AppRuntimeService repairs missing and modified cached runtime files',
    () async {
      final fixture = await createRuntimeFixture();
      final executable = File('${fixture.source.path}\\WallSync.exe');
      final asset = File('${fixture.source.path}\\data.bin');
      final stableTime = DateTime.utc(2020, 1, 1);
      await executable.setLastModified(stableTime);
      await asset.setLastModified(stableTime);

      try {
        final runtime = await fixture.service.prepareRuntime(
          'TestRuntime',
          allowHardLinks: false,
        );
        final runtimeAsset = File('${runtime.path}\\data.bin');
        expect(await runtimeAsset.readAsString(), 'known-good-content');

        await runtimeAsset.writeAsString('corrupted--content');
        await fixture.service.prepareRuntime(
          'TestRuntime',
          allowHardLinks: false,
        );
        expect(await runtimeAsset.readAsString(), 'known-good-content');

        await runtimeAsset.delete();
        await fixture.service.prepareRuntime(
          'TestRuntime',
          allowHardLinks: false,
        );
        expect(await runtimeAsset.readAsString(), 'known-good-content');

        final manifest =
            jsonDecode(
                  await File(
                    '${runtime.path}\\runtime.manifest',
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        final files = manifest['files'] as Map<String, dynamic>;
        final sourceStat = await asset.stat();
        expect(files['data.bin'], {
          'size': await asset.length(),
          'modified': sourceStat.modified.microsecondsSinceEpoch,
        });

        await asset.writeAsString('updated-source-content');
        await asset.setLastModified(DateTime.utc(2021, 1, 1));
        final updatedRuntime = await fixture.service.prepareRuntime(
          'TestRuntime',
          allowHardLinks: false,
        );
        expect(updatedRuntime.path, isNot(runtime.path));
        expect(await File('${runtime.path}\\WallSync.exe').exists(), isTrue);
      } finally {
        await fixture.root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('AppRuntimeService coalesces concurrent preparation requests', () async {
    final fixture = await createRuntimeFixture();

    try {
      final first = fixture.service.prepareRuntime(
        'TestRuntime',
        allowHardLinks: false,
      );
      final second = fixture.service.prepareRuntime(
        'TestRuntime',
        allowHardLinks: false,
      );

      expect(identical(first, second), isTrue);
      final result = await Future.wait([first, second]);
      expect(result[0].path, result[1].path);
      expect(
        await File('${result[0].path}\\runtime.manifest').exists(),
        isTrue,
      );
    } finally {
      await fixture.root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('AppRuntimeService reuses prepared runtime via manifest', () async {
    final fixture = await createRuntimeFixture();

    try {
      final dir = await fixture.service.prepareRuntime(
        'TestRuntime',
        allowHardLinks: false,
      );
      final manifestFile = File('${dir.path}\\runtime.manifest');
      expect(await manifestFile.exists(), isTrue);

      final secondDir = await fixture.service.prepareRuntime(
        'TestRuntime',
        allowHardLinks: false,
      );
      expect(secondDir.path, dir.path);
    } finally {
      await fixture.root.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));

  test(
    'AppRuntimeService isolates runtimes that must not use hard links',
    () async {
      final fixture = await createRuntimeFixture();

      try {
        final linkedRuntime = await fixture.service.prepareRuntime(
          'TestRuntime',
        );
        final copiedRuntime = await fixture.service.prepareRuntime(
          'TestRuntime',
          allowHardLinks: false,
        );
        final manifest =
            jsonDecode(
                  await File(
                    '${copiedRuntime.path}\\runtime.manifest',
                  ).readAsString(),
                )
                as Map<String, dynamic>;

        expect(copiedRuntime.path, isNot(linkedRuntime.path));
        expect(manifest['allowHardLinks'], isFalse);
      } finally {
        await fixture.root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
