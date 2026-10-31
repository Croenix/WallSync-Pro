import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'settings_service.dart';

enum OverlayLifecycleState {
  stopped,
  preparing,
  launching,
  processStarted,
  windowInitialized,
  firstFrameRendered,
  ready,
  failedOrTimedOut,
  stopping;

  bool get isTerminal => this == stopped || this == failedOrTimedOut;
  bool get isRunning => this != stopped && this != failedOrTimedOut;
}

class OverlayProcessRecord {
  const OverlayProcessRecord({
    required this.pid,
    required this.creationTime,
    required this.executablePath,
    this.ready = true,
    this.state = OverlayLifecycleState.ready,
    this.entryPointMs,
    this.settingsLoadedMs,
    this.windowInitMs,
    this.firstFrameMs,
    this.readyPublishedMs,
    this.acknowledgedMs,
    this.failureReason,
  });

  final int pid;
  final int? creationTime;
  final String? executablePath;
  final bool ready;
  final OverlayLifecycleState state;
  final int? entryPointMs;
  final int? settingsLoadedMs;
  final int? windowInitMs;
  final int? firstFrameMs;
  final int? readyPublishedMs;
  final int? acknowledgedMs;
  final String? failureReason;

  OverlayProcessRecord copyWith({
    int? pid,
    int? creationTime,
    String? executablePath,
    bool? ready,
    OverlayLifecycleState? state,
    int? entryPointMs,
    int? settingsLoadedMs,
    int? windowInitMs,
    int? firstFrameMs,
    int? readyPublishedMs,
    int? acknowledgedMs,
    String? failureReason,
  }) => OverlayProcessRecord(
    pid: pid ?? this.pid,
    creationTime: creationTime ?? this.creationTime,
    executablePath: executablePath ?? this.executablePath,
    ready: ready ?? this.ready,
    state: state ?? this.state,
    entryPointMs: entryPointMs ?? this.entryPointMs,
    settingsLoadedMs: settingsLoadedMs ?? this.settingsLoadedMs,
    windowInitMs: windowInitMs ?? this.windowInitMs,
    firstFrameMs: firstFrameMs ?? this.firstFrameMs,
    readyPublishedMs: readyPublishedMs ?? this.readyPublishedMs,
    acknowledgedMs: acknowledgedMs ?? this.acknowledgedMs,
    failureReason: failureReason ?? this.failureReason,
  );

  Map<String, Object?> toJson() => {
    'pid': pid,
    'creationTime': creationTime,
    'executablePath': executablePath,
    'ready': ready,
    'state': state.name,
    if (entryPointMs != null) 'entryPointMs': entryPointMs,
    if (settingsLoadedMs != null) 'settingsLoadedMs': settingsLoadedMs,
    if (windowInitMs != null) 'windowInitMs': windowInitMs,
    if (firstFrameMs != null) 'firstFrameMs': firstFrameMs,
    if (readyPublishedMs != null) 'readyPublishedMs': readyPublishedMs,
    if (acknowledgedMs != null) 'acknowledgedMs': acknowledgedMs,
    if (failureReason != null) 'failureReason': failureReason,
  };

