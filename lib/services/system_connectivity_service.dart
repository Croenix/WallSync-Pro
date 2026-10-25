import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'settings_service.dart';

typedef _ConnectivityStatusReader =
    Future<SystemConnectivitySnapshot> Function();

class SystemConnectivitySnapshot {
  const SystemConnectivitySnapshot({this.wifiEnabled, this.bluetoothEnabled});

  final bool? wifiEnabled;
  final bool? bluetoothEnabled;

  factory SystemConnectivitySnapshot.fromJsonText(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Connectivity status response is not an object.',
      );
    }
    return SystemConnectivitySnapshot(
      wifiEnabled: decoded['wifi'] is bool ? decoded['wifi'] as bool : null,
      bluetoothEnabled: decoded['bluetooth'] is bool
          ? decoded['bluetooth'] as bool
          : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SystemConnectivitySnapshot &&
      other.wifiEnabled == wifiEnabled &&
      other.bluetoothEnabled == bluetoothEnabled;

  @override
  int get hashCode => Object.hash(wifiEnabled, bluetoothEnabled);
}

/// Reads and controls the Windows network and Bluetooth adapters used by widgets.
class SystemConnectivityService {
  SystemConnectivityService._({
    _ConnectivityStatusReader? readStatus,
    this._retryDelay = const Duration(milliseconds: 500),
  }) : _readStatusOverride = readStatus;

  static final SystemConnectivityService instance =
      SystemConnectivityService._();

  @visibleForTesting
  factory SystemConnectivityService.forTesting({
    required Future<SystemConnectivitySnapshot> Function() readStatus,
    Duration retryDelay = Duration.zero,
  }) => SystemConnectivityService._(
    readStatus: readStatus,
    retryDelay: retryDelay,
  );

  static const Duration _pollInterval = Duration(seconds: 5);
  static const Duration _commandTimeout = Duration(seconds: 8);
  static const int _maxReadAttempts = 2;
  final StreamController<SystemConnectivitySnapshot> _controller =
      StreamController<SystemConnectivitySnapshot>.broadcast();
  final Set<String> _owners = {};
  final _ConnectivityStatusReader? _readStatusOverride;
  final Duration _retryDelay;
  Timer? _pollTimer;
  Future<void>? _pollInProgress;
  Process? _statusProcess;
  int _pollGeneration = 0;
  bool _disposed = false;
  SystemConnectivitySnapshot _current = const SystemConnectivitySnapshot();

  Stream<SystemConnectivitySnapshot> get stream => _controller.stream;
  SystemConnectivitySnapshot get current => _current;

  void start({required String owner}) {
    if (_disposed) {
      throw StateError('SystemConnectivityService has been disposed.');
    }
    _owners.add(owner);
    if (_pollTimer != null) return;
    unawaited(refresh());
    _pollTimer = Timer.periodic(_pollInterval, (_) => unawaited(refresh()));
  }

  void stop({required String owner}) {
    _owners.remove(owner);
    if (_owners.isNotEmpty) return;
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollGeneration++;
    _statusProcess?.kill();
  }

  Future<void> refresh() {
    if (_disposed) {
      return Future<void>.error(
        StateError('SystemConnectivityService has been disposed.'),
      );
    }
    final pending = _pollInProgress;
    if (pending != null) return pending;
    final refreshFuture = _readStatus(_pollGeneration);
    _pollInProgress = refreshFuture;
    return refreshFuture.whenComplete(() {
      if (identical(_pollInProgress, refreshFuture)) {
        _pollInProgress = null;
      }
    });
  }

