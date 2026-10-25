import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'settings_service.dart';

class AppRuntimeService {
  static final Map<String, Directory> _sessionPreparedRuntimes = {};
  static final Map<String, Future<Directory>> _inFlightPreparations = {};
  Directory? _cachedRuntimeDir;

  Future<Directory> prepareRuntime(String runtimeName) {
    // 1. Session memory cache check
    final cached = _sessionPreparedRuntimes[runtimeName] ?? _cachedRuntimeDir;
    if (cached != null) {
      final executableName =
          File(Platform.resolvedExecutable).uri.pathSegments.last;
      final cachedExe = File('${cached.path}\\$executableName');
      final manifest = File('${cached.path}\\runtime.manifest');
      if (cachedExe.existsSync() && manifest.existsSync()) {
        return Future.value(cached);
      }
    }

    // 2. Coalesce concurrent requests to prevent duplicate copies or races
    final inFlight = _inFlightPreparations[runtimeName];
    if (inFlight != null) {
      logInfo(
        'AppRuntimeService',
        'Coalescing concurrent $runtimeName preparation request.',
      );
      return inFlight;
    }

    late final Future<Directory> operation;
    operation = _prepareRuntimeInternal(runtimeName).whenComplete(() {
      if (identical(_inFlightPreparations[runtimeName], operation)) {
        _inFlightPreparations.remove(runtimeName);
      }
    });
    _inFlightPreparations[runtimeName] = operation;
    return operation;
  }