  static OverlayProcessRecord? tryParse(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;
    final legacyPid = int.tryParse(text);
    if (legacyPid != null && legacyPid > 0) {
      return OverlayProcessRecord(
        pid: legacyPid,
        creationTime: null,
        executablePath: null,
        ready: true,
        state: OverlayLifecycleState.ready,
      );
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      final pid = decoded['pid'];
      final rawCreationTime = decoded['creationTime'];
      final creationTime = rawCreationTime is int
          ? rawCreationTime
          : rawCreationTime is String
          ? int.tryParse(rawCreationTime)
          : null;
      final executablePath = decoded['executablePath'];
      final rawReady = decoded['ready'];
      if (pid is! int ||
          pid <= 0 ||
          creationTime == null ||
          creationTime <= 0 ||
          (executablePath != null &&
              (executablePath is! String || executablePath.isEmpty)) ||
          (rawReady != null && rawReady is! bool)) {
        return null;
      }
      final bool ready = rawReady as bool? ?? true;
      OverlayLifecycleState state;
      final rawState = decoded['state'];
      if (rawState is String) {
        state = OverlayLifecycleState.values.firstWhere(
          (s) => s.name == rawState,
          orElse: () => ready ? OverlayLifecycleState.ready : OverlayLifecycleState.processStarted,
        );
      } else {
        state = ready ? OverlayLifecycleState.ready : OverlayLifecycleState.processStarted;
      }

      int? parseMs(dynamic val) => val is int ? val : (val is String ? int.tryParse(val) : null);

      return OverlayProcessRecord(
        pid: pid,
        creationTime: creationTime,
        executablePath: executablePath is String ? executablePath : null,
        ready: ready,
        state: state,
        entryPointMs: parseMs(decoded['entryPointMs']),
        settingsLoadedMs: parseMs(decoded['settingsLoadedMs']),
        windowInitMs: parseMs(decoded['windowInitMs']),
        firstFrameMs: parseMs(decoded['firstFrameMs']),
        readyPublishedMs: parseMs(decoded['readyPublishedMs']),
        acknowledgedMs: parseMs(decoded['acknowledgedMs']),
        failureReason: decoded['failureReason'] as String?,
      );
    } on FormatException {
      return null;
    }
  }

  bool matches(OverlayProcessRecord other) =>
      pid == other.pid &&
      creationTime == other.creationTime &&
      (executablePath == null ||
          other.executablePath == null ||
          _normalizePath(executablePath) ==
              _normalizePath(other.executablePath));
}

class OverlayProcessInspection {
  const OverlayProcessInspection({
    required this.isRunning,
    required this.creationTime,
    required this.executablePath,
    this.executablePathAccessible = true,
  });

  final bool isRunning;
  final int creationTime;
  final String? executablePath;
  final bool executablePathAccessible;

  bool matches(OverlayProcessRecord record) =>
      record.creationTime == creationTime &&
      (!isRunning ||
          !executablePathAccessible ||
          record.executablePath == null ||
          _normalizePath(record.executablePath) ==
              _normalizePath(executablePath));
}

enum OverlayCloseResult {
  noProcessRecord,
  stoppedGracefully,
  stoppedAfterForceTermination,
  processIdentityChanged,
  processCouldNotBeVerified,
  processDidNotExit,
}

enum OverlayReadinessStatus {
  ready,
  starting,
  missing,
  malformed,
  exited,
  identityMismatch,
  unverifiable,
  failed,
}

const overlayWindowVisibilityRetryDelays = <Duration>[
  Duration(milliseconds: 200),
  Duration(milliseconds: 400),
  Duration(milliseconds: 800),
  Duration(milliseconds: 1600),
  Duration(milliseconds: 3200),
  Duration(milliseconds: 6400),
  Duration(seconds: 8),
  Duration(seconds: 12),
];

Offset clampOverlayPositionToDisplays({
  required Offset requested,
  required Size windowSize,
  required List<Rect> displayBounds,
}) {
  if (displayBounds.isEmpty) return requested;

  final isFullyOnDisplay = displayBounds.any(
    (bounds) =>
        requested.dx >= bounds.left &&
        requested.dy >= bounds.top &&
        requested.dx + windowSize.width <= bounds.right &&
        requested.dy + windowSize.height <= bounds.bottom,
  );
  if (isFullyOnDisplay) return requested;

  var closest = requested;
  var closestDistance = double.infinity;
  for (final bounds in displayBounds) {
    final maxX = math.max(bounds.left, bounds.right - windowSize.width);
    final maxY = math.max(bounds.top, bounds.bottom - windowSize.height);
    final candidate = Offset(
      requested.dx.clamp(bounds.left, maxX).toDouble(),
      requested.dy.clamp(bounds.top, maxY).toDouble(),
    );
    final dx = candidate.dx - requested.dx;
    final dy = candidate.dy - requested.dy;
    final distance = dx * dx + dy * dy;
    if (distance < closestDistance) {
      closest = candidate;
      closestDistance = distance;
    }
  }
  return closest;
}

