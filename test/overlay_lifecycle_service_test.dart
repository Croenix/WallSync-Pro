import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/models/taskbar_settings.dart';
import 'package:wall_sync/services/overlay_lifecycle_service.dart';
import 'package:wall_sync/services/overlay_startup_service.dart';

const record = OverlayProcessRecord(
  pid: 1234,
  creationTime: 987654,
  executablePath: r'C:\WallSync\wallsync.exe',
);

void main() {
  test('coalesces duplicate overlay launch requests', () async {
    final gate = OverlayLaunchGate();
    final launchCompleter = Completer<void>();
    var launchCount = 0;
    Future<void> launch() {
      launchCount++;
      return launchCompleter.future;
    }

    final first = gate.run(launch);
    final second = gate.run(launch);
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(launchCount, 1);
    launchCompleter.complete();
    await Future.wait([first, second]);
  });

  test(
    'failed overlay launch can be retried after the gate releases',
    () async {
      final gate = OverlayLaunchGate();
      var attempts = 0;

      await expectLater(
        gate.run(() async {
          attempts++;
          throw StateError('launch failed');
        }),
        throwsStateError,
      );
      await gate.run(() async {
        attempts++;
      });

      expect(attempts, 2);
    },
  );

  test('overlay recovery retries are increasing, bounded, and resettable', () {
    final policy = OverlayRecoveryPolicy();

    expect(policy.nextDelay(), const Duration(seconds: 1));
    expect(policy.nextDelay(), const Duration(seconds: 3));
    expect(policy.nextDelay(), const Duration(seconds: 8));
    expect(policy.nextDelay(), isNull);
    expect(policy.attempts, 3);

    policy.reset();
    expect(policy.attempts, 0);
    expect(policy.nextDelay(), const Duration(seconds: 1));
  });

  test('overlay visibility retries stop at the configured bound', () async {
    var checks = 0;
    final retries = <int>[];
    final visible = await waitForOverlayWindowVisibility(
      isVisible: () async {
        checks++;
        return false;
      },
      retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
      onRetry: (attempt, _) => retries.add(attempt),
    );

    expect(visible, isFalse);
    expect(checks, 4);
    expect(retries, [1, 2, 3]);
    expect(
      overlayWindowVisibilityRetryDelays
          .map((delay) => delay.inMilliseconds)
          .toList(),
      [200, 400, 800, 1600, 3200, 6400, 8000, 12000],
    );
  });

  test('restores an off-screen saved position to the nearest display', () {
    final result = clampOverlayPositionToDisplays(
      requested: const Offset(-1500, 900),
      windowSize: const Size(400, 250),
      displayBounds: const [
        Rect.fromLTWH(0, 0, 1920, 1080),
        Rect.fromLTWH(1920, 0, 1280, 1024),
      ],
    );

    expect(result, const Offset(0, 830));
  });

  test('preserves a valid saved position on a secondary display', () {
    const position = Offset(2100, 100);
    expect(
      clampOverlayPositionToDisplays(
        requested: position,
        windowSize: const Size(400, 250),
        displayBounds: const [
          Rect.fromLTWH(0, 0, 1920, 1080),
          Rect.fromLTWH(1920, 0, 1280, 1024),
        ],
      ),
      position,
    );
  });

  test(
    'startup Run entry is idempotent and uses the installed executable',
    () async {
      String? runValue;
      var addCount = 0;
      final service = OverlayStartupService(
        logInfo: (_, _) {},
        logWarning: (_, _) {},
        executablePath: r'C:\Program Files\WallSync\WallSync.exe',
        isWindows: true,
        executableExists: (_) async => true,
        packageStartupSync: (_) async => 'unpackaged',
        runCommand: (executable, arguments) async {
          if (executable == 'reg' && arguments.first == 'query') {
            return ProcessResult(
              0,
              0,
              'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
                  '${runValue == null ? '' : '\n    WallSync    REG_SZ    $runValue'}',
              '',
            );
          }
          if (executable == 'reg' && arguments.first == 'add') {
            addCount++;
            runValue = arguments[7];
            return ProcessResult(
              0,
              0,
              'The operation completed successfully.',
              '',
            );
          }
          if (executable == 'schtasks' && arguments.first == '/delete') {
            return ProcessResult(
              0,
              1,
              'ERROR: The system cannot find the file specified.',
              '',
            );
          }
          if (executable == 'schtasks' && arguments.first == '/query') {
            return ProcessResult(
              0,
              1,
              'ERROR: The system cannot find the file specified.',
              '',
            );
          }
          throw StateError('Unexpected command: $executable $arguments');
        },
      );

      await service.sync(true);
      await service.sync(true);

      expect(
        runValue,
        '"C:\\Program Files\\WallSync\\WallSync.exe" '
        '--startup-trigger=windows-logon',
      );
      expect(addCount, 1);
    },
  );

  test('startup registration creates a missing current-user Run key', () async {
    String? runValue;
    var addCount = 0;
    final service = OverlayStartupService(
      logInfo: (_, _) {},
      logWarning: (_, _) {},
      executablePath: r'C:\Program Files\WallSync\WallSync.exe',
      isWindows: true,
      executableExists: (_) async => true,
      packageStartupSync: (_) async => 'unpackaged',
      runCommand: (executable, arguments) async {
        if (executable == 'reg' && arguments.first == 'query') {
          if (runValue == null) {
            return ProcessResult(
              0,
              1,
              '',
              'ERROR: The system was unable to find the specified registry key or value.',
            );
          }
          return ProcessResult(
            0,
            0,
            'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
                '\n    WallSync    REG_SZ    $runValue',
            '',
          );
        }
        if (executable == 'reg' && arguments.first == 'add') {
          addCount++;
          runValue = arguments[7];
          return ProcessResult(
            0,
            0,
            'The operation completed successfully.',
            '',
          );
        }
        if (executable == 'schtasks' && arguments.first == '/delete') {
          return ProcessResult(
            0,
            1,
            'ERROR: The system cannot find the file specified.',
            '',
          );
        }
        if (executable == 'schtasks' && arguments.first == '/query') {
          return ProcessResult(
            0,
            1,
            'ERROR: The system cannot find the file specified.',
            '',
          );
        }
        throw StateError('Unexpected command: $executable $arguments');
      },
    );

    await service.sync(true);

    expect(addCount, 1);
    expect(
      runValue,
      '"C:\\Program Files\\WallSync\\WallSync.exe" '
      '--startup-trigger=windows-logon',
    );
  });

  test(
    'disabling startup removes and verifies the current-user Run entry',
    () async {
      String? runValue =
          '"C:\\WallSync\\WallSync.exe" --startup-trigger=windows-logon';
      var deleteCount = 0;
      final service = OverlayStartupService(
        logInfo: (_, _) {},
        logWarning: (_, _) {},
        executablePath: r'C:\WallSync\WallSync.exe',
        isWindows: true,
        executableExists: (_) async => true,
        packageStartupSync: (_) async => 'unpackaged',
        runCommand: (executable, arguments) async {
          if (executable == 'reg' && arguments.first == 'query') {
            return ProcessResult(
              0,
              0,
              'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
                  '${runValue == null ? '' : '\n    WallSync    REG_SZ    $runValue'}',
              '',
            );
          }
          if (executable == 'reg' && arguments.first == 'delete') {
            deleteCount++;
            runValue = null;
            return ProcessResult(
              0,
              0,
              'The operation completed successfully.',
              '',
            );
          }
          if (executable == 'schtasks' && arguments.first == '/delete') {
            return ProcessResult(
              0,
              1,
              'ERROR: The system cannot find the file specified.',
              '',
            );
          }
          if (executable == 'schtasks' && arguments.first == '/query') {
            return ProcessResult(
              0,
              1,
              'ERROR: The system cannot find the file specified.',
              '',
            );
          }
          throw StateError('Unexpected command: $executable $arguments');
        },
      );

      await service.sync(false);

      expect(runValue, isNull);
      expect(deleteCount, 1);
    },
  );

  test('packaged startup respects a Windows Startup apps opt-out', () async {
    var packageSyncCount = 0;
    var registryWrites = 0;
    final service = OverlayStartupService(
      logInfo: (_, _) {},
      logWarning: (_, _) {},
      isWindows: true,
      packageStartupSync: (enabled) async {
        expect(enabled, isTrue);
        packageSyncCount++;
        return 'disabledByUser';
      },
      runCommand: (executable, arguments) async {
        if (executable == 'reg' && arguments.first == 'query') {
          return ProcessResult(
            0,
            0,
            r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run',
            '',
          );
        }
        if (executable == 'reg' &&
            (arguments.first == 'add' || arguments.first == 'delete')) {
          registryWrites++;
          return ProcessResult(0, 0, '', '');
        }
        if (executable == 'schtasks' && arguments.first == '/delete') {
          return ProcessResult(
            0,
            1,
            'ERROR: The system cannot find the file specified.',
            '',
          );
        }
        if (executable == 'schtasks' && arguments.first == '/query') {
          return ProcessResult(
            0,
            1,
            'ERROR: The system cannot find the file specified.',
            '',
          );
        }
        throw StateError('Unexpected command: $executable $arguments');
      },
    );

    await service.sync(true);

    expect(packageSyncCount, 1);
    expect(registryWrites, 0);
  });

  test('waits for delayed overlay PID registration and readiness', () async {
    var reads = 0;
    final result = await waitForOverlayReadiness(
      readRecord: () async {
        reads++;
        if (reads == 1) return null;
        return OverlayProcessRecord(
          pid: record.pid,
          creationTime: record.creationTime,
          executablePath: record.executablePath,
          ready: reads >= 3,
        );
      },
      inspectProcess: (_) async => _inspection(true),
      timeout: const Duration(seconds: 1),
      pollInterval: Duration.zero,
    );

    expect(result.status, OverlayReadinessStatus.ready);
    expect(result.record?.ready, isTrue);
    expect(reads, 3);
  });

  test('readiness polling survives a transient PID lock error', () async {
    var reads = 0;
    final result = await waitForOverlayReadiness(
      readRecord: () async {
        reads++;
        if (reads == 1) {
          throw FileSystemException(
            'sharing violation',
            'overlay.pid',
            const OSError('sharing violation', 33),
          );
        }
        return record;
      },
      inspectProcess: (_) async => _inspection(true),
      expectedPid: record.pid,
      timeout: const Duration(seconds: 1),
      pollInterval: Duration.zero,
    );

    expect(result.status, OverlayReadinessStatus.ready);
    expect(reads, 2);
  });

  test(
    'does not accept a stale PID record with mismatched creation time',
    () async {
      final result = await waitForOverlayReadiness(
        readRecord: () async => record,
        inspectProcess: (_) async => OverlayProcessInspection(
          isRunning: true,
          creationTime: record.creationTime! + 1,
          executablePath: record.executablePath,
        ),
        timeout: Duration.zero,
        pollInterval: Duration.zero,
      );

      expect(result.status, OverlayReadinessStatus.identityMismatch);
      expect(result.isReady, isFalse);
    },
  );

  test(
    'readiness requires matching child mode, operation, revision and HWND',
    () async {
      final dockRecord = OverlayProcessRecord(
        pid: record.pid,
        creationTime: record.creationTime,
        executablePath: record.executablePath,
        ready: true,
        instanceId: 'widget_overlay',
        templateId: 'split',
        processMode: 'widget_overlay',
        operationId: 7,
        configurationRevision: 3,
        hwnd: 12345,
      );

      final rejected = await waitForOverlayReadiness(
        readRecord: () async => dockRecord,
        inspectProcess: (_) async => _inspection(true),
        expectedPid: record.pid,
        expectedInstanceId: 'widget_overlay',
        expectedTemplateId: 'classic',
        expectedProcessMode: 'widget_overlay',
        expectedOperationId: 8,
        expectedConfigurationRevision: 3,
        requireWindowHandle: true,
        timeout: Duration.zero,
        pollInterval: Duration.zero,
      );
      expect(rejected.status, OverlayReadinessStatus.identityMismatch);
      expect(rejected.isReady, isFalse);

      final accepted = await waitForOverlayReadiness(
        readRecord: () async => dockRecord,
        inspectProcess: (_) async => _inspection(true),
        expectedPid: record.pid,
        expectedInstanceId: 'widget_overlay',
        expectedTemplateId: 'split',
        expectedProcessMode: 'widget_overlay',
        expectedOperationId: 7,
        expectedConfigurationRevision: 3,
        requireWindowHandle: true,
        timeout: Duration.zero,
        pollInterval: Duration.zero,
      );
      expect(accepted.status, OverlayReadinessStatus.ready);
      expect(accepted.record?.hwnd, 12345);
    },
  );

  test('rejects a live PID with a different executable identity', () async {
    final result = await waitForOverlayReadiness(
      readRecord: () async => record,
      inspectProcess: (_) async => OverlayProcessInspection(
        isRunning: true,
        creationTime: record.creationTime!,
        executablePath: r'C:\Other\wallsync.exe',
      ),
      timeout: Duration.zero,
      pollInterval: Duration.zero,
    );

    expect(result.status, OverlayReadinessStatus.identityMismatch);
    expect(result.isReady, isFalse);
  });

  test('parses current and legacy overlay PID records', () {
    final parsed = OverlayProcessRecord.tryParse(
      '{"pid":1234,"creationTime":"987654",'
      '"executablePath":"C:\\\\WallSync\\\\wallsync.exe"}',
    );
    expect(parsed?.matches(record), isTrue);
    expect(parsed?.ready, isTrue);
    final starting = OverlayProcessRecord.tryParse(
      '{"pid":1234,"creationTime":987654,"executablePath":null,"ready":false}',
    );
    expect(starting?.ready, isFalse);
    expect(starting?.matches(record), isTrue);
    final legacy = OverlayProcessRecord.tryParse('1234');
    expect(legacy?.pid, 1234);
    expect(legacy?.creationTime, isNull);
    expect(
      OverlayProcessRecord.tryParse(
        '{"pid":0,"creationTime":0,"executablePath":""}',
      ),
      isNull,
    );
  });

  test(
    'graceful shutdown removes the record only after process exit',
    () async {
      var running = true;
      OverlayProcessRecord? storedRecord = record;
      final service = OverlayLifecycleService(
        readRecord: () async => storedRecord,
        inspectProcess: (_) async => _inspection(running),
        requestExit: (_) async {
          running = false;
        },
        terminateProcess: (_) async =>
            fail('Graceful exit should not terminate.'),
        removeRecordIfMatches: (expected) async {
          if (storedRecord?.matches(expected) ?? false) storedRecord = null;
        },
        pollInterval: Duration.zero,
      );

      expect(await service.close(), OverlayCloseResult.stoppedGracefully);
      expect(storedRecord, isNull);
    },
  );

  test(
    'creation time verifies ownership when executable path is inaccessible',
    () async {
      var running = true;
      OverlayProcessRecord? storedRecord = record;
      final service = OverlayLifecycleService(
        readRecord: () async => storedRecord,
        inspectProcess: (_) async => OverlayProcessInspection(
          isRunning: running,
          creationTime: record.creationTime!,
          executablePath: null,
          executablePathAccessible: false,
        ),
        requestExit: (_) async {
          running = false;
        },
        terminateProcess: (_) async =>
            fail('Graceful exit should not terminate.'),
        removeRecordIfMatches: (expected) async {
          if (storedRecord?.matches(expected) ?? false) storedRecord = null;
        },
        pollInterval: Duration.zero,
      );

      expect(await service.close(), OverlayCloseResult.stoppedGracefully);
      expect(storedRecord, isNull);
    },
  );

  test(
    'verified creation time permits force exit without executable path',
    () async {
      var running = true;
      var terminationCount = 0;
      OverlayProcessRecord? storedRecord = record;
      final service = OverlayLifecycleService(
        readRecord: () async => storedRecord,
        inspectProcess: (_) async => OverlayProcessInspection(
          isRunning: running,
          creationTime: record.creationTime!,
          executablePath: null,
          executablePathAccessible: false,
        ),
        requestExit: (_) async {},
        terminateProcess: (_) async {
          terminationCount++;
          running = false;
        },
        removeRecordIfMatches: (expected) async {
          if (storedRecord?.matches(expected) ?? false) storedRecord = null;
        },
        gracefulTimeout: Duration.zero,
        forceExitTimeout: const Duration(milliseconds: 20),
        pollInterval: const Duration(milliseconds: 1),
      );

      expect(
        await service.close(),
        OverlayCloseResult.stoppedAfterForceTermination,
      );
      expect(terminationCount, 1);
      expect(storedRecord, isNull);
    },
  );

  test(
    'cleans a verified exited process when Windows no longer exposes its path',
    () async {
      OverlayProcessRecord? storedRecord = record;
      final service = OverlayLifecycleService(
        readRecord: () async => storedRecord,
        inspectProcess: (_) async => OverlayProcessInspection(
          isRunning: false,
          creationTime: record.creationTime!,
          executablePath: '',
        ),
        requestExit: (_) async =>
            fail('An exited process needs no exit signal.'),
        terminateProcess: (_) async =>
            fail('An exited process must not be killed.'),
        removeRecordIfMatches: (expected) async {
          if (storedRecord?.matches(expected) ?? false) storedRecord = null;
        },
      );

      expect(await service.close(), OverlayCloseResult.stoppedGracefully);
      expect(storedRecord, isNull);
    },
  );

  test(
    'forces termination only after graceful timeout and confirms exit',
    () async {
      var running = true;
      var terminationCount = 0;
      OverlayProcessRecord? storedRecord = record;
      final service = OverlayLifecycleService(
        readRecord: () async => storedRecord,
        inspectProcess: (_) async => _inspection(running),
        requestExit: (_) async {},
        terminateProcess: (_) async {
          terminationCount++;
          running = false;
        },
        removeRecordIfMatches: (expected) async {
          if (storedRecord?.matches(expected) ?? false) storedRecord = null;
        },
        gracefulTimeout: const Duration(milliseconds: 1),
        forceExitTimeout: const Duration(milliseconds: 20),
        pollInterval: const Duration(milliseconds: 1),
      );

      expect(
        await service.close(),
        OverlayCloseResult.stoppedAfterForceTermination,
      );
      expect(terminationCount, 1);
      expect(storedRecord, isNull);
    },
  );

  test(
    'does not terminate legacy PID records without process identity',
    () async {
      var terminationCount = 0;
      final service = OverlayLifecycleService(
        readRecord: () async => const OverlayProcessRecord(
          pid: 1234,
          creationTime: null,
          executablePath: null,
        ),
        inspectProcess: (_) async => _inspection(true),
        requestExit: (_) async {},
        terminateProcess: (_) async {
          terminationCount++;
        },
        removeRecordIfMatches: (_) async {},
      );

      expect(
        await service.close(),
        OverlayCloseResult.processCouldNotBeVerified,
      );
      expect(terminationCount, 0);
    },
  );

  test('coalesces duplicate close requests', () async {
    final exitRequested = Completer<void>();
    var requestCount = 0;
    var running = true;
    final service = OverlayLifecycleService(
      readRecord: () async => record,
      inspectProcess: (_) async => _inspection(running),
      requestExit: (_) async {
        requestCount++;
        await exitRequested.future;
        running = false;
      },
      terminateProcess: (_) async =>
          fail('Graceful exit should not terminate.'),
      removeRecordIfMatches: (_) async {},
      gracefulTimeout: const Duration(seconds: 1),
      pollInterval: const Duration(milliseconds: 1),
    );

    final first = service.close();
    final second = service.close();
    expect(requestCount, 0);
    await Future<void>.delayed(Duration.zero);
    expect(requestCount, 1);
    exitRequested.complete();

    expect(await first, OverlayCloseResult.stoppedGracefully);
    expect(await second, OverlayCloseResult.stoppedGracefully);
    expect(requestCount, 1);
  });

  test(
    'does not remove a PID record if the PID now belongs to another process',
    () async {
      var cleanupCount = 0;
      var terminationCount = 0;
      final service = OverlayLifecycleService(
        readRecord: () async => record,
        inspectProcess: (_) async => const OverlayProcessInspection(
          isRunning: true,
          creationTime: 1,
          executablePath: r'C:\Other\process.exe',
        ),
        requestExit: (_) async {},
        terminateProcess: (_) async => terminationCount++,
        removeRecordIfMatches: (_) async {
          cleanupCount++;
        },
      );

      expect(await service.close(), OverlayCloseResult.processIdentityChanged);
      expect(terminationCount, 0);
      expect(cleanupCount, 1);
    },
  );

  test('parses records with lifecycle states and precise timestamps', () {
    const json =
        '{"pid":1234,"creationTime":987654,'
        '"executablePath":"C:\\\\WallSync\\\\wallsync.exe","ready":true,'
        '"state":"ready","entryPointMs":1000,"settingsLoadedMs":1050,'
        '"windowInitMs":1200,"firstFrameMs":1300,"readyPublishedMs":1350,'
        '"acknowledgedMs":1400}';
    final parsed = OverlayProcessRecord.tryParse(json);
    expect(parsed, isNotNull);
    expect(parsed!.pid, 1234);
    expect(parsed.state, OverlayLifecycleState.ready);
    expect(parsed.entryPointMs, 1000);
    expect(parsed.settingsLoadedMs, 1050);
    expect(parsed.windowInitMs, 1200);
    expect(parsed.firstFrameMs, 1300);
    expect(parsed.readyPublishedMs, 1350);
    expect(parsed.acknowledgedMs, 1400);

    final updated = parsed.copyWith(
      state: OverlayLifecycleState.stopping,
      templateId: 'split',
      failureReason: 'user requested stop',
    );
    expect(updated.state, OverlayLifecycleState.stopping);
    expect(updated.templateId, 'split');
    expect(updated.failureReason, 'user requested stop');
    expect(updated.entryPointMs, 1000);
  });

  test('tracks each native widget presentation stage before ready', () {
    const presentationStages = [
      OverlayLifecycleState.processStarted,
      OverlayLifecycleState.engineInitialized,
      OverlayLifecycleState.hwndCreated,
      OverlayLifecycleState.firstFrameRendered,
      OverlayLifecycleState.windowConfigured,
      OverlayLifecycleState.windowShown,
      OverlayLifecycleState.presentationVerified,
    ];

    expect(presentationStages.map((state) => state.name), [
      'processStarted',
      'engineInitialized',
      'hwndCreated',
      'firstFrameRendered',
      'windowConfigured',
      'windowShown',
      'presentationVerified',
    ]);
    for (final state in presentationStages) {
      final record = const OverlayProcessRecord(
        pid: 1234,
        creationTime: 987654,
        executablePath: 'C:\\WallSync\\wallsync.exe',
        ready: false,
        state: OverlayLifecycleState.processStarted,
      ).copyWith(state: state);
      expect(record.ready, isFalse);
      expect(record.state, state);
    }
  });

  test('PID file reads retry a temporary Windows sharing violation', () async {
    final directory = await Directory.systemTemp.createTemp(
      'wallsync-pid-read-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final pidFile = File('${directory.path}\\overlay.pid');
    await pidFile.writeAsString('{"pid":1234}');
    var reads = 0;

    final contents = await readOverlayPidFileContents(
      pidFile,
      readContents: () async {
        reads++;
        if (reads == 1) {
          throw FileSystemException(
            'sharing violation',
            pidFile.path,
            const OSError('sharing violation', 32),
          );
        }
        return pidFile.readAsString();
      },
      retryDelay: (_) => Duration.zero,
    );

    expect(contents, '{"pid":1234}');
    expect(reads, 2);
  });

  test('PID file reads are serialized within the process', () async {
    final directory = await Directory.systemTemp.createTemp(
      'wallsync-pid-read-concurrency-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final pidFile = File('${directory.path}\\overlay.pid');
    await pidFile.writeAsString('{"pid":1234}');
    var activeReads = 0;
    var maximumActiveReads = 0;

    Future<String> readContents() async {
      activeReads++;
      if (activeReads > maximumActiveReads) {
        maximumActiveReads = activeReads;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
      activeReads--;
      return pidFile.readAsString();
    }

    await Future.wait(
      List.generate(
        4,
        (_) => readOverlayPidFileContents(pidFile, readContents: readContents),
      ),
    );

    expect(maximumActiveReads, 1);
  });

  test(
    'PID lock retries do not unlock a lock that was never acquired',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'wallsync-pid-lock-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final pidFile = File('${directory.path}\\overlay.pid');
      await pidFile.writeAsString('{"pid":1234}');
      var lockAttempts = 0;

      final contents = await readOverlayPidFileContents(
        pidFile,
        acquireSharedLock: (file) async {
          lockAttempts++;
          if (lockAttempts == 1) {
            throw FileSystemException(
              'sharing violation',
              pidFile.path,
              const OSError('sharing violation', 33),
            );
          }
          await file.lock(FileLock.shared);
        },
        retryDelay: (_) => Duration.zero,
      );

      expect(contents, '{"pid":1234}');
      expect(lockAttempts, 2);
    },
  );

  test(
    'waitForOverlayReadiness reports failed status when overlay initialization fails',
    () async {
      final failedRecord = OverlayProcessRecord(
        pid: record.pid,
        creationTime: record.creationTime,
        executablePath: record.executablePath,
        ready: false,
        state: OverlayLifecycleState.failedOrTimedOut,
        failureReason: 'Window setup failed',
      );

      final result = await waitForOverlayReadiness(
        readRecord: () async => failedRecord,
        inspectProcess: (_) async => _inspection(true),
        timeout: const Duration(seconds: 1),
        pollInterval: Duration.zero,
      );

      expect(result.status, OverlayReadinessStatus.failed);
      expect(result.isReady, isFalse);
      expect(result.record?.failureReason, 'Window setup failed');
    },
  );

  test(
    'waitForOverlayReadiness succeeds via final reconciliation check at timeout boundary',
    () async {
      var checkCount = 0;
      final result = await waitForOverlayReadiness(
        readRecord: () async {
          checkCount++;
          // First check returns starting, final boundary check returns ready
          return OverlayProcessRecord(
            pid: record.pid,
            creationTime: record.creationTime,
            executablePath: record.executablePath,
            ready: checkCount > 1,
            state: checkCount > 1
                ? OverlayLifecycleState.ready
                : OverlayLifecycleState.processStarted,
          );
        },
        inspectProcess: (_) async => _inspection(true),
        timeout:
            Duration.zero, // Forces immediate timeout to test boundary check
        pollInterval: const Duration(milliseconds: 10),
      );

      expect(result.status, OverlayReadinessStatus.ready);
      expect(result.isReady, isTrue);
    },
  );

  test(
    'does not reconcile ready when lifecycle state and stage disagree',
    () async {
      final result = await waitForOverlayReadiness(
        readRecord: () async => const OverlayProcessRecord(
          pid: 1234,
          creationTime: 987654,
          executablePath: r'C:\WallSync\wallsync.exe',
          ready: true,
          state: OverlayLifecycleState.ready,
          stage: DockReadinessStage.windowInteractive,
        ),
        inspectProcess: (_) async => _inspection(true),
        timeout: Duration.zero,
      );

      expect(result.isReady, isFalse);
    },
  );

  test(
    'per-widget recovery policies operate independently without cross-exhaustion',
    () {
      final policyA = OverlayRecoveryPolicy();
      final policyB = OverlayRecoveryPolicy();

      // Policy A attempts fail and increment
      expect(policyA.nextDelay(), const Duration(seconds: 1));
      expect(policyA.nextDelay(), const Duration(seconds: 3));
      expect(policyA.attempts, 2);

      // Policy B should be completely fresh and unaffected by Policy A
      expect(policyB.attempts, 0);
      expect(policyB.nextDelay(), const Duration(seconds: 1));
      expect(policyB.attempts, 1);

      // Resetting Policy A does not change Policy B
      policyA.reset();
      expect(policyA.attempts, 0);
      expect(policyB.attempts, 1);
    },
  );
}

OverlayProcessInspection _inspection(bool running) => OverlayProcessInspection(
  isRunning: running,
  creationTime: record.creationTime!,
  executablePath: record.executablePath!,
);
