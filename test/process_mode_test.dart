import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/process_mode.dart';

void main() {
  test('dashboard arguments classify the process as main', () {
    final parsed = parseProcessArguments([]);

    expect(parsed.mode, ProcessMode.main);
    expect(parsed.mode.value, 'main');
  });

  test('validated overlay arguments classify classic and taskbar dock', () {
    final classic = parseProcessArguments(['--overlay']);
    final dock = parseProcessArguments([
      '--overlay',
      '--overlay-type=taskbar_dock',
      '--instance-id=taskbar_dock',
      '--operation-id=7',
      '--config-revision=3',
    ]);

    expect(classic.mode, ProcessMode.classic);
    expect(classic.mode.value, 'classic');
    expect(dock.mode, ProcessMode.taskbarDock);
    expect(dock.mode.value, 'taskbar_dock');
    expect(dock.operationId, 7);
    expect(dock.configurationRevision, 3);

    final monitorDock = parseProcessArguments([
      '--overlay',
      '--overlay-type=taskbar_dock',
      '--instance-id=taskbar_dock_Display1',
      '--operation-id=8',
    ]);
    expect(monitorDock.mode, ProcessMode.taskbarDock);
    expect(monitorDock.instanceId, 'taskbar_dock_Display1');
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

  test('dock mode requires its instance identity and operation ID', () {
    expect(
      () => parseProcessArguments([
        '--overlay',
        '--overlay-type=taskbar_dock',
        '--instance-id=other',
        '--operation-id=1',
      ]),
      throwsFormatException,
    );
    expect(
      () => parseProcessArguments([
        '--overlay',
        '--overlay-type=taskbar_dock',
        '--instance-id=taskbar_dock',
      ]),
      throwsFormatException,
    );
  });
}
