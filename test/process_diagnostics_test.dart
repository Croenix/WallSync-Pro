import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/process_diagnostics.dart';

void main() {
  test(
    'identifies last startup stage without treating shutdown as progress',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wallsync-process-diagnostics-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}\\child.log');
      await file.writeAsString(
        '2026-11-04T10:00:00Z stage=native_window_initialization result=success\n'
        '2026-11-04T10:00:01Z stage=window_message_loop result=started\n'
        '2026-11-04T10:00:02Z stage=child_stderr output="engine warning"\n',
      );

      expect(
        await ProcessDiagnosticLog.lastCompletedStage(file),
        'native_window_initialization',
      );
      await file.writeAsString(
        '${await file.readAsString()}'
        '2026-11-04T10:00:03Z stage=process_exit exitCode=1\n',
      );
      expect(
        await ProcessDiagnosticLog.lastCompletedStage(file),
        'native_window_initialization',
      );
    },
  );
}
