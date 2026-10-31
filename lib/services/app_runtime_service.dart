import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'settings_service.dart';
import 'system_optimizer_service.dart';

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

    // Fast content fingerprinting using relative path, file size, and executable second-level mtime
    final fingerprintStopwatch = Stopwatch()..start();
    final stats = await Future.wait(entries.map((e) => e.stat()));
    final fingerprint = StringBuffer();
    final sourceFileSizes = <String, int>{};
    var totalBytes = 0;
    for (var i = 0; i < entries.length; i++) {
      final entity = entries[i];
      final stat = stats[i];
      final relativePath = entity.path.substring(sourceDir.path.length);
      final isExecutable = entity.path.endsWith(executableName);
      fingerprint
        ..write(relativePath)
        ..write('|')
        ..write(stat.type)
        ..write('|')
        ..write(stat.size);
      if (isExecutable) {
        // Only track executable timestamp at second resolution to remain stable across hot-restarts
        fingerprint.write('|${stat.modified.millisecondsSinceEpoch ~/ 1000}');
      }
      fingerprint.write('\n');

      if (entity is File) {
        final rel = relativePath.startsWith('\\') || relativePath.startsWith('/')
            ? relativePath.substring(1)
            : relativePath;
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
          '$runtimeName invalid manifest in $version ($e); syncing.',
        );
      }
    }

    // 4. Incremental preparation: copy only missing or mismatched files directly into runtimeDir
    final copyStopwatch = Stopwatch()..start();
    await runtimeDir.create(recursive: true);

    try {
      // Ensure subdirectories exist
      for (final entity in entries.whereType<Directory>()) {
        final relativePath = entity.path.substring(sourceDir.path.length + 1);
        final destination = '${runtimeDir.path}\\$relativePath';
        await Directory(destination).create(recursive: true);
      }

      // Copy files with bounded concurrency (8 parallel workers), skipping unchanged files
      final files = entries.whereType<File>().toList();
      var copiedCount = 0;
      var copiedBytes = 0;
      const concurrency = 8;
      for (var i = 0; i < files.length; i += concurrency) {
        final batch = files.sublist(i, math.min(i + concurrency, files.length));
        await Future.wait(
          batch.map((entity) async {
            final relativePath =
                entity.path.substring(sourceDir.path.length + 1);
            final destination = '${runtimeDir.path}\\$relativePath';
            final destFile = File(destination);
            final sourceSize = sourceFileSizes[relativePath] ?? 0;
            if (await destFile.exists()) {
              final destSize = await destFile.length();
              if (destSize == sourceSize) {
                return; // File is already up-to-date
              }
            }
            await Directory(destFile.parent.path).create(recursive: true);
            // Attempt zero-copy native NTFS hard link first (0ms, 0 disk space)
            bool linked = false;
            try {
              linked = await SystemOptimizerService.instance.createHardLink(
                target: destination,
                existing: entity.path,
              );
            } catch (_) {}
            if (!linked) {
              await entity.copy(destination);
              copiedBytes += sourceSize;
            }
            copiedCount++;
          }),
        );
      }

      // Write completion manifest
      final manifestPayload = {
        'version': version,
        'executableName': executableName,
        'fileCount': sourceFileSizes.length,
        'totalBytes': totalBytes,
        'completedAt': DateTime.now().toIso8601String(),
      };
      await manifestFile.writeAsString(
        jsonEncode(manifestPayload),
        flush: false,
      );

      logPerf(
        'AppRuntimeService',
        '$runtimeName runtime sync completed in ${copyStopwatch.elapsedMilliseconds}ms '
        '(total ${stopwatch.elapsedMilliseconds}ms; synced $copiedCount/${files.length} files, '
        '${(copiedBytes / (1024 * 1024)).toStringAsFixed(1)}MB copied).',
      );

      _sessionPreparedRuntimes[runtimeName] = runtimeDir;
      _cachedRuntimeDir = runtimeDir;

      // Auto-prune old runtime versions asynchronously in background
      unawaited(() async {
        try {
          await for (final oldEntity in runtimeParent.list(followLinks: false)) {
            if (oldEntity is Directory &&
                oldEntity.path != runtimeDir.path &&
                !oldEntity.path.contains('.tmp')) {
              try {
                await oldEntity.delete(recursive: true);
              } catch (_) {}
            }
          }
        } catch (_) {}
      }());

      return runtimeDir;
    } catch (error) {
      logError('AppRuntimeService', 'Failed to prepare runtime: $error');
      rethrow;
    }
  }
}
