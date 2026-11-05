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
        final runtimeExecutable = File('${runtime.path}\\WallSync.exe');
        expect(await runtimeAsset.readAsString(), 'known-good-content');

        final verifiedRuntime = await fixture.service.prepareRuntime(
          'TestRuntime',
          allowHardLinks: false,
        );
        expect(verifiedRuntime.path, runtime.path);

        await runtimeExecutable.writeAsString('tampered!!');
        await runtimeExecutable.setLastModified(stableTime);
        final repairedRuntime = await fixture.service.prepareRuntime(
          'TestRuntime',
          allowHardLinks: false,
        );
        expect(repairedRuntime.path, isNot(runtime.path));
        expect(await runtimeExecutable.readAsString(), 'tampered!!');
        expect(
          await File('${repairedRuntime.path}\\WallSync.exe').readAsString(),
          'executable',
        );
        expect(
          await File('${repairedRuntime.path}\\data.bin').readAsString(),
          'known-good-content',
        );
        final reusedRepair = await fixture.service.prepareRuntime(
          'TestRuntime',
          allowHardLinks: false,
        );
        expect(reusedRepair.path, repairedRuntime.path);

        final repairedAsset = File('${repairedRuntime.path}\\data.bin');
        await repairedAsset.delete();
        final restoredRuntime = await fixture.service.prepareRuntime(
          'TestRuntime',
          allowHardLinks: false,
        );
        expect(restoredRuntime.path, isNot(repairedRuntime.path));
        expect(
          await File('${restoredRuntime.path}\\data.bin').readAsString(),
          'known-good-content',
        );

        final manifest =
            jsonDecode(
                  await File(
                    '${restoredRuntime.path}\\runtime.manifest',
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
        expect(updatedRuntime.path, isNot(restoredRuntime.path));
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

  test(
    'AppRuntimeService invalidates cached source hashes after same-size edits',
    () async {
      final fixture = await createRuntimeFixture();
      final executable = File('${fixture.source.path}\\WallSync.exe');
      final stableTime = DateTime.utc(2020, 1, 1);
      await executable.setLastModified(stableTime);

      try {
        final originalRuntime = await fixture.service.prepareRuntime(
          'TestRuntime',
          allowHardLinks: false,
        );
        await executable.writeAsString('tampered!!');
        await executable.setLastModified(stableTime);

        final updatedRuntime = await fixture.service.prepareRuntime(
          'TestRuntime',
          allowHardLinks: false,
        );

        expect(updatedRuntime.path, isNot(originalRuntime.path));
        expect(
          await File('${updatedRuntime.path}\\WallSync.exe').readAsString(),
          'tampered!!',
        );
      } finally {
        await fixture.root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'AppRuntimeService keeps concurrent source inventories isolated',
    () async {
      final fixture = await createRuntimeFixture();
      final secondSource = Directory('${fixture.root.path}\\second-source');
      await secondSource.create();
      await File(
        '${secondSource.path}\\WallSync.exe',
      ).writeAsString('second-executable');
      await File(
        '${secondSource.path}\\data.bin',
      ).writeAsString('second-runtime-content');
      final secondService = AppRuntimeService(
        sourceDirectory: secondSource,
        runtimeBaseDirectory: Directory('${fixture.root.path}\\runtime'),
        executableName: 'WallSync.exe',
      );

      try {
        final results = await Future.wait([
          fixture.service.prepareRuntime(
            'OverlayRuntime',
            allowHardLinks: false,
          ),
          secondService.prepareRuntime('OverlayRuntime', allowHardLinks: false),
        ]);

        expect(results[0].path, isNot(results[1].path));
        expect(
          await File('${results[0].path}\\data.bin').readAsString(),
          'known-good-content',
        );
        expect(
          await File('${results[1].path}\\data.bin').readAsString(),
          'second-runtime-content',
        );
      } finally {
        await fixture.root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

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
