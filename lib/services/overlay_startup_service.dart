import 'dart:io';

import 'package:flutter/services.dart';

typedef StartupCommandRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
typedef PackageStartupSync = Future<String?> Function(bool enabled);

class OverlayStartupService {
  static const runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const runValueName = 'WallSync';
  static const taskName = r'\WallSyncOverlayStartup';
  static const _startupArguments = '--startup-trigger=windows-logon';
  static const _startupChannel = MethodChannel('com.wallsync/startup');

  OverlayStartupService({
    required this.logInfo,
    required this.logWarning,
    StartupCommandRunner? runCommand,
    String? executablePath,
    bool? isWindows,
    Future<bool> Function(String path)? executableExists,
    PackageStartupSync? packageStartupSync,
  }) : _runCommand = runCommand ?? _runProcess,
       _executablePath = executablePath ?? Platform.resolvedExecutable,
       _isWindows = isWindows ?? Platform.isWindows,
       _executableExists = executableExists ?? _fileExists,
       _packageStartupSync = packageStartupSync ?? _syncPackageStartup;

  final void Function(String tag, String message) logInfo;
  final void Function(String tag, String message) logWarning;
  final StartupCommandRunner _runCommand;
  final String _executablePath;
  final bool _isWindows;
  final Future<bool> Function(String path) _executableExists;
  final PackageStartupSync _packageStartupSync;

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
  ) => Process.run(executable, arguments);

  static Future<bool> _fileExists(String path) => File(path).exists();

  static Future<String?> _syncPackageStartup(bool enabled) =>
      _startupChannel.invokeMethod<String>('sync', {'enabled': enabled});

  String get _runCommandValue => '"$_executablePath" $_startupArguments';

  Future<void> sync(bool enabled) async {
    if (!_isWindows) return;

    final packageState = await _packageStartupSync(enabled);
    if (packageState != null && packageState != 'unpackaged') {
      const packageStates = {
        'enabled',
        'disabled',
        'disabledByUser',
        'disabledByPolicy',
        'enabledByPolicy',
      };
      if (!packageStates.contains(packageState)) {
        throw StateError(
          'Windows returned an unexpected packaged startup task state: '
          '"$packageState".',
        );
      }
      if (packageState == 'disabledByUser' ||
          packageState == 'disabledByPolicy' ||
          (packageState == 'enabledByPolicy' && !enabled)) {
        logWarning(
          'OverlayStartupService',
          'Windows reports the packaged startup task as $packageState; '
              'respecting the Windows startup control.',
        );
      } else {
        logInfo(
          'OverlayStartupService',
          'Synchronized packaged startup task; Windows reports state '
              '"$packageState".',
        );
      }
      await _removeRunValue();
      await _removeRunValue('DesktopWidgetOverlay');
      await _removeLegacyTask(taskName);
      return;
    }

    if (enabled) {
      await _registerRunValue();
    } else {
      await _removeRunValue();
    }
    await _removeRunValue('DesktopWidgetOverlay');
    await _removeLegacyTask(taskName);
  }

  Future<void> _registerRunValue() async {
    if (!await _executableExists(_executablePath)) {
      throw FileSystemException(
        'Installed WallSync executable does not exist; startup registration '
        'was not changed.',
        _executablePath,
      );
    }
    if (_executablePath.contains('"')) {
      throw ArgumentError.value(
        _executablePath,
        'executablePath',
        'Windows executable paths cannot contain a quote character.',
      );
    }

    var currentValue = await _readRunValue();
    if (currentValue != _runCommandValue) {
      final result = await _runCommand('reg', [
        'add',
        runKey,
        '/v',
        runValueName,
        '/t',
        'REG_SZ',
        '/d',
        _runCommandValue,
        '/f',
      ]);
      _requireSuccess('reg add', result);

      currentValue = await _readRunValue();
      if (currentValue != _runCommandValue) {
        throw StateError(
          'Windows startup registration verification failed. Expected '
          '"$_runCommandValue", but found "${currentValue ?? '<missing>'}".',
        );
      }
      logInfo(
        'OverlayStartupService',
        'Registered and verified current-user Run value "$runValueName" '
            'for the installed executable and background startup arguments.',
      );
      return;
    }

    logInfo(
      'OverlayStartupService',
      'Current-user Run value "$runValueName" already matches the installed '
          'executable; leaving it unchanged.',
    );
  }

  Future<void> _removeRunValue([String valueName = runValueName]) async {
    final currentValue = await _readRunValue(valueName);
    if (currentValue == null) {
      logInfo(
        'OverlayStartupService',
        'Current-user Run value "$valueName" is already absent.',
      );
      return;
    }

    final result = await _runCommand('reg', [
      'delete',
      runKey,
      '/v',
      valueName,
      '/f',
    ]);
    if (result.exitCode != 0) {
      final valueAfterDelete = await _readRunValue(valueName);
      if (valueAfterDelete != null) {
        throw StateError(
          'reg delete failed (${result.exitCode}) and the startup value '
          'remains: ${_diagnostic(result)}',
        );
      }
    }

    if (await _readRunValue(valueName) != null) {
      throw StateError(
        'Windows startup registration removal could not be verified.',
      );
    }
    logInfo(
      'OverlayStartupService',
      'Removed current-user Run value "$valueName".',
    );
  }

  Future<String?> _readRunValue([String valueName = runValueName]) async {
    final result = await _runCommand('reg', ['query', runKey]);
    if (_isRegistryKeyNotFound(result)) return null;
    _requireSuccess('reg query', result);

    final valueLine = RegExp(
      '^\\s*${RegExp.escape(valueName)}\\s+REG_\\w+\\s+(.*?)\\s*\$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(result.stdout.toString());
    return valueLine?.group(1);
  }

  static bool _isRegistryKeyNotFound(ProcessResult result) {
    if (result.exitCode == 0) return false;
    final output = '${result.stderr}\n${result.stdout}'.toLowerCase();
    return output.contains(
          'unable to find the specified registry key or value',
        ) ||
        output.contains('cannot find the specified registry key or value');
  }

  Future<void> _removeLegacyTask(String name) async {
    final result = await _runCommand('schtasks', [
      '/delete',
      '/f',
      '/tn',
      name,
    ]);
    if (result.exitCode == 0) {
      logInfo(
        'OverlayStartupService',
        'Removed obsolete Task Scheduler startup task "$name".',
      );
      return;
    }

    final query = await _runCommand('schtasks', ['/query', '/tn', name]);
    if (query.exitCode == 0 || !_isTaskNotFound(query)) {
      logWarning(
        'OverlayStartupService',
        'Could not confirm removal of obsolete Task Scheduler task "$name": '
            '${_diagnostic(result)} ${_diagnostic(query)}',
      );
      throw StateError(
        'Could not confirm removal of obsolete Task Scheduler task "$name".',
      );
    }
  }

  void _requireSuccess(String operation, ProcessResult result) {
    if (result.exitCode != 0) {
      throw StateError(
        '$operation failed (${result.exitCode}): ${_diagnostic(result)}',
      );
    }
  }

  static bool _isTaskNotFound(ProcessResult result) {
    final output = '${result.stderr}\n${result.stdout}'.toLowerCase();
    return output.contains('cannot find') ||
        output.contains('could not be found') ||
        output.contains('not found');
  }

  static String _diagnostic(ProcessResult result) {
    final stdout = result.stdout.toString().trim();
    final stderr = result.stderr.toString().trim();
    final details = [
      if (stdout.isNotEmpty) 'stdout: $stdout',
      if (stderr.isNotEmpty) 'stderr: $stderr',
    ].join('; ');
    if (details.isEmpty) return 'Windows returned no additional details.';
    return details.length <= 500 ? details : '${details.substring(0, 500)}...';
  }
}
