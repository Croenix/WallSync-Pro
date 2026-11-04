import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/process_mode.dart';

void main() {
  test('dashboard arguments classify the process as main', () {
    final parsed = parseProcessArguments([]);

    expect(parsed.mode, ProcessMode.main);
    expect(parsed.mode.value, 'main');
  });

  test('validated overlay arguments classify classic mode', () {
    final classic = parseProcessArguments(['--overlay']);

    expect(classic.mode, ProcessMode.classic);
    expect(classic.mode.value, 'classic');
  });

  test('wallpaper mode remains independent from overlay mode', () {
    final parsed = parseProcessArguments([
      '--wallpaper',
      '--video-path',
      r'C:\Wallpapers\loop.mp4',
    ]);

    expect(parsed.mode, ProcessMode.wallpaper);
    expect(parsed.videoPath, r'C:\Wallpapers\loop.mp4');
  });

  test('rejects unknown and contradictory process arguments', () {
    expect(
      () => parseProcessArguments(['--overlay', '--overlay-type=unknown']),
      throwsFormatException,
    );
    expect(
      () => parseProcessArguments(['--overlay-type=classic']),
      throwsFormatException,
    );
    expect(
      () => parseProcessArguments(['--overlay', '--wallpaper']),
      throwsFormatException,
    );
    expect(
      () => parseProcessArguments(['--unexpected-mode']),
      throwsFormatException,
    );
  });

  test('retired taskbar dock process type is rejected', () {
    expect(
      () => parseProcessArguments([
        '--overlay',
        '--overlay-type=taskbar_dock',
      ]),
      throwsFormatException,
    );
  });
}
