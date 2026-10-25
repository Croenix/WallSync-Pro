import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wall_sync/services/live_wallpaper_manager.dart';
import 'package:wall_sync/services/mpv_runtime_resolver.dart';
import 'package:wall_sync/services/settings_service.dart';
import 'package:wall_sync/services/video_thumbnail_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final resolver = MpvRuntimeResolver.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resolver.invalidateCache();
  });

  test('resolves a bundled MPV executable in plugins/mpv next to runner', () async {
    final root = await Directory.systemTemp.createTemp('wallsync-test-mpv-');
    addTearDown(() => root.delete(recursive: true));

    final bundledExe = await _writeFakeMpvExecutable(
      '${root.path}${Platform.pathSeparator}Release'
      '${Platform.pathSeparator}plugins${Platform.pathSeparator}mpv'
      '${Platform.pathSeparator}mpv.exe',
    );
    final runnerPath =
        '${root.path}${Platform.pathSeparator}Release'
        '${Platform.pathSeparator}WallSync.exe';

    final candidates = MpvRuntimeResolver.candidatePathsForTesting(
      executablePath: runnerPath,
      currentDirectory: root.path,
      environment: const {},
    );

    final info = await resolver.resolve(
      refresh: true,
      candidateOverrides: candidates,
    );

    expect(info.path, bundledExe.absolute.path);
    expect(info.architecture, 'x64');
    expect(info.fileSizeBytes, greaterThan(0));
    expect(candidates.first, bundledExe.path);
  });

  test('resolves bundled MPV with spaces in directories correctly', () async {
    final root = await Directory.systemTemp.createTemp('wallsync test space-');
    addTearDown(() => root.delete(recursive: true));

    final bundledExe = await _writeFakeMpvExecutable(
      '${root.path}${Platform.pathSeparator}Program Files'
      '${Platform.pathSeparator}WallSync Desktop'
      '${Platform.pathSeparator}plugins${Platform.pathSeparator}mpv'
      '${Platform.pathSeparator}mpv.exe',
    );
    await resolver.setConfiguredPath(bundledExe.path);

    final resolved = await resolver.requireExecutablePath(refresh: true);
    expect(resolved, bundledExe.absolute.path);

    final thumbExe = await VideoThumbnailService.findMpvExecutable();
    expect(thumbExe, bundledExe.absolute.path);
  });

  test('throws MpvRuntimeMissingException with diagnostics when missing', () async {
    final missing =
        '${Directory.systemTemp.path}${Platform.pathSeparator}missing_dir'
        '${Platform.pathSeparator}mpv.exe';

    expect(
      () => resolver.resolve(
        refresh: true,
        candidateOverrides: [missing],
      ),
      throwsA(isA<MpvRuntimeMissingException>()),
    );

    try {
      await resolver.resolve(
        refresh: true,
        candidateOverrides: [missing],
      );
      fail('Should have thrown MpvRuntimeMissingException');
    } on MpvRuntimeMissingException catch (e) {
      expect(e.userFacingMessage, contains('Built-in video wallpaper engine'));
      expect(e.diagnostics, contains('missing'));
    }
  });

  test('rejects empty (0 byte) executable files', () async {
    final root = await Directory.systemTemp.createTemp('wallsync-empty-');
    addTearDown(() => root.delete(recursive: true));

    final emptyFile = File('${root.path}${Platform.pathSeparator}mpv.exe');
    await emptyFile.create(recursive: true);

    expect(
      () => resolver.resolve(
        refresh: true,
        candidateOverrides: [emptyFile.path],
      ),
      throwsA(isA<MpvRuntimeMissingException>()),
    );
  });

  test('cached result avoids repeated disk searches', () async {
    final root = await Directory.systemTemp.createTemp('wallsync-cache-');
    addTearDown(() => root.delete(recursive: true));

    final bundledExe = await _writeFakeMpvExecutable(
      '${root.path}${Platform.pathSeparator}plugins${Platform.pathSeparator}mpv'
      '${Platform.pathSeparator}mpv.exe',
    );

    final first = await resolver.resolve(
      refresh: true,
      candidateOverrides: [bundledExe.path],
    );
    expect(first.path, bundledExe.absolute.path);

    // Now override candidates to an invalid path without refresh: should return cached result
    final second = await resolver.resolve(
      refresh: false,
      candidateOverrides: [r'C:\invalid\path\mpv.exe'],
    );
    expect(second.path, bundledExe.absolute.path);

    // Invalidate cache: should now throw
    resolver.invalidateCache();
    expect(
      () => resolver.resolve(
        refresh: false,
        candidateOverrides: [r'C:\invalid\path\mpv.exe'],
      ),
      throwsA(isA<MpvRuntimeMissingException>()),
    );
  });

  test('LiveWallpaperManager passes resolved mpvPath to native startMpv', () async {
    if (!Platform.isWindows) return;

    final root = await Directory.systemTemp.createTemp('wallsync-pass-');
    addTearDown(() => root.delete(recursive: true));

    final fakeExe = await _writeFakeMpvExecutable(
      '${root.path}${Platform.pathSeparator}plugins${Platform.pathSeparator}mpv'
      '${Platform.pathSeparator}mpv.exe',
    );
    await resolver.setConfiguredPath(fakeExe.path);

    Map<Object?, Object?>? receivedArgs;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LiveWallpaperManager.channel, (call) async {
      if (call.method == 'startMpv') {
        receivedArgs = call.arguments as Map<Object?, Object?>;
        return const {
          'success': true,
          'frameDecoded': true,
          'windowAttached': true,
          'windowVisible': true,
          'width': 1920,
          'height': 1080,
          'pid': 8888,
        };
      }
      return null;
    });

    final manager = LiveWallpaperManager();
    try {
      await manager.start(
        WidgetSettings(
          activeWallpaperType: 'video',
          activeWallpaperPath: r'C:\wallpapers\test.mp4',
        ),
      );
      expect(receivedArgs?['mpvPath'], fakeExe.absolute.path);
    } finally {
      manager.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LiveWallpaperManager.channel, null);
    }
  });
}

Future<File> _writeFakeMpvExecutable(String path) async {
  final file = File(path);
  await file.parent.create(recursive: true);

  // Write a minimal valid PE header indicating x64 (IMAGE_FILE_MACHINE_AMD64 = 0x8664)
  final bytes = List<int>.filled(512, 0);
  // MZ header
  bytes[0] = 0x4D;
  bytes[1] = 0x5A;
  // e_lfanew at 0x3C pointing to offset 0x80
  bytes[0x3C] = 0x80;
  bytes[0x3D] = 0x00;
  bytes[0x3E] = 0x00;
  bytes[0x3F] = 0x00;
  // PE signature at 0x80 ('PE\0\0')
  bytes[0x80] = 0x50;
  bytes[0x81] = 0x45;
  bytes[0x82] = 0x00;
  bytes[0x83] = 0x00;
  // COFF machine type at 0x84: 0x8664 (x64)
  bytes[0x84] = 0x64;
  bytes[0x85] = 0x86;

  await file.writeAsBytes(bytes, flush: true);
  return file;
}
