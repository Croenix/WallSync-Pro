import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';
import 'app_runtime_service.dart';
import 'settings_service.dart';
import 'live_wallpaper_manager.dart';

String _normalizeWallpaperPath(String p) {
  var s = p.trim().replaceAll('/', '\\');
  if (s.startsWith(r'\\?\') || s.startsWith(r'\??\')) {
    s = s.substring(4);
  }
  while (s.length > 3 && (s.endsWith('\\') || s.endsWith('/'))) {
    s = s.substring(0, s.length - 1);
  }
  return s.toLowerCase();
}

String _expandEnvironmentVariables(String path) {
  var result = path;
  if (result.contains('%')) {
    Platform.environment.forEach((key, value) {
      result = result.replaceAll('%$key%', value);
      result = result.replaceAll('%${key.toUpperCase()}%', value);
      result = result.replaceAll('%${key.toLowerCase()}%', value);
    });
  }
  return result;
}

bool _wallpaperPathsMatch(String activePath, String requestedPath) {
  if (activePath.isEmpty || requestedPath.isEmpty) return false;
  final expActive = _expandEnvironmentVariables(activePath);
  final expRequested = _expandEnvironmentVariables(requestedPath);
  final normActive = _normalizeWallpaperPath(expActive);
  final normRequested = _normalizeWallpaperPath(expRequested);
  if (normActive == normRequested) return true;

  try {
    final activeFile = File(expActive);
    final reqFile = File(expRequested);
    if (activeFile.existsSync() && reqFile.existsSync()) {
      return activeFile.resolveSymbolicLinksSync().toLowerCase() ==
          reqFile.resolveSymbolicLinksSync().toLowerCase();
    }
  } catch (_) {}

  return false;
}

Future<
  ({
    bool succeeded,
    int setMs,
    int setError,
    bool confirmed,
    int verifyMs,
    int workerMs,
    bool verifySucceeded,
    int verifyError,
    String activePath,
  })
>
_applyWallpaperWithSystemParametersInfo(String path) => Isolate.run(() {
  final workerStopwatch = Stopwatch()..start();
  final pathPointer = path.toNativeUtf16();
  try {
    final setStopwatch = Stopwatch()..start();
    final setResult = SystemParametersInfo(
      SPI_SETDESKWALLPAPER,
      0,
      pathPointer.cast(),
      SPIF_UPDATEINIFILE | SPIF_SENDCHANGE,
    );
    final setMs = setStopwatch.elapsedMilliseconds;
    if (!setResult.value) {
      return (
        succeeded: false,
        setMs: setMs,
        setError: setResult.error,
        confirmed: false,
        verifyMs: 0,
        workerMs: workerStopwatch.elapsedMilliseconds,
        verifySucceeded: false,
        verifyError: 0,
        activePath: '',
      );
    }

    final verifyStopwatch = Stopwatch()..start();
    final activePathBuffer = calloc<Uint16>(MAX_PATH);
    try {
      final verification = SystemParametersInfo(
        SPI_GETDESKWALLPAPER,
        MAX_PATH,
        activePathBuffer.cast(),
        SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
      );
      final activePath = verification.value
          ? activePathBuffer.cast<Utf16>().toDartString()
          : '';
      final confirmed = WallpaperEngine.wallpaperStateConfirmedForTesting(
        setCallSucceeded: setResult.value,
        stateQuerySucceeded: verification.value,
        activePath: activePath,
        requestedPath: path,
      );
      return (
        succeeded: true,
        setMs: setMs,
        setError: 0,
        confirmed: confirmed,
        verifyMs: verifyStopwatch.elapsedMilliseconds,
        workerMs: workerStopwatch.elapsedMilliseconds,
        verifySucceeded: verification.value,
        verifyError: verification.error,
        activePath: activePath,
      );
    } finally {
      calloc.free(activePathBuffer);
    }
  } finally {
    calloc.free(pathPointer);
  }
});

({
  bool succeeded,
  bool confirmed,
  int monitorCount,
  List<String> paths,
  String? error,
})
_readDesktopWallpaperState(String requestedPath) {
  final coInit = CoInitializeEx(COINIT_APARTMENTTHREADED);
  if (coInit < 0) {
    return (
      succeeded: false,
      confirmed: false,
      monitorCount: 0,
      paths: <String>[],
      error: 'CoInitializeEx failed: $coInit',
    );
  }
  try {
    return using((arena) {
      final clsid = IIDFromString(
        PCWSTR(
          '{C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD}'.toNativeUtf16(
            allocator: arena,
          ),
        ),
      );
      final wallpaper = CoCreateInstance<IDesktopWallpaper>(
        clsid,
        null,
        CLSCTX_ALL,
      );
      try {
        final monitorCount = wallpaper.getMonitorDevicePathCount();
        final paths = <String>[];
        var confirmed = monitorCount > 0;
        for (var i = 0; i < monitorCount; i++) {
          final monitor = wallpaper.getMonitorDevicePathAt(i);
          try {
            final activeWallpaper = wallpaper.getWallpaper(PCWSTR(monitor));
            try {
              final activePath = activeWallpaper.toDartString();
              paths.add(activePath);
              if (!_wallpaperPathsMatch(activePath, requestedPath)) {
                confirmed = false;
              }
            } finally {
              CoTaskMemFree(activeWallpaper);
            }
          } finally {
            CoTaskMemFree(monitor);
          }
        }
        return (
          succeeded: true,
          confirmed: confirmed,
          monitorCount: monitorCount,
          paths: paths,
          error: null,
        );
      } finally {
        wallpaper.release();
      }
    });
  } catch (error) {
    return (
      succeeded: false,
      confirmed: false,
      monitorCount: 0,
      paths: <String>[],
      error: error.toString(),
    );
  } finally {
    CoUninitialize();
  }
}

class WallpaperEngine {
  final _settingsService = SettingsService();
  final _appRuntimeService = AppRuntimeService();

  @visibleForTesting
  static int estimateWorkerDispatchAndReturnMs({
    required int roundTripMs,
    required int workerMs,
  }) => roundTripMs > workerMs ? roundTripMs - workerMs : 0;

  @visibleForTesting
  static bool wallpaperStateConfirmedForTesting({
    required bool setCallSucceeded,
    required bool stateQuerySucceeded,
    required String activePath,
    required String requestedPath,
  }) =>
      setCallSucceeded &&
      stateQuerySucceeded &&
      _wallpaperPathsMatch(activePath, requestedPath);

  @visibleForTesting
  static bool shouldUseSystemParametersFallback({
    required bool immediateComVerified,
    required bool delayedComVerified,
  }) => !immediateComVerified && !delayedComVerified;

  /// Gets the file where the wallpaper process ID is stored.
  Future<File> get wallpaperPidFile async {
    final file = await _settingsService.pidFile;
    // Save wallpaper pid in a sibling file
    return File(file.path.replaceAll('overlay.pid', 'wallpaper.pid'));
  }

  Future<File> get wallpaperLockFile async {
    final file = await _settingsService.lockFile;
    return File(file.path.replaceAll('overlay.lock', 'wallpaper.lock'));
  }

  Future<File> get wallpaperReadyFile async {
    final file = await wallpaperPidFile;
    return File(file.path.replaceAll('wallpaper.pid', 'wallpaper.ready'));
  }

  Future<void> markWallpaperReady() async {
    final readyFile = await wallpaperReadyFile;
    await readyFile.writeAsString(pid.toString(), flush: true);
  }

  Future<Directory> _prepareRuntime(String runtimeName) async {
    return _appRuntimeService.prepareRuntime(runtimeName);
  }

  Future<Directory> prepareOverlayRuntime() =>
      _prepareRuntime('OverlayRuntime');

  /// Sets a static high-resolution image as the Windows desktop wallpaper.
  Future<bool> setStaticWallpaper(
    String path,
    String style, {
    WidgetSettings? settings,
    bool Function()? isCancelled,
    int? transitionId,
  }) async {
    if (!Platform.isWindows) return false;
    logInfo(
      'WallpaperEngine',
      'Transition #${transitionId ?? '-'} preparing static wallpaper: $path with style: $style',
    );
    final sw = Stopwatch()..start();

    final imageFile = File(path);
    final validationStopwatch = Stopwatch()..start();
    final imageExists = await imageFile.exists();
    final imageLength = imageExists ? await imageFile.length() : 0;
    final validationMs = validationStopwatch.elapsedMilliseconds;
    if (!imageExists || imageLength == 0) {
      logError(
        'WallpaperEngine',
        'Wallpaper image does not exist or is empty: $path '
            '(validation ${validationMs}ms).',
        null,
        null,
      );
      return false;
    }
    logPerf(
      'WallpaperEngine',
      'Transition #${transitionId ?? '-'} cached image validation completed '
          'in ${validationMs}ms ($imageLength bytes).',
    );
    if (isCancelled?.call() ?? false) return false;
    final cleanPath = imageFile.absolute.path.replaceAll('/', '\\');

    final liveManager = LiveWallpaperManager();
    final restoreVideo = liveManager.currentPath.isNotEmpty;
    WidgetSettings? previousSettings;
    if (restoreVideo) {
      final currentSettings = settings ?? await _settingsService.loadSettings();
      previousSettings = currentSettings.copyWith(
        activeWallpaperType: 'video',
        activeWallpaperPath: liveManager.currentPath,
      );
      logInfo(
        'WallpaperEngine',
        'Transition #${transitionId ?? '-'} confirmed an active owned MPV path before static apply.',
      );
    }
    logInfo(
      'WallpaperEngine',
      'Transition #${transitionId ?? '-'} stopping owned video before applying static wallpaper.',
    );
    final stopVideoStopwatch = Stopwatch()..start();
    final stopped = await stopAnimatedWallpaper(transitionId: transitionId);
    final stopVideoMs = stopVideoStopwatch.elapsedMilliseconds;
    logPerf(
      'WallpaperEngine',
      'Transition #${transitionId ?? '-'} owned-video stop completed '
          'success=$stopped in ${stopVideoMs}ms.',
    );
    if (!stopped) return false;
    if (isCancelled?.call() ?? false) {
      logInfo(
        'WallpaperEngine',
        'Transition #${transitionId ?? '-'} cancelled before static apply.',
      );
      return false;
    }

    var wallpaperApplied = false;
    var appliedWithDesktopWallpaper = false;
    var desktopWallpaperSetMs = 0;
    var desktopWallpaperPositionMs = 0;
    var desktopWallpaperVerifyMs = 0;
    var desktopWallpaperDelayedVerifyMs = 0;
    var desktopWallpaperDelayedVerifyAttempted = false;
    var immediateDesktopWallpaperApplied = false;
    var systemParametersInfoSetMs = 0;
    var systemParametersInfoVerifyMs = 0;
    final nativeApplyStopwatch = Stopwatch()..start();
    final coInit = CoInitializeEx(COINIT_APARTMENTTHREADED);
    logInfo('WallpaperEngine', 'CoInitializeEx result: $coInit');
    final clsidString = '{C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD}';
    try {
      using((arena) {
        final clsid = IIDFromString(
          PCWSTR(clsidString.toNativeUtf16(allocator: arena)),
        );
        final wallpaper = CoCreateInstance<IDesktopWallpaper>(
          clsid,
          null,
          CLSCTX_ALL,
        );
        try {
          final pathPtr = cleanPath.toNativeUtf16(allocator: arena);
          final setWallpaperStopwatch = Stopwatch()..start();
          logInfo(
            'WallpaperEngine',
            'Transition #${transitionId ?? '-'} entering '
                'IDesktopWallpaper.setWallpaper.',
          );
          wallpaper.setWallpaper(PCWSTR(nullptr), PCWSTR(pathPtr));
          desktopWallpaperSetMs = setWallpaperStopwatch.elapsedMilliseconds;
          logPerf(
            'WallpaperEngine',
            'Transition #${transitionId ?? '-'} '
                'IDesktopWallpaper.setWallpaper returned in '
                '${desktopWallpaperSetMs}ms.',
          );
          final DESKTOP_WALLPAPER_POSITION position = switch (style) {
            'fit' => DWPOS_FIT,
            'stretch' => DWPOS_STRETCH,
            'tile' => DWPOS_TILE,
            'center' => DWPOS_CENTER,
            'span' => DWPOS_SPAN,
            _ => DWPOS_FILL,
          };
          try {
            final setPositionStopwatch = Stopwatch()..start();
            logInfo(
              'WallpaperEngine',
              'Transition #${transitionId ?? '-'} entering '
                  'IDesktopWallpaper.setPosition for style=$style.',
            );
            wallpaper.setPosition(position);
            desktopWallpaperPositionMs =
                setPositionStopwatch.elapsedMilliseconds;
            logPerf(
              'WallpaperEngine',
              'Transition #${transitionId ?? '-'} IDesktopWallpaper.setPosition '
                  'returned in ${desktopWallpaperPositionMs}ms.',
            );
          } catch (e, st) {
            logError(
              'WallpaperEngine',
              'Failed to set static wallpaper fit mode',
              e,
              st,
            );
          }

          final verifyStopwatch = Stopwatch()..start();
          final monitorCount = wallpaper.getMonitorDevicePathCount();
          wallpaperApplied = monitorCount > 0;
          final actualPaths = <String>[];
          for (var i = 0; i < monitorCount; i++) {
            final monitor = wallpaper.getMonitorDevicePathAt(i);
            try {
              final activeWallpaper = wallpaper.getWallpaper(PCWSTR(monitor));
              try {
                final activePath = activeWallpaper.toDartString();
                actualPaths.add(activePath);
                wallpaperApplied = _wallpaperPathsMatch(activePath, cleanPath);
              } finally {
                CoTaskMemFree(activeWallpaper);
              }
            } finally {
              CoTaskMemFree(monitor);
            }
          }
          desktopWallpaperVerifyMs = verifyStopwatch.elapsedMilliseconds;
          logPerf(
            'WallpaperEngine',
            'Transition #${transitionId ?? '-'} IDesktopWallpaper '
                'monitor-path verification completed in '
                '${desktopWallpaperVerifyMs}ms '
                '(confirmed=$wallpaperApplied, monitors=$monitorCount, '
                'requested="$cleanPath", '
                'actual=${actualPaths.map((p) => '"$p"').join(', ')}).',
          );
          appliedWithDesktopWallpaper = wallpaperApplied;
        } finally {
          wallpaper.release();
        }
      });
    } catch (e) {
      logWarning(
        'WallpaperEngine',
        'IDesktopWallpaper could not confirm the requested static wallpaper: $e',
      );
    } finally {
      // S_OK and S_FALSE both increment the current thread's COM init count.
      if (coInit >= 0) {
        CoUninitialize();
      }
    }
    immediateDesktopWallpaperApplied = wallpaperApplied;
    var verifyAttempts = 1;
    var pollingWaitMs = 0;
    var pollingQueryMs = 0;
    if (!wallpaperApplied) {
      desktopWallpaperDelayedVerifyAttempted = true;
      final delayedVerifyStopwatch = Stopwatch()..start();
      final pollingIntervals = [100, 150, 200, 250, 300];
      var totalElapsedPollingMs = 0;
      for (final intervalMs in pollingIntervals) {
        if (isCancelled?.call() ?? false) {
          logInfo(
            'WallpaperEngine',
            'Transition #${transitionId ?? '-'} cancelled during wallpaper verification.',
          );
          break;
        }
        await Future<void>.delayed(Duration(milliseconds: intervalMs));
        totalElapsedPollingMs += intervalMs;
        pollingWaitMs += intervalMs;
        verifyAttempts++;

        final queryStopwatch = Stopwatch()..start();
        final delayedState = _readDesktopWallpaperState(cleanPath);
        final queryElapsed = queryStopwatch.elapsedMilliseconds;
        pollingQueryMs += queryElapsed;

        if (delayedState.succeeded && delayedState.confirmed) {
          wallpaperApplied = true;
          appliedWithDesktopWallpaper = true;
          logPerf(
            'WallpaperEngine',
            'Transition #${transitionId ?? '-'} IDesktopWallpaper confirmed '
                'via direct adaptive polling in ${delayedVerifyStopwatch.elapsedMilliseconds}ms '
                '(attempt $verifyAttempts, interval ${intervalMs}ms, '
                'native query ${queryElapsed}ms, monitors=${delayedState.monitorCount}).',
          );
          break;
        }
        if (totalElapsedPollingMs >= 1200) break;
      }
      desktopWallpaperDelayedVerifyMs =
          delayedVerifyStopwatch.elapsedMilliseconds;
      if (!wallpaperApplied) {
        if (desktopWallpaperSetMs > 0) {
          logWarning(
            'WallpaperEngine',
            'Transition #${transitionId ?? '-'} IDesktopWallpaper.setWallpaper succeeded in ${desktopWallpaperSetMs}ms, '
                'but monitor-path verification timed out after ${desktopWallpaperDelayedVerifyMs}ms across $verifyAttempts attempts.',
          );
        } else {
          logWarning(
            'WallpaperEngine',
            'Transition #${transitionId ?? '-'} IDesktopWallpaper adaptive polling '
                'timed out after ${desktopWallpaperDelayedVerifyMs}ms across $verifyAttempts attempts.',
          );
        }
      }
    }
    final desktopWallpaperTotalMs = nativeApplyStopwatch.elapsedMilliseconds;
    logPerf(
      'WallpaperEngine',
      'Transition #${transitionId ?? '-'} IDesktopWallpaper phases: '
          'set=${desktopWallpaperSetMs}ms, style=${desktopWallpaperPositionMs}ms, '
          'immediateVerification=${desktopWallpaperVerifyMs}ms, '
          'delayedVerification=${desktopWallpaperDelayedVerifyAttempted ? '${desktopWallpaperDelayedVerifyMs}ms ($verifyAttempts attempts; wait=${pollingWaitMs}ms, query=${pollingQueryMs}ms)' : 'not-needed'}, '
          'totalNative=${desktopWallpaperTotalMs}ms.',
    );

    if (WallpaperEngine.shouldUseSystemParametersFallback(
      immediateComVerified: immediateDesktopWallpaperApplied,
      delayedComVerified:
          desktopWallpaperDelayedVerifyAttempted && wallpaperApplied,
    )) {
      logInfo(
        'WallpaperEngine',
        'Transition #${transitionId ?? '-'} dispatching '
            'SystemParametersInfo fallback to a worker isolate for style=$style.',
      );
      final workerRoundTripStopwatch = Stopwatch()..start();
      final result = await _applyWallpaperWithSystemParametersInfo(cleanPath);
      final workerRoundTripMs = workerRoundTripStopwatch.elapsedMilliseconds;
      final dispatchAndReturnMs =
          WallpaperEngine.estimateWorkerDispatchAndReturnMs(
            roundTripMs: workerRoundTripMs,
            workerMs: result.workerMs,
          );
      systemParametersInfoSetMs = result.setMs;
      systemParametersInfoVerifyMs = result.verifyMs;
      wallpaperApplied = result.confirmed;
      logPerf(
        'WallpaperEngine',
        'Transition #${transitionId ?? '-'} worker-isolate '
            'SystemParametersInfo timing: isolate dispatch/return overhead '
            'estimate=${dispatchAndReturnMs}ms, worker execution '
            '${result.workerMs}ms, SPI_SETDESKWALLPAPER call '
            '${result.setMs}ms, SPI_GET path-state verification '
            '${result.verifyMs}ms; request-to-path-state-confirmation '
            '${workerRoundTripMs}ms (style=$style, '
            'apiSuccess=${result.succeeded}, setError=${result.setError}, '
            'verifyApiSuccess=${result.verifySucceeded}, '
            'verifyError=${result.verifyError}, pathConfirmed=${result.confirmed}, '
            'requested="$cleanPath", actual="${result.activePath}").',
      );
      if (!result.succeeded) {
        logError(
          'WallpaperEngine',
          'SystemParametersInfo(SPI_SETDESKWALLPAPER) failed with Win32 error ${result.setError}',
          null,
          null,
        );
      }
      logPerf(
        'WallpaperEngine',
        'Transition #${transitionId ?? '-'} '
            'SPI_GETDESKWALLPAPER final path-state verification completed in '
            '${result.verifyMs}ms (apiSuccess=${result.verifySucceeded}, '
            'error=${result.verifyError}, confirmed=$wallpaperApplied, '
            'activePath="${result.activePath}").',
      );
      if (!wallpaperApplied) {
        logError(
          'WallpaperEngine',
          'Windows did not confirm the requested static wallpaper path.',
        );
      }
    }

    final durationMs = sw.elapsedMilliseconds;
    if (wallpaperApplied) {
      final message =
          'Transition #${transitionId ?? '-'} static wallpaper transition success=true '
          'finalPathStateVerified=true '
          'method=${appliedWithDesktopWallpaper ? (desktopWallpaperDelayedVerifyAttempted ? 'IDesktopWallpaper-delayed-verified' : 'IDesktopWallpaper') : 'SystemParametersInfo'} '
          'total=${durationMs}ms (image validation=${validationMs}ms, '
          'video stop=${stopVideoMs}ms, IDesktopWallpaper=${desktopWallpaperTotalMs}ms, '
          'IDesktopWallpaper delayed verification=${desktopWallpaperDelayedVerifyAttempted ? '${desktopWallpaperDelayedVerifyMs}ms' : 'not-needed'}, '
          'SPI set=${systemParametersInfoSetMs}ms, '
          'SPI verification=${systemParametersInfoVerifyMs}ms).';
      if (durationMs > 2500) {
        logWarning('WallpaperEngine', message);
      } else {
        logPerf('WallpaperEngine', message);
      }
    } else if (restoreVideo) {
      logError(
        'WallpaperEngine',
        'Transition #${transitionId ?? '-'} static wallpaper transition '
            'success=false total=${durationMs}ms (image validation=${validationMs}ms, '
            'video stop=${stopVideoMs}ms, IDesktopWallpaper=${desktopWallpaperTotalMs}ms, '
            'SPI set=${systemParametersInfoSetMs}ms, '
            'SPI verification=${systemParametersInfoVerifyMs}ms).',
      );
      if (!(isCancelled?.call() ?? false)) {
        await _restoreVideoAfterFailedStaticApply(previousSettings, transitionId);
      }
    } else {
      logError(
        'WallpaperEngine',
        'Transition #${transitionId ?? '-'} static wallpaper transition '
            'success=false total=${durationMs}ms (image validation=${validationMs}ms, '
            'video stop=${stopVideoMs}ms, IDesktopWallpaper=${desktopWallpaperTotalMs}ms, '
            'SPI set=${systemParametersInfoSetMs}ms, '
            'SPI verification=${systemParametersInfoVerifyMs}ms).',
      );
    }
    return wallpaperApplied;
  }

  /// Starts the live video wallpaper using Lively's MPV player architecture.
  Future<bool> startAnimatedWallpaper(
    String path, {
    WidgetSettings? settings,
    bool Function()? isCancelled,
    int? transitionId,
  }) async {
    if (!Platform.isWindows) return false;
    logInfo(
      'WallpaperEngine',
      'Starting live video wallpaper with Lively MPV engine: $path',
    );
    final sw = Stopwatch()..start();

    final trimmed = path.trim();
    final uri = Uri.tryParse(trimmed);
    final filePath = (uri != null && uri.scheme == 'file')
        ? uri.toFilePath()
        : trimmed;
    final videoFile = File(filePath);
    if (!await videoFile.exists() || await videoFile.length() == 0) {
      logError(
        'WallpaperEngine',
        'Video wallpaper file does not exist or is empty: $filePath',
      );
      return false;
    }
    if (isCancelled?.call() ?? false) return false;
    final canonicalPath = videoFile.absolute.path;
    final previousVideoPath = LiveWallpaperManager().currentPath;

    try {
      final currentSettings = settings ?? await _settingsService.loadSettings();
      final updatedSettings = currentSettings.copyWith(
        activeWallpaperType: 'video',
        activeWallpaperPath: canonicalPath,
        videoWallpaperPaused: false,
      );

      final liveManager = LiveWallpaperManager();
      logInfo(
        'WallpaperEngine',
        'Transition #${transitionId ?? '-'} starting video: $canonicalPath',
      );
      await liveManager.start(
        updatedSettings,
        isCancelled: isCancelled,
        transitionId: transitionId,
      );
      if (isCancelled?.call() ?? false) {
        logInfo(
          'WallpaperEngine',
          'Transition #${transitionId ?? '-'} cancelled after liveManager.start; returning false.',
        );
        return false;
      }

      final pidFile = await wallpaperPidFile;
      final readyFile = await wallpaperReadyFile;
      final effectivePid = (liveManager.mpvPid ?? pid).toString();
      await pidFile.writeAsString(effectivePid, flush: true);
      await readyFile.writeAsString(effectivePid, flush: true);

      final durationMs = sw.elapsedMilliseconds;
      if (durationMs > 3000) {
        logWarning(
          'WallpaperEngine',
          'Transition #${transitionId ?? '-'} video startup took ${durationMs}ms; '
              'PID ${liveManager.mpvPid}, attached=true, visible=true, firstFrame=true.',
        );
      } else {
        logPerf(
          'WallpaperEngine',
          'Transition #${transitionId ?? '-'} video wallpaper active in ${durationMs}ms: $canonicalPath (PID ${liveManager.mpvPid}, attached=true, visible=true, firstFrame=true)',
        );
      }
      return true;
    } on MpvStartupCancelledException catch (e) {
      logInfo(
        'WallpaperEngine',
        'Transition #${transitionId ?? '-'} video startup cancelled: ${e.message}',
      );
      return false;
    } catch (e, st) {
      logError(
        'WallpaperEngine',
        'Failed to launch MPV video wallpaper',
        e,
        st,
      );
      final stopped = await stopAnimatedWallpaper(transitionId: transitionId);
      if (!stopped) {
        logError(
          'WallpaperEngine',
          'Could not confirm cleanup of the failed MPV startup.',
        );
      }
      if (previousVideoPath.isNotEmpty && !(isCancelled?.call() ?? false)) {
        logWarning(
          'WallpaperEngine',
          'Restoring the previously active video wallpaper after startup failure: $previousVideoPath',
        );
        final restored = await startAnimatedWallpaper(
          previousVideoPath,
          transitionId: transitionId,
        );
        if (!restored) {
          logError(
            'WallpaperEngine',
            'Failed to restore the previously active video wallpaper: $previousVideoPath',
          );
        }
      }
      return false;
    }
  }

  Future<void> _restoreVideoAfterFailedStaticApply(
    WidgetSettings? previousSettings,
    int? transitionId,
  ) async {
    final previousPath = previousSettings?.activeWallpaperPath;
    if (previousSettings?.activeWallpaperType != 'video' ||
        previousPath == null ||
        previousPath.isEmpty) {
      return;
    }

    try {
      logWarning(
        'WallpaperEngine',
        'Transition #${transitionId ?? '-'} static apply did not complete; restoring the previous video wallpaper.',
      );
      final restored = await startAnimatedWallpaper(
        previousPath,
        transitionId: transitionId,
      );
      if (!restored) {
        logError(
          'WallpaperEngine',
          'Failed to restore the previous video after a static wallpaper transition failed.',
        );
      }
    } catch (e, st) {
      logError(
        'WallpaperEngine',
        'Failed to restore the previous video after a static wallpaper transition failed.',
        e,
        st,
      );
    }
  }

  /// Stops the running live video wallpaper process.
  Future<bool> stopAnimatedWallpaper({int? transitionId}) async {
    if (!Platform.isWindows) return true;
    logInfo('WallpaperEngine', 'Stopping live video wallpaper process...');

    try {
      final liveManager = LiveWallpaperManager();
      await liveManager.stop(transitionId: transitionId);

      final pidFile = await wallpaperPidFile;
      final readyFile = await wallpaperReadyFile;
      if (await pidFile.exists()) await pidFile.delete();
      if (await readyFile.exists()) {
        await readyFile.delete();
      }
      return true;
    } catch (e, st) {
      logError('WallpaperEngine', 'Error stopping wallpaper process', e, st);
      return false;
    }
  }

  /// Reparents the current process's window to the desktop background shell.
  Future<bool> reparentToDesktop() async {
    if (!Platform.isWindows) return false;
    logInfo('WallpaperEngine', 'Starting desktop reparenting process...');
    final attached = await LiveWallpaperManager.channel.invokeMethod<bool>(
      'attachToDesktop',
    );
    if (attached == null) {
      throw StateError('Native wallpaper plugin returned no attach result.');
    }
    return attached;
  }
}