  Future<Directory> _prepareRuntimeInternal(String runtimeName) async {
    final stopwatch = Stopwatch()..start();
    final sourceDir = File(Platform.resolvedExecutable).parent;
    final executableName =
        File(Platform.resolvedExecutable).uri.pathSegments.last;

    // Filter files: exclude mpv for the Flutter-only overlay
    final listingStopwatch = Stopwatch()..start();
    final rawEntries = await sourceDir
        .list(recursive: true, followLinks: false)
        .toList();
    final entries = rawEntries.where((entity) {
      if (runtimeName == 'OverlayRuntime') {
        final lower = entity.path.toLowerCase();
        if (lower.endsWith('mpv.exe') || lower.contains(r'\plugins\mpv\')) {
          return false;
        }
      }
      return true;
    }).toList();
    entries.sort((a, b) => a.path.compareTo(b.path));
    final listingMs = listingStopwatch.elapsedMilliseconds;

    // Fast content fingerprinting
    final fingerprintStopwatch = Stopwatch()..start();
    final stats = await Future.wait(entries.map((e) => e.stat()));
    final fingerprint = StringBuffer();
    final sourceFileSizes = <String, int>{};
    var totalBytes = 0;
    for (var i = 0; i < entries.length; i++) {
      final entity = entries[i];
      final stat = stats[i];
      final relativePath = entity.path.substring(sourceDir.path.length);
      fingerprint
        ..write(relativePath)
        ..write('|')
        ..write(stat.type)
        ..write('|')
        ..write(stat.size)
        ..write('|')
        ..write(stat.modified.microsecondsSinceEpoch)
        ..write('\n');
      if (entity is File) {
        final rel = relativePath.substring(1);
        sourceFileSizes[rel] = stat.size;
        totalBytes += stat.size;
      }
    }
    final version =
        sha256.convert(utf8.encode(fingerprint.toString())).toString();
    final fingerprintMs = fingerprintStopwatch.elapsedMilliseconds;

    final localAppData =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    final runtimeParent = Directory('$localAppData\\WallSync\\$runtimeName');
    await runtimeParent.create(recursive: true);
    final runtimeDir = Directory('${runtimeParent.path}\\$version');
    final manifestFile = File('${runtimeDir.path}\\runtime.manifest');
    final runtimeExecutable = File('${runtimeDir.path}\\$executableName');

    // 3. Warm check: verify existing complete runtime via manifest
    if (await runtimeExecutable.exists() && await manifestFile.exists()) {
      try {
        final manifestContent = await manifestFile.readAsString();
        final manifestData = jsonDecode(manifestContent) as Map<String, dynamic>;
        if (manifestData['version'] == version &&
            manifestData['fileCount'] == sourceFileSizes.length &&
            manifestData['totalBytes'] == totalBytes) {
          logPerf(
            'AppRuntimeService',
            '$runtimeName warm reuse confirmed in ${stopwatch.elapsedMilliseconds}ms '
            '(scan=${listingMs}ms, fingerprint=${fingerprintMs}ms, '
            '${sourceFileSizes.length} files verified via manifest).',
          );
          _sessionPreparedRuntimes[runtimeName] = runtimeDir;
          _cachedRuntimeDir = runtimeDir;
          return runtimeDir;
        }
      } catch (e) {
        logWarning(
          'AppRuntimeService',
          '$runtimeName invalid manifest in $version ($e); recreating.',
        );
      }
    }

    // 4. Cold preparation: stage into an isolated temp directory to prevent partial copies
    final copyStopwatch = Stopwatch()..start();
    final stagingDir = Directory(
      '${runtimeParent.path}\\$version.tmp_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    );
    if (await stagingDir.exists()) await stagingDir.delete(recursive: true);
    await stagingDir.create(recursive: true);

    try {
      // Create subdirectories in staging
      for (final entity in entries.whereType<Directory>()) {
        final relativePath = entity.path.substring(sourceDir.path.length + 1);
        final destination = '${stagingDir.path}\\$relativePath';
        await Directory(destination).create(recursive: true);
      }

      // Copy files with bounded concurrency (8 parallel workers)
      final files = entries.whereType<File>().toList();
      const concurrency = 8;
      for (var i = 0; i < files.length; i += concurrency) {
        final batch = files.sublist(i, math.min(i + concurrency, files.length));
        await Future.wait(
          batch.map((entity) async {
            final relativePath =
                entity.path.substring(sourceDir.path.length + 1);
            final destination = '${stagingDir.path}\\$relativePath';
            await Directory(
              File(destination).parent.path,
            ).create(recursive: true);
            await entity.copy(destination);
          }),
        );
      }

      // Write completion manifest into staging directory BEFORE atomic rename
      final stagingManifest = File('${stagingDir.path}\\runtime.manifest');
      final manifestPayload = {
        'version': version,
        'executableName': executableName,
        'fileCount': sourceFileSizes.length,
        'totalBytes': totalBytes,
        'completedAt': DateTime.now().toIso8601String(),
      };
      await stagingManifest.writeAsString(
        jsonEncode(manifestPayload),
        flush: true,
      );

      // Atomic publication: if runtimeDir exists, remove stale/incomplete folder first
      if (await runtimeDir.exists()) {
        try {
          await runtimeDir.delete(recursive: true);
        } catch (_) {}
      }

      await stagingDir.rename(runtimeDir.path);

      logPerf(
        'AppRuntimeService',
        '$runtimeName cold runtime copy completed in ${copyStopwatch.elapsedMilliseconds}ms '
        '(total ${stopwatch.elapsedMilliseconds}ms; ${files.length} files, '
        '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)}MB).',
      );

      _sessionPreparedRuntimes[runtimeName] = runtimeDir;
      _cachedRuntimeDir = runtimeDir;

      // Auto-prune old runtime versions asynchronously in background
      unawaited(() async {
        try {
          await for (final oldEntity in runtimeParent.list(followLinks: false)) {
            if (oldEntity is Directory &&
                oldEntity.path != runtimeDir.path) {
              try {
                await oldEntity.delete(recursive: true);
              } catch (_) {}
            }
          }
        } catch (_) {}
      }());

      return runtimeDir;
    } catch (error) {
      if (await stagingDir.exists()) {
        try {
          await stagingDir.delete(recursive: true);
        } catch (_) {}
      }
      rethrow;
    }
  }
}
