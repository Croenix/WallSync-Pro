import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:wall_sync/services/live_wallpaper_manager.dart';
import 'package:wall_sync/services/settings_service.dart';
import 'package:wall_sync/services/wallpaper_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup polling returns only after a decoded-frame result', () async {
    var polls = 0;
    final result = await LiveWallpaperManager.pollStartupForTesting(
      initialResult: const {'pending': true},
      poll: () async {
        polls++;
        return polls == 1
            ? <String, dynamic>{'pending': true}
            : <String, dynamic>{
                'success': true,
                'frameDecoded': true,
                'windowAttached': true,
                'windowVisible': true,
                'windowWidth': 1920,
                'windowHeight': 1080,
              };
      },
      isCancelled: () => false,
      initialInterval: Duration.zero,
    );

    expect(polls, 2);
    expect(result?['success'], isTrue);
    expect(result?['frameDecoded'], isTrue);
  });

  test('startup readiness requires a decoded frame and an attached window', () {
    const ready = <String, dynamic>{
      'success': true,
      'frameDecoded': true,
      'windowAttached': true,
      'windowVisible': true,
      'width': 1920,
      'height': 1080,
    };

    expect(LiveWallpaperManager.startupResultIsReadyForTesting(ready), isTrue);
    expect(
      LiveWallpaperManager.startupResultIsReadyForTesting({
        ...ready,
        'frameDecoded': false,
      }),
      isFalse,
    );
    expect(
      LiveWallpaperManager.startupResultIsReadyForTesting({
        ...ready,
        'windowAttached': false,
      }),
      isFalse,
    );
    expect(
      LiveWallpaperManager.startupResultIsReadyForTesting({
        ...ready,
        'windowVisible': false,
      }),
      isFalse,
    );
    expect(
      LiveWallpaperManager.startupResultIsReadyForTesting({
        ...ready,
        'windowWidth': 0,
      }),
      isFalse,
    );
  });

  test(
    'startup readiness accepts legacy window dimensions during migration',
    () {
      const legacy = <String, dynamic>{
        'success': true,
        'frameDecoded': true,
        'windowAttached': true,
        'windowVisible': true,
        'width': 1920,
        'height': 1080,
      };

      expect(
        LiveWallpaperManager.startupResultIsReadyForTesting(legacy),
        isTrue,
      );
    },
  );

  test(
    'startup polling stops before another native poll when cancelled',
    () async {
      var polls = 0;
      final result = await LiveWallpaperManager.pollStartupForTesting(
        initialResult: const {'pending': true},
        poll: () async {
          polls++;
          return const {'pending': true};
        },
        isCancelled: () => true,
        initialInterval: Duration.zero,
      );

      expect(result, isNull);
      expect(polls, 0);
    },
  );

  test(
    'wallpaper lifecycle markers do not collide with the overlay marker',
    () async {
      final overlayMarker = await SettingsService().pidFile;
      final engine = WallpaperEngine();
      final wallpaperMarker = await engine.wallpaperPidFile;
      final readyMarker = await engine.wallpaperReadyFile;

      expect(wallpaperMarker.path, isNot(overlayMarker.path));
      expect(readyMarker.path, isNot(wallpaperMarker.path));
      expect(wallpaperMarker.path, endsWith('wallpaper.pid'));
      expect(readyMarker.path, endsWith('wallpaper.ready'));
    },
  );

  test('static wallpaper success requires verified final path state', () {
    expect(
      WallpaperEngine.wallpaperStateConfirmedForTesting(
        setCallSucceeded: true,
        stateQuerySucceeded: true,
        activePath: r'C:\Wallpapers\sample.jpg',
        requestedPath: r'c:/wallpapers/sample.jpg',
      ),
      isTrue,
    );
    expect(
      WallpaperEngine.wallpaperStateConfirmedForTesting(
        setCallSucceeded: true,
        stateQuerySucceeded: false,
        activePath: r'C:\Wallpapers\sample.jpg',
        requestedPath: r'C:\Wallpapers\sample.jpg',
      ),
      isFalse,
    );
    expect(
      WallpaperEngine.wallpaperStateConfirmedForTesting(
        setCallSucceeded: true,
        stateQuerySucceeded: true,
        activePath: r'C:\Wallpapers\previous.jpg',
        requestedPath: r'C:\Wallpapers\sample.jpg',
      ),
      isFalse,
    );
  });

  test('worker dispatch/return overhead estimate does not go negative', () {
    expect(
      WallpaperEngine.estimateWorkerDispatchAndReturnMs(
        roundTripMs: 5000,
        workerMs: 3800,
      ),
      1200,
    );
    expect(
      WallpaperEngine.estimateWorkerDispatchAndReturnMs(
        roundTripMs: 2000,
        workerMs: 2500,
      ),
      0,
    );
  });

  test(
    'delayed COM verification avoids SPI only after confirmed path state',
    () {
      expect(
        WallpaperEngine.shouldUseSystemParametersFallback(
          immediateComVerified: true,
          delayedComVerified: false,
        ),
        isFalse,
      );
      expect(
        WallpaperEngine.shouldUseSystemParametersFallback(
          immediateComVerified: false,
          delayedComVerified: true,
        ),
        isFalse,
      );
      expect(
        WallpaperEngine.shouldUseSystemParametersFallback(
          immediateComVerified: false,
          delayedComVerified: false,
        ),
        isTrue,
      );
    },
  );

  test('MPV start requires ready window and stop confirmation', () async {
    if (!Platform.isWindows) return;
    final manager = LiveWallpaperManager();
    var confirmStop = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LiveWallpaperManager.channel, (call) async {
          switch (call.method) {
            case 'startMpv':
              return const {
                'success': true,
                'frameDecoded': true,
                'windowAttached': true,
                'windowVisible': true,
                'width': 1920,
                'height': 1080,
                'pid': 12345,
              };
            case 'getPlaybackPolicy':
              return const {'fullscreen': false, 'batterySaver': false};
            case 'stopMpv':
              return confirmStop;
            default:
              throw MissingPluginException('Unexpected method ${call.method}');
          }
        });
    try {
      await manager.start(
        WidgetSettings(
          activeWallpaperType: 'video',
          activeWallpaperPath: r'C:\wallpapers\test.mp4',
        ),
      );
      expect(manager.mpvPid, 12345);
      expect(manager.currentPath, r'C:\wallpapers\test.mp4');

      await expectLater(manager.stop(), throwsStateError);
      expect(manager.currentPath, r'C:\wallpapers\test.mp4');

      confirmStop = true;
      await manager.stop();
      expect(manager.mpvPid, isNull);
      expect(manager.currentPath, isEmpty);
    } finally {
      manager.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LiveWallpaperManager.channel, null);
    }
  });

  test(
    'cancelled MPV startup stops before polling or publishing readiness',
    () async {
      if (!Platform.isWindows) return;
      final manager = LiveWallpaperManager();
      var cancelled = false;
      var polls = 0;
      var stopped = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LiveWallpaperManager.channel, (call) async {
            switch (call.method) {
              case 'startMpv':
                cancelled = true;
                return const {'pending': true, 'pid': 12345};
              case 'pollMpvStart':
                polls++;
                return const {'pending': true};
              case 'stopMpv':
                stopped = true;
                return true;
              default:
                throw MissingPluginException(
                  'Unexpected method ${call.method}',
                );
            }
          });
      try {
        await expectLater(
          manager.start(
            WidgetSettings(
              activeWallpaperType: 'video',
              activeWallpaperPath: r'C:\wallpapers\test.mp4',
            ),
            isCancelled: () => cancelled,
          ),
          throwsStateError,
        );
        expect(polls, 0);
        expect(stopped, isTrue);
        expect(manager.currentPath, isEmpty);
        expect(manager.mpvPid, isNull);
      } finally {
        manager.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LiveWallpaperManager.channel, null);
      }
    },
  );

  test('static wallpaper matches DOS device prefix and trailing slashes', () {
    expect(
      WallpaperEngine.wallpaperStateConfirmedForTesting(
        setCallSucceeded: true,
        stateQuerySucceeded: true,
        activePath: r'\\?\C:\Wallpapers\sample.jpg\',
        requestedPath: r'c:/wallpapers/sample.jpg',
      ),
      isTrue,
    );
  });

  test('static wallpaper matches environment variable expansion', () {
    final tempDir = Directory.systemTemp.path;
    expect(
      WallpaperEngine.wallpaperStateConfirmedForTesting(
        setCallSucceeded: true,
        stateQuerySucceeded: true,
        activePath: '$tempDir\\sample.jpg',
        requestedPath: '%TEMP%/sample.jpg',
      ),
      isTrue,
    );
  });

  test('static wallpaper rejects genuinely different image files', () {
    expect(
      WallpaperEngine.wallpaperStateConfirmedForTesting(
        setCallSucceeded: true,
        stateQuerySucceeded: true,
        activePath: r'C:\Wallpapers\landscape.jpg',
        requestedPath: r'C:\Wallpapers\portrait.jpg',
      ),
      isFalse,
    );
  });

  test('MPV stop is idempotent and safe against concurrent calls', () async {
    if (!Platform.isWindows) return;
    final manager = LiveWallpaperManager();
    var stopCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LiveWallpaperManager.channel, (call) async {
          switch (call.method) {
            case 'startMpv':
              return const {
                'success': true,
                'frameDecoded': true,
                'windowAttached': true,
                'windowVisible': true,
                'width': 1920,
                'height': 1080,
                'pid': 99999,
              };
            case 'getPlaybackPolicy':
              return const {'fullscreen': false, 'batterySaver': false};
            case 'stopMpv':
              stopCount++;
              await Future.delayed(const Duration(milliseconds: 50));
              return true;
            default:
              throw MissingPluginException('Unexpected method ${call.method}');
          }
        });
    try {
      await manager.start(
        WidgetSettings(
          activeWallpaperType: 'video',
          activeWallpaperPath: r'C:\wallpapers\test.mp4',
        ),
      );
      expect(manager.mpvPid, 99999);

      // Concurrent stops: both should complete cleanly with only 1 native call
      final futures = [manager.stop(), manager.stop()];
      await Future.wait(futures);
      expect(stopCount, 1);
      expect(manager.mpvPid, isNull);

      // Subsequent call when already stopped: idempotent no-op
      await manager.stop();
      expect(stopCount, 1);
    } finally {
      manager.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LiveWallpaperManager.channel, null);
    }
  });

  test(
    'two identical video requests arriving during startup reuse in-flight operation',
    () async {
      if (!Platform.isWindows) return;
      final manager = LiveWallpaperManager();
      var startCallCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LiveWallpaperManager.channel, (call) async {
            switch (call.method) {
              case 'startMpv':
                startCallCount++;
                await Future.delayed(const Duration(milliseconds: 30));
                return const {
                  'success': true,
                  'frameDecoded': true,
                  'windowAttached': true,
                  'windowVisible': true,
                  'width': 1920,
                  'height': 1080,
                  'pid': 12345,
                };
              case 'getPlaybackPolicy':
                return const {'fullscreen': false, 'batterySaver': false};
              case 'stopMpv':
                return true;
              default:
                throw MissingPluginException(
                  'Unexpected method ${call.method}',
                );
            }
          });
      try {
        final settings = WidgetSettings(
          activeWallpaperType: 'video',
          activeWallpaperPath: r'C:\wallpapers\duplicate_test.mp4',
        );

        // Launch two identical requests almost simultaneously
        final future1 = manager.start(settings);
        final future2 = manager.start(settings);

        await Future.wait([future1, future2]);

        // Only 1 native start call should have occurred
        expect(startCallCount, 1);
        expect(manager.mpvPid, 12345);
      } finally {
        manager.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LiveWallpaperManager.channel, null);
      }
    },
  );

  test(
    'different target supersedes in-flight startup safely without corrupting newer process',
    () async {
      if (!Platform.isWindows) return;
      final manager = LiveWallpaperManager();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(LiveWallpaperManager.channel, (call) async {
            switch (call.method) {
              case 'startMpv':
                final path = (call.arguments as Map)['path'] as String?;
                final pid = path?.contains('videoB') == true ? 20002 : 10001;
                return {'pending': true, 'pid': pid};
              case 'pollMpvStart':
                await Future.delayed(const Duration(milliseconds: 20));
                return const {
                  'success': true,
                  'frameDecoded': true,
                  'windowAttached': true,
                  'windowVisible': true,
                  'width': 1920,
                  'height': 1080,
                  'pid': 20002,
                };
              case 'getPlaybackPolicy':
                return const {'fullscreen': false, 'batterySaver': false};
              case 'stopMpv':
                return true;
              default:
                throw MissingPluginException(
                  'Unexpected method ${call.method}',
                );
            }
          });
      try {
        await manager.stop();
        final settingsA = WidgetSettings(
          activeWallpaperType: 'video',
          activeWallpaperPath: r'C:\wallpapers\videoA.mp4',
        );
        final settingsB = WidgetSettings(
          activeWallpaperType: 'video',
          activeWallpaperPath: r'C:\wallpapers\videoB.mp4',
        );

        // Start A, then immediately supersede with B
        final futureA = manager.start(settingsA);
        await Future.delayed(const Duration(milliseconds: 5));
        final futureB = manager.start(settingsB);

        // Future A should fail with MpvStartupCancelledException
        await expectLater(
          futureA,
          throwsA(isA<MpvStartupCancelledException>()),
        );

        // Future B should succeed
        await futureB;
        expect(manager.mpvPid, 20002);
        expect(manager.currentPath, r'C:\wallpapers\videoB.mp4');
      } finally {
        manager.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LiveWallpaperManager.channel, null);
      }
    },
  );

  test('cancellation immediately before and after window attachment', () async {
    // 1. Before window attached
    var cancelledBeforeAttach = true;
    final res1 = await LiveWallpaperManager.pollStartupForTesting(
      initialResult: const {'pending': true, 'windowAttached': false},
      poll: () async => const {'pending': true, 'windowAttached': false},
      isCancelled: () => cancelledBeforeAttach,
      initialInterval: Duration.zero,
    );
    expect(res1, isNull);

    // 2. After window attached, but before first frame decode
    var pollCount = 0;
    var cancelAfterAttach = false;
    final res2 = await LiveWallpaperManager.pollStartupForTesting(
      initialResult: const {'pending': true, 'windowAttached': false},
      poll: () async {
        pollCount++;
        cancelAfterAttach = true;
        return const {
          'pending': true,
          'windowAttached': true,
          'frameDecoded': false,
        };
      },
      isCancelled: () => cancelAfterAttach,
      initialInterval: Duration.zero,
    );
    expect(res2, isNull);
    expect(pollCount, 1);
  });

  test('startup timeout followed by a successful retry', () async {
    var attempts = 0;
    Future<Map<String, dynamic>?> runStartupAttempt() {
      attempts++;
      return LiveWallpaperManager.pollStartupForTesting(
        initialResult: const {'pending': true},
        poll: () async {
          if (attempts == 1) {
            // First attempt times out
            return const {'pending': true};
          } else {
            // Second attempt succeeds immediately
            return const {
              'success': true,
              'windowAttached': true,
              'windowVisible': true,
              'frameDecoded': true,
              'width': 1920,
              'height': 1080,
              'pid': 54321,
            };
          }
        },
        timeout: const Duration(milliseconds: 30),
        initialInterval: const Duration(milliseconds: 10),
        isCancelled: () => false,
      );
    }

    final attempt1 = await runStartupAttempt();
    expect(attempt1?['pending'], isTrue);
    expect(
      LiveWallpaperManager.startupResultIsReadyForTesting(attempt1),
      isFalse,
    );

    final attempt2 = await runStartupAttempt();
    expect(
      LiveWallpaperManager.startupResultIsReadyForTesting(attempt2),
      isTrue,
    );
    expect(attempt2?['pid'], 54321);
  });

  test(
    'cached static wallpaper completes successfully without unnecessary delayed polling',
    () {
      // Immediate verification succeeds when activePath matches requestedPath
      final immediateConfirmed = WallpaperEngine.wallpaperStateConfirmedForTesting(
        setCallSucceeded: true,
        stateQuerySucceeded: true,
        activePath:
            r'C:\Users\User\AppData\Local\WALLSYNC\cached_wallpapers\wallpaper1.jpg',
        requestedPath:
            r'C:\Users\User\AppData\Local\WALLSYNC\cached_wallpapers\wallpaper1.jpg',
      );
      expect(immediateConfirmed, isTrue);

      // Immediate verification also succeeds across canonical path differences (slashes, casing)
      final canonicalConfirmed = WallpaperEngine.wallpaperStateConfirmedForTesting(
        setCallSucceeded: true,
        stateQuerySucceeded: true,
        activePath:
            r'C:\USERS\USER\APPDATA\LOCAL\WALLSYNC\CACHED_WALLPAPERS\WALLPAPER1.JPG',
        requestedPath:
            r'c:/users/user/appdata/local/wallsync/cached_wallpapers/wallpaper1.jpg',
      );
      expect(canonicalConfirmed, isTrue);
    },
  );
}