Future<bool> waitForOverlayWindowVisibility({
  required Future<bool> Function() isVisible,
  List<Duration> retryDelays = overlayWindowVisibilityRetryDelays,
  void Function(int attempt, Duration delay)? onRetry,
}) async {
  for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
    if (await isVisible()) return true;
    if (attempt == retryDelays.length) return false;
    final delay = retryDelays[attempt];
    onRetry?.call(attempt + 1, delay);
    await Future<void>.delayed(delay);
  }
  return false;
}

class OverlayReadinessResult {
  const OverlayReadinessResult({
    required this.status,
    this.record,
    this.inspection,
    required this.elapsed,
  });

  final OverlayReadinessStatus status;
  final OverlayProcessRecord? record;
  final OverlayProcessInspection? inspection;
  final Duration elapsed;

  bool get isReady => status == OverlayReadinessStatus.ready;
}

Future<OverlayReadinessResult> waitForOverlayReadiness({
  required Future<OverlayProcessRecord?> Function() readRecord,
  required OverlayProcessInspector inspectProcess,
  Duration timeout = const Duration(seconds: 30),
  Duration pollInterval = const Duration(milliseconds: 250),
  void Function(
    OverlayReadinessStatus status,
    OverlayProcessRecord? record,
    OverlayProcessInspection? inspection,
    Duration elapsed,
  )?
  onStatusChanged,
}) async {
  final stopwatch = Stopwatch()..start();
  var status = OverlayReadinessStatus.missing;
  var previousStatus = status;
  int? previousPid;
  OverlayProcessRecord? latestRecord;
  OverlayProcessInspection? latestInspection;
  do {
    try {
      latestRecord = await readRecord();
      if (latestRecord == null) {
        status = OverlayReadinessStatus.missing;
      } else {
        latestInspection = await inspectProcess(latestRecord.pid);
        if (latestInspection == null) {
          status = OverlayReadinessStatus.unverifiable;
        } else if (!latestInspection.matches(latestRecord)) {
          status = OverlayReadinessStatus.identityMismatch;
        } else if (!latestInspection.isRunning) {
          status = OverlayReadinessStatus.exited;
        } else if (latestRecord.state == OverlayLifecycleState.failedOrTimedOut) {
          status = OverlayReadinessStatus.failed;
        } else if (!latestRecord.ready) {
          status = OverlayReadinessStatus.starting;
        } else {
          status = OverlayReadinessStatus.ready;
        }
      }
    } on FormatException {
      status = OverlayReadinessStatus.malformed;
      latestRecord = null;
      latestInspection = null;
    }
    if (status != previousStatus || latestRecord?.pid != previousPid) {
      onStatusChanged?.call(
        status,
        latestRecord,
        latestInspection,
        stopwatch.elapsed,
      );
      previousStatus = status;
      previousPid = latestRecord?.pid;
    }
    if (status == OverlayReadinessStatus.ready) {
      return OverlayReadinessResult(
        status: status,
        record: latestRecord,
        inspection: latestInspection,
        elapsed: stopwatch.elapsed,
      );
    }
    if (stopwatch.elapsed >= timeout) break;
    await Future<void>.delayed(pollInterval);
  } while (stopwatch.elapsed < timeout);

  // Final reconciliation check right at timeout boundary
  if (status != OverlayReadinessStatus.ready) {
    try {
      final finalRecord = await readRecord();
      if (finalRecord != null && finalRecord.ready) {
        final finalInspection = await inspectProcess(finalRecord.pid);
        if (finalInspection != null &&
            finalInspection.matches(finalRecord) &&
            finalInspection.isRunning) {
          return OverlayReadinessResult(
            status: OverlayReadinessStatus.ready,
            record: finalRecord,
            inspection: finalInspection,
            elapsed: stopwatch.elapsed,
          );
        }
      }
    } catch (_) {}
  }

  return OverlayReadinessResult(
    status: status,
    record: latestRecord,
    inspection: latestInspection,
    elapsed: stopwatch.elapsed,
  );
}