  Future<void> _readStatus(int generation) async {
    if (!Platform.isWindows && _readStatusOverride == null) return;
    const script = r'''
$wifiAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match 'Wi-?Fi|WLAN' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless' })
$wifi = $null
if ($wifiAdapters.Count -gt 0) {
  $wifi = [bool](@($wifiAdapters | Where-Object { $_.Status -eq 'Up' }).Count -gt 0)
}
$bluetoothAdapters = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue |
  Where-Object { $_.FriendlyName -match 'Bluetooth' -and $_.InstanceId -match '^(USB|PCI)' })
$bluetooth = $null
if ($bluetoothAdapters.Count -gt 0) {
  $bluetooth = [bool](@($bluetoothAdapters | Where-Object { $_.Status -eq 'OK' }).Count -gt 0)
}
[PSCustomObject]@{ wifi = $wifi; bluetooth = $bluetooth } | ConvertTo-Json -Compress
''';
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 1; attempt <= _maxReadAttempts; attempt++) {
      if (_disposed || generation != _pollGeneration) return;
      try {
        final snapshot = _readStatusOverride == null
            ? await _runStatusScript(script, generation)
            : await _readStatusOverride();
        if (snapshot == null || _disposed || generation != _pollGeneration) {
          return;
        }
        if (snapshot != _current) {
          _current = snapshot;
          _controller.add(snapshot);
          logInfo(
            'SystemConnectivityService',
            'Adapter state changed: Wi-Fi=${snapshot.wifiEnabled ?? "unavailable"}, '
                'Bluetooth=${snapshot.bluetoothEnabled ?? "unavailable"}.',
          );
        }
        return;
      } catch (error, stackTrace) {
        if (_disposed || generation != _pollGeneration) return;
        lastError = error;
        lastStackTrace = stackTrace;
        if (attempt < _maxReadAttempts) {
          logWarning(
            'SystemConnectivityService',
            'Adapter status read attempt $attempt/$_maxReadAttempts failed; '
                'retrying after ${_retryDelay.inMilliseconds}ms: $error',
          );
          await Future<void>.delayed(_retryDelay);
        }
      }
    }
    if (lastError != null) {
      logError(
        'SystemConnectivityService',
        'Could not read Windows Wi-Fi/Bluetooth adapter state after '
            '$_maxReadAttempts attempts; retaining the last known state.',
        lastError,
        lastStackTrace,
      );
    }
  }

  Future<SystemConnectivitySnapshot?> _runStatusScript(
    String script,
    int generation,
  ) async {
    final process = await Process.start('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ]);
    if (_disposed || generation != _pollGeneration) {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
      return null;
    }
    _statusProcess = process;
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    try {
      final exitCode = await process.exitCode.timeout(
        _commandTimeout,
        onTimeout: () {
          process.kill();
          throw TimeoutException(
            'PowerShell adapter status query exceeded '
            '${_commandTimeout.inSeconds}s.',
          );
        },
      );
      final output = (await stdoutFuture).trim();
      final errorOutput = (await stderrFuture).trim();
      if (exitCode != 0) {
        throw ProcessException(
          'powershell',
          const ['-NoProfile', '-NonInteractive', '-Command'],
          errorOutput,
          exitCode,
        );
      }
      if (output.isEmpty) {
        throw const FormatException(
          'PowerShell returned empty adapter status.',
        );
      }
      return SystemConnectivitySnapshot.fromJsonText(output);
    } on TimeoutException {
      process.kill();
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
      await stdoutFuture;
      await stderrFuture;
      rethrow;
    } finally {
      if (identical(_statusProcess, process)) {
        _statusProcess = null;
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollGeneration++;
    final process = _statusProcess;
    final pendingPoll = _pollInProgress;
    process?.kill();
    _statusProcess = null;
    _owners.clear();
    if (process != null) {
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
    }
    if (pendingPoll != null) {
      try {
        await pendingPoll.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        logWarning(
          'SystemConnectivityService',
          'Connectivity poll did not finish within 2s during disposal.',
        );
      }
    }
    await _controller.close();
  }

  Future<void> setWifiEnabled(bool enabled) async {
    final action = enabled ? 'Enable-NetAdapter' : 'Disable-NetAdapter';
    final script =
        r'''
$adapter = Get-NetAdapter -Physical -ErrorAction Stop |
  Where-Object { $_.Name -match 'Wi-?Fi|WLAN' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless' } |
  Select-Object -First 1
if ($null -eq $adapter) { throw 'No Wi-Fi adapter was found.' }
ACTION -Name $adapter.Name -Confirm:$false -ErrorAction Stop
'''
            .replaceFirst('ACTION', action);
    await _runAdapterCommand(script, 'Wi-Fi');
    if (_current.wifiEnabled != enabled) {
      throw StateError('Windows did not confirm the requested Wi-Fi state.');
    }
  }

  Future<void> setBluetoothEnabled(bool enabled) async {
    final action = enabled ? 'Enable-PnpDevice' : 'Disable-PnpDevice';
    final script =
        r'''
$adapter = Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction Stop |
  Where-Object { $_.FriendlyName -match 'Bluetooth' -and $_.InstanceId -match '^(USB|PCI)' } |
  Select-Object -First 1
if ($null -eq $adapter) { throw 'No Bluetooth radio adapter was found.' }
ACTION -InstanceId $adapter.InstanceId -Confirm:$false -ErrorAction Stop
'''
            .replaceFirst('ACTION', action);
    await _runAdapterCommand(script, 'Bluetooth');
    if (_current.bluetoothEnabled != enabled) {
      throw StateError(
        'Windows did not confirm the requested Bluetooth adapter state.',
      );
    }
  }

  Future<void> _runAdapterCommand(String command, String adapterName) async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        '$adapterName controls are only available on Windows.',
      );
    }
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'try { \$ErrorActionPreference = "Stop"; $command } catch { [Console]::Error.WriteLine(\$_); exit 1 }',
    ]).timeout(const Duration(seconds: 15));
    if (result.exitCode != 0) {
      final detail = result.stderr.toString().trim();
      final privilegeHint =
          detail.toLowerCase().contains('access is denied') ||
              detail.toLowerCase().contains('administrator')
          ? ' Run WallSync as administrator to change this adapter.'
          : '';
      throw ProcessException(
        'powershell',
        const ['-NoProfile', '-NonInteractive', '-Command'],
        'Could not change $adapterName state.$privilegeHint $detail',
        result.exitCode,
      );
    }
    await refresh();
  }
}
