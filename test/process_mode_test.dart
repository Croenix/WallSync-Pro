import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/process_mode.dart';
import 'package:wall_sync/services/settings_service.dart';

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

  test('keeps process mode, instance ID and visual template independent', () {
    final parsed = parseProcessArguments([
      '--overlay',
      '--instance-id=widget-instance-7',
      '--template-id=split',
      '--operation-id=42',
      '--config-revision=3',
    ]);

    expect(parsed.mode, ProcessMode.classic);
    expect(parsed.instanceId, 'widget-instance-7');
    expect(parsed.templateId, 'split');
    expect(parsed.operationId, 42);
    expect(parsed.configurationRevision, 3);
  });

  test('every supported visual template passes through process arguments', () {
    final supportedTemplates = WidgetSettings.templateDefaults.keys.where(
      (id) => !id.startsWith('taskbar_'),
    );

    for (final templateId in supportedTemplates) {
      final parsed = parseProcessArguments([
        '--overlay',
        '--instance-id=instance-1',
        '--template-id=$templateId',
      ]);
      expect(parsed.templateId, templateId);
      expect(parsed.instanceId, 'instance-1');
      expect(parsed.mode, ProcessMode.classic);
    }
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
      () => parseProcessArguments(['--overlay', '--template-id=bad template']),
      throwsFormatException,
    );
    expect(
      () => parseProcessArguments([
        '--overlay',
        '--template-id=split',
        '--template-id=classic',
      ]),
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
      () => parseProcessArguments(['--overlay', '--overlay-type=taskbar_dock']),
      throwsFormatException,
    );
  });
}