class OverlayLaunchGate {
  Future<void>? _launchInProgress;

  Future<void> run(Future<void> Function() launch) {
    final pending = _launchInProgress;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = Future<void>.microtask(launch).whenComplete(() {
      if (identical(_launchInProgress, operation)) {
        _launchInProgress = null;
      }
    });
    _launchInProgress = operation;
    return operation;
  }
}

const overlayRecoveryRetryDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 3),
  Duration(seconds: 8),
];

class OverlayRecoveryPolicy {
  int _attempts = 0;

  int get attempts => _attempts;

  Duration? nextDelay() {
    if (_attempts >= overlayRecoveryRetryDelays.length) return null;
    return overlayRecoveryRetryDelays[_attempts++];
  }

  void reset() => _attempts = 0;
}

typedef OverlayProcessReader = Future<OverlayProcessRecord?> Function();
typedef OverlayProcessInspector =
    Future<OverlayProcessInspection?> Function(int pid);
typedef OverlayExitRequester =
    Future<void> Function(OverlayProcessRecord record);
typedef OverlayProcessTerminator =
    Future<void> Function(OverlayProcessRecord record);
typedef OverlayRecordCleaner =
    Future<void> Function(OverlayProcessRecord record);

class OverlayLifecycleService {
  factory OverlayLifecycleService({
    required OverlayProcessReader readRecord,
    required OverlayProcessInspector inspectProcess,
    required OverlayExitRequester requestExit,
    required OverlayProcessTerminator terminateProcess,
    required OverlayRecordCleaner removeRecordIfMatches,
    Duration gracefulTimeout = const Duration(seconds: 6),
    Duration forceExitTimeout = const Duration(seconds: 4),
    Duration pollInterval = const Duration(milliseconds: 100),
  }) => OverlayLifecycleService._(
    readRecord: readRecord,
    inspectProcess: inspectProcess,
    requestExit: requestExit,
    terminateProcess: terminateProcess,
    removeRecordIfMatches: removeRecordIfMatches,
    gracefulTimeout: gracefulTimeout,
    forceExitTimeout: forceExitTimeout,
    pollInterval: pollInterval,
  );

  OverlayLifecycleService._({
    required this._readRecord,
    required this._inspectProcess,
    required this._requestExit,
    required this._terminateProcess,
    required this._removeRecordIfMatches,
    required this.gracefulTimeout,
    required this.forceExitTimeout,
    required this.pollInterval,
  });

