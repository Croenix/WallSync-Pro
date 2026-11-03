import 'dart:async';
import 'dart:io';

class ProcessDiagnosticLog {
  ProcessDiagnosticLog._(this.file);

  final File file;
  Future<void> _writeQueue = Future<void>.value();
  String _processMode = 'unvalidated';
  String? _instanceId;
  int? _operationId;
  int _configurationRevision = 1;

  String get path => file.path;

  void setContext({
    required String processMode,
    String? instanceId,
    int? operationId,
    int configurationRevision = 1,
  }) {
    _processMode = processMode;
    _instanceId = instanceId;
    _operationId = operationId;
    _configurationRevision = configurationRevision;
  }

  Future<void> record(String stage, String detail) {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final line =
        '$timestamp processMode=$_processMode '
        'instanceId=${_instanceId ?? 'none'} '
        'operationId=${_operationId?.toString() ?? 'none'} '
        'configRevision=$_configurationRevision stage=$stage $detail\r\n';
    _writeQueue = _writeQueue.then<void>((_) async {
      await file.writeAsString(line, mode: FileMode.append, flush: true);
    });
    return _writeQueue;
  }

  Future<void> flush() => _writeQueue;

  static Future<ProcessDiagnosticLog> initialize(List<String> arguments) async {
    final nativePath = Platform.environment['WALLSYNC_DIAGNOSTIC_LOG'];
    final appData =
        Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    final timestamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final fallbackPath =
        '$appData${Platform.pathSeparator}com.example'
        '${Platform.pathSeparator}wallsync${Platform.pathSeparator}diagnostics'
        '${Platform.pathSeparator}process_${pid}_${timestamp}_unvalidated_none_op_0.log';
    final path = nativePath == null || nativePath.trim().isEmpty
        ? fallbackPath
        : nativePath;
    final file = File(path);
    await file.parent.create(recursive: true);
    final log = ProcessDiagnosticLog._(file);
    await log.record(
      'dart_process_entry',
      'pid=$pid rawArguments=${_quoteArguments(arguments)}',
    );
    if (nativePath == null || nativePath.trim().isEmpty) {
      await log.record(
        'native_entry_unavailable',
        'WALLSYNC_DIAGNOSTIC_LOG was not set; native startup milestones '
            'cannot be recovered for this process',
      );
    }
    return log;
  }

  static Future<File?> findForProcess(int processId) async {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    final directory = Directory('$appData\\com.example\\wallsync\\diagnostics');
    if (!await directory.exists()) return null;
    final prefix = 'process_${processId}_';
    final files = <File>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File &&
          _fileName(entity.path).startsWith(prefix) &&
          entity.path.toLowerCase().endsWith('.log')) {
        files.add(entity);
      }
    }
    if (files.isEmpty) return null;
    files.sort((left, right) => left.path.compareTo(right.path));
    return files.last;
  }

  static Future<void> appendToFile(
    File file,
    String stage,
    String detail,
  ) async {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    await file.writeAsString(
      '$timestamp stage=$stage $detail\r\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  static Future<String> lastCompletedStage(File? file) async {
    if (file == null || !await file.exists()) {
      return 'native-entry-not-recorded';
    }
    final lines = await file.readAsLines();
    for (final line in lines.reversed) {
      final match = RegExp(r'\bstage=([^\s]+)').firstMatch(line);
      final stage = match?.group(1);
      if (stage != null &&
          !const {
            'process_exit',
            'window_message_loop',
            'flutter_window_shutdown',
            'shutdown',
            'child_stdout',
            'child_stderr',
            'parent_process_spawned',
            'parent_connection_acknowledged',
            'child_process_exit',
          }.contains(stage)) {
        return stage;
      }
    }

    Future<List<String>> readLastLines(File? file, {int limit = 8}) async {
      if (file == null || !await file.exists()) return const [];
      final lines = await file.readAsLines();
      return lines.length <= limit
          ? lines
          : lines.sublist(lines.length - limit);
    }

    return 'no-startup-stage-recorded';
  }

  static String _quoteArguments(List<String> arguments) => arguments
      .map((argument) => '"${argument.replaceAll('"', r'\"')}"')
      .join(' ');

  static String _fileName(String path) =>
      path.substring(path.lastIndexOf(Platform.pathSeparator) + 1);
}