  factory OverlayLifecycleService.forApp(SettingsService settingsService) {
    final pidFileFuture = settingsService.pidFile;

    Future<OverlayProcessRecord?> readRecord() async {
      final pidFile = await pidFileFuture;
      if (!await pidFile.exists()) return null;
      final contents = await pidFile.readAsString();
      final record = OverlayProcessRecord.tryParse(contents);
      if (record == null) {
        logWarning(
          'OverlayLifecycleService',
          'Overlay PID record is malformed; leaving it untouched.',
        );
        throw const FormatException('Overlay PID record is malformed.');
      }
      return record;
    }

    Future<void> withPidFileLock(
      Future<void> Function(File pidFile) action,
    ) async {
      final pidFile = await pidFileFuture;
      final lockFile = File('${pidFile.path}.lock');
      final lock = await lockFile.open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive).timeout(const Duration(seconds: 2));
        await action(pidFile);
      } finally {
        try {
          await lock.unlock();
        } finally {
          await lock.close();
        }
      }
    }

    Future<void> removeRecordIfMatches(OverlayProcessRecord expected) =>
        withPidFileLock((pidFile) async {
          if (!await pidFile.exists()) return;
          final actual = OverlayProcessRecord.tryParse(
            await pidFile.readAsString(),
          );
          if (actual?.matches(expected) == true) {
            await pidFile.delete();
            logInfo(
              'OverlayLifecycleService',
              'Removed PID record for stopped overlay process ${expected.pid}.',
            );
          }
        });

    return OverlayLifecycleService(
      readRecord: readRecord,
      inspectProcess: inspectWindowsProcess,
      requestExit: (_) async {
        await settingsService.updateSettings(
          (current) => current.copyWith(exitOverlay: true),
        );
      },
      terminateProcess: terminateWindowsProcess,
      removeRecordIfMatches: removeRecordIfMatches,
    );
  }

  static Future<void> writeCurrentProcessRecord(
    SettingsService settingsService, {
    bool ready = false,
    OverlayLifecycleState state = OverlayLifecycleState.processStarted,
    int? entryPointMs,
    int? settingsLoadedMs,
    int? windowInitMs,
    int? firstFrameMs,
    int? readyPublishedMs,
    int? acknowledgedMs,
    String? failureReason,
  }) async {
    final stopwatch = Stopwatch()..start();
    final identityStopwatch = Stopwatch()..start();
    final record = await currentWindowsProcessRecord();
    final identityMs = identityStopwatch.elapsedMilliseconds;
    final pidFile = await settingsService.pidFile;
    final lockFile = File('${pidFile.path}.lock');
    final lock = await lockFile.open(mode: FileMode.append);
    try {
      final lockStopwatch = Stopwatch()..start();
      await lock.lock(FileLock.exclusive).timeout(const Duration(seconds: 2));
      final lockWaitMs = lockStopwatch.elapsedMilliseconds;
      final writeStopwatch = Stopwatch()..start();

      OverlayProcessRecord? existingRecord;
      if (await pidFile.exists()) {
        try {
          existingRecord = OverlayProcessRecord.tryParse(await pidFile.readAsString());
        } catch (_) {}
      }

      if (ready) {
        if (existingRecord == null) {
          throw StateError(
            'Cannot acknowledge overlay readiness without a PID record.',
          );
        }
        if (!existingRecord.matches(record)) {
          throw StateError(
            'Overlay PID record changed before readiness acknowledgement.',
          );
        }
      }

      final registered = OverlayProcessRecord(
        pid: record.pid,
        creationTime: record.creationTime,
        executablePath: record.executablePath,
        ready: ready,
        state: state,
        entryPointMs: entryPointMs ?? existingRecord?.entryPointMs,
        settingsLoadedMs: settingsLoadedMs ?? existingRecord?.settingsLoadedMs,
        windowInitMs: windowInitMs ?? existingRecord?.windowInitMs,
        firstFrameMs: firstFrameMs ?? existingRecord?.firstFrameMs,
        readyPublishedMs: readyPublishedMs ?? (ready ? DateTime.now().millisecondsSinceEpoch : existingRecord?.readyPublishedMs),
        acknowledgedMs: acknowledgedMs ?? existingRecord?.acknowledgedMs,
        failureReason: failureReason ?? existingRecord?.failureReason,
      );
      final temporaryFile = File(
        '${pidFile.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      try {
        await temporaryFile.writeAsString(
          jsonEncode(registered.toJson()),
          flush: true,
        );
        var replaced = false;
        for (var attempt = 0; attempt < 3; attempt++) {
          try {
            if (await pidFile.exists()) {
              try {
                await pidFile.delete();
              } catch (_) {}
            }
            await temporaryFile.rename(pidFile.path);
            replaced = true;
            break;
          } on FileSystemException {
            if (attempt < 2) {
              await Future<void>.delayed(const Duration(milliseconds: 40));
            }
          }
        }
        if (!replaced) {
          await pidFile.writeAsString(
            jsonEncode(registered.toJson()),
            flush: true,
          );
        }
      } finally {
        if (await temporaryFile.exists()) {
          try {
            await temporaryFile.delete();
          } on FileSystemException catch (error) {
            logWarning(
              'OverlayLifecycleService',
              'Could not remove temporary PID record ${temporaryFile.path}: '
                  '$error',
            );
          }
        }
      }
      logInfo(
        'OverlayLifecycleService',
        'Registered overlay process identity: PID ${record.pid}, '
            'state=${state.name}, ready=$ready, executable=${record.executablePath ?? '<inaccessible>'} '
            '(identity ${identityMs}ms, PID-file lock ${lockWaitMs}ms, '
            'write ${writeStopwatch.elapsedMilliseconds}ms, '
            'total ${stopwatch.elapsedMilliseconds}ms).',
      );
    } finally {
      try {
        await lock.unlock();
      } finally {
        await lock.close();
      }
    }
  }

  static Future<void> updateCurrentProcessState(
    SettingsService settingsService, {
    required OverlayLifecycleState state,
    bool? ready,
    int? entryPointMs,
    int? settingsLoadedMs,
    int? windowInitMs,
    int? firstFrameMs,
    int? readyPublishedMs,
    int? acknowledgedMs,
    String? failureReason,
  }) => writeCurrentProcessRecord(
    settingsService,
    state: state,
    ready: ready ?? (state == OverlayLifecycleState.ready),
    entryPointMs: entryPointMs,
    settingsLoadedMs: settingsLoadedMs,
    windowInitMs: windowInitMs,
    firstFrameMs: firstFrameMs,
    readyPublishedMs: readyPublishedMs,
    acknowledgedMs: acknowledgedMs,
    failureReason: failureReason,
  );

  static Future<void> markCurrentProcessReady(
    SettingsService settingsService, {
    int? readyPublishedMs,
  }) => updateCurrentProcessState(
    settingsService,
    state: OverlayLifecycleState.ready,
    ready: true,
    readyPublishedMs: readyPublishedMs ?? DateTime.now().millisecondsSinceEpoch,
  );

  static Future<void> markCurrentProcessFailed(
    SettingsService settingsService, {
    required String reason,
  }) => updateCurrentProcessState(
    settingsService,
    state: OverlayLifecycleState.failedOrTimedOut,
    ready: false,
    failureReason: reason,
  );

  final OverlayProcessReader _readRecord;
  final OverlayProcessInspector _inspectProcess;
  final OverlayExitRequester _requestExit;
  final OverlayProcessTerminator _terminateProcess;
  final OverlayRecordCleaner _removeRecordIfMatches;
  final Duration gracefulTimeout;
  final Duration forceExitTimeout;
  final Duration pollInterval;
  Future<OverlayCloseResult>? _closeInProgress;

  Future<OverlayCloseResult> close() {
    final pending = _closeInProgress;
    if (pending != null) return pending;
    late final Future<OverlayCloseResult> operation;
    operation = _close().whenComplete(() {
      if (identical(_closeInProgress, operation)) {
        _closeInProgress = null;
      }
    });
    _closeInProgress = operation;
    return operation;
  }

  Future<OverlayCloseResult> _close() async {
    final record = await _readRecord();
    if (record == null) return OverlayCloseResult.noProcessRecord;
    if (record.creationTime == null) {
      return OverlayCloseResult.processCouldNotBeVerified;
    }

    final beforeClose = await _inspectProcess(record.pid);
    if (beforeClose == null) {
      return OverlayCloseResult.processCouldNotBeVerified;
    }
    if (!beforeClose.matches(record)) {
      await _removeRecordIfMatches(record);
      return OverlayCloseResult.processIdentityChanged;
    }
    if (!beforeClose.isRunning) {
      await _removeRecordIfMatches(record);
      return OverlayCloseResult.stoppedGracefully;
    }

    await _requestExit(record);
    final gracefulExit = await _waitForExit(record, gracefulTimeout);
    if (gracefulExit == _ExitState.stopped) {
      await _removeRecordIfMatches(record);
      return OverlayCloseResult.stoppedGracefully;
    }
    if (gracefulExit == _ExitState.identityChanged) {
      await _removeRecordIfMatches(record);
      return OverlayCloseResult.processIdentityChanged;
    }
    if (gracefulExit == _ExitState.unknown) {
      return OverlayCloseResult.processCouldNotBeVerified;
    }

    final beforeTerminate = await _inspectProcess(record.pid);
    if (beforeTerminate == null) {
      return OverlayCloseResult.processCouldNotBeVerified;
    }
    if (!beforeTerminate.matches(record)) {
      await _removeRecordIfMatches(record);
      return OverlayCloseResult.processIdentityChanged;
    }
    if (!beforeTerminate.isRunning) {
      await _removeRecordIfMatches(record);
      return OverlayCloseResult.stoppedGracefully;
    }

    await _terminateProcess(record);
    final forcedExit = await _waitForExit(record, forceExitTimeout);
    if (forcedExit == _ExitState.stopped ||
        forcedExit == _ExitState.identityChanged) {
      await _removeRecordIfMatches(record);
      return forcedExit == _ExitState.stopped
          ? OverlayCloseResult.stoppedAfterForceTermination
          : OverlayCloseResult.processIdentityChanged;
    }
    if (forcedExit == _ExitState.unknown) {
      return OverlayCloseResult.processCouldNotBeVerified;
    }
    final finalInspection = await _inspectProcess(record.pid);
    if (finalInspection != null &&
        (!finalInspection.isRunning || !finalInspection.matches(record))) {
      await _removeRecordIfMatches(record);
      return OverlayCloseResult.stoppedAfterForceTermination;
    }
    return OverlayCloseResult.processDidNotExit;
  }

  Future<_ExitState> _waitForExit(
    OverlayProcessRecord record,
    Duration timeout,
  ) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      await Future<void>.delayed(pollInterval);
      final inspection = await _inspectProcess(record.pid);
      if (inspection == null) return _ExitState.unknown;
      if (!inspection.matches(record)) return _ExitState.identityChanged;
      if (!inspection.isRunning) return _ExitState.stopped;
    }
    return _ExitState.stillRunning;
  }
}

enum _ExitState { stopped, identityChanged, unknown, stillRunning }

Future<OverlayProcessInspection?> inspectWindowsProcess(int processId) async {
  if (!Platform.isWindows || processId <= 0) return null;
  final opened = OpenProcess(
    PROCESS_ACCESS_RIGHTS(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE),
    false,
    processId,
  );
  final handle = opened.value;
  if (handle.address == 0) {
    if (opened.error == ERROR_INVALID_PARAMETER) {
      return const OverlayProcessInspection(
        isRunning: false,
        creationTime: 0,
        executablePath: '',
      );
    }
    logWarning(
      'OverlayLifecycleService',
      'OpenProcess failed for PID $processId '
          '(Win32 error ${opened.error}); process identity is unverified.',
    );
    return null;
  }

  final pathBuffer = calloc<Uint16>(1024);
  final pathLength = calloc<Uint32>()..value = 1024;
  final creationTime = calloc<FILETIME>();
  final exitTime = calloc<FILETIME>();
  final kernelTime = calloc<FILETIME>();
  final userTime = calloc<FILETIME>();
  try {
    final timesResult = GetProcessTimes(
      handle,
      creationTime,
      exitTime,
      kernelTime,
      userTime,
    );
    if (!timesResult.value) {
      logWarning(
        'OverlayLifecycleService',
        'Could not read creation time for PID $processId '
            '(Win32 error ${timesResult.error}).',
      );
      return null;
    }
    final creationTicks =
        (creationTime.ref.dwHighDateTime << 32) |
        creationTime.ref.dwLowDateTime;
    final waitResult = WaitForSingleObject(handle, 0).value;
    if (waitResult != WAIT_TIMEOUT && waitResult != WAIT_OBJECT_0) {
      return null;
    }
    if (waitResult == WAIT_OBJECT_0) {
      return OverlayProcessInspection(
        isRunning: false,
        creationTime: creationTicks,
        executablePath: '',
      );
    }
    final pathResult = QueryFullProcessImageName(
      handle,
      PROCESS_NAME_FORMAT(0),
      PWSTR(pathBuffer.cast<Utf16>()),
      pathLength,
    );
    if (!pathResult.value) {
      logWarning(
        'OverlayLifecycleService',
        'Executable path unavailable for running PID $processId '
            '(Win32 error ${pathResult.error}); ownership will be checked '
            'using the process creation time.',
      );
    }
    return OverlayProcessInspection(
      isRunning: true,
      creationTime: creationTicks,
      executablePath: pathResult.value
          ? pathBuffer.cast<Utf16>().toDartString()
          : null,
      executablePathAccessible: pathResult.value,
    );
  } finally {
    CloseHandle(handle);
    calloc
      ..free(pathBuffer)
      ..free(pathLength)
      ..free(creationTime)
      ..free(exitTime)
      ..free(kernelTime)
      ..free(userTime);
  }
}

Future<void> terminateWindowsProcess(OverlayProcessRecord record) async {
  if (!Platform.isWindows) {
    throw UnsupportedError('Overlay process termination requires Windows.');
  }
  final opened = OpenProcess(
    PROCESS_ACCESS_RIGHTS(
      PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | SYNCHRONIZE,
    ),
    false,
    record.pid,
  );
  final handle = opened.value;
  if (handle.address == 0) {
    throw StateError(
      'Could not open overlay process ${record.pid} for verified termination '
      '(Win32 error ${opened.error}).',
    );
  }

  final pathBuffer = calloc<Uint16>(1024);
  final pathLength = calloc<Uint32>()..value = 1024;
  final creationTime = calloc<FILETIME>();
  final exitTime = calloc<FILETIME>();
  final kernelTime = calloc<FILETIME>();
  final userTime = calloc<FILETIME>();
  try {
    final hasPath = QueryFullProcessImageName(
      handle,
      PROCESS_NAME_FORMAT(0),
      PWSTR(pathBuffer.cast<Utf16>()),
      pathLength,
    ).value;
    final hasTimes = GetProcessTimes(
      handle,
      creationTime,
      exitTime,
      kernelTime,
      userTime,
    ).value;
    if (!hasTimes) {
      throw StateError(
        'Could not verify overlay process creation time ${record.pid} '
        'before termination.',
      );
    }
    final actual = OverlayProcessRecord(
      pid: record.pid,
      creationTime:
          (creationTime.ref.dwHighDateTime << 32) |
          creationTime.ref.dwLowDateTime,
      executablePath: hasPath ? pathBuffer.cast<Utf16>().toDartString() : null,
    );
    if (!actual.matches(record)) {
      throw StateError(
        'Overlay process identity changed before termination; refusing '
        'to terminate PID ${record.pid}.',
      );
    }
    if (WaitForSingleObject(handle, 0).value == WAIT_OBJECT_0) return;
    final result = TerminateProcess(handle, 1);
    if (!result.value) {
      throw StateError(
        'Windows rejected termination of verified overlay PID ${record.pid} '
        '(Win32 error ${result.error}).',
      );
    }
  } finally {
    CloseHandle(handle);
    calloc
      ..free(pathBuffer)
      ..free(pathLength)
      ..free(creationTime)
      ..free(exitTime)
      ..free(kernelTime)
      ..free(userTime);
  }
}

Future<OverlayProcessRecord> currentWindowsProcessRecord() async {
  final inspection = await inspectWindowsProcess(pid);
  if (inspection == null || !inspection.isRunning) {
    throw StateError(
      'Could not verify the current WallSync process creation time.',
    );
  }
  return OverlayProcessRecord(
    pid: pid,
    creationTime: inspection.creationTime,
    executablePath: inspection.executablePath,
  );
}

String? _normalizePath(String? path) =>
    path?.replaceAll('/', '\\').toLowerCase();
