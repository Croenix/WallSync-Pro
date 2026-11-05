import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'settings_service.dart';
import 'system_optimizer_service.dart';

class AppRuntimeService {
  static final Map<String, Future<Directory>> _inFlightPreparations = {};

  AppRuntimeService({
    Directory? sourceDirectory,
    this.runtimeBaseDirectory,
    String? executableName,
  }) : _sourceDirectory =
           sourceDirectory ?? File(Platform.resolvedExecutable).parent,
       _executableName =
           executableName ??
           File(Platform.resolvedExecutable).uri.pathSegments.last;

  final Directory _sourceDirectory;
  final Directory? runtimeBaseDirectory;
  final String _executableName;

  Future<Directory> prepareRuntime(
    String runtimeName, {
    bool allowHardLinks = true,
  }) {
    final preparationKey = '$runtimeName|hardLinks=$allowHardLinks';
    // Coalesce concurrent requests to prevent duplicate copies or races.
    final inFlight = _inFlightPreparations[preparationKey];
    if (inFlight != null) {
      logInfo(
        'AppRuntimeService',
        'Coalescing concurrent $runtimeName preparation request.',
      );
      return inFlight;
    }

    late final Future<Directory> operation;
    operation =
        _prepareRuntimeInternal(
          runtimeName,
          allowHardLinks: allowHardLinks,
        ).whenComplete(() {
          if (identical(_inFlightPreparations[preparationKey], operation)) {
            _inFlightPreparations.remove(preparationKey);
          }
        });
    _inFlightPreparations[preparationKey] = operation;
    return operation;
  }

  Future<Directory> _prepareRuntimeInternal(
    String runtimeName, {
    required bool allowHardLinks,
  }) async {
    final stopwatch = Stopwatch()..start();
    final sourceDir = _sourceDirectory;
    final executableName = _executableName;

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

    // Include each entry's modification time so same-size Flutter asset changes
    // cannot reuse a stale overlay runtime.
    final fingerprintStopwatch = Stopwatch()..start();
    final stats = await Future.wait(entries.map((e) => e.stat()));
    final fingerprint = StringBuffer('allowHardLinks=$allowHardLinks\n');
    final sourceFileSizes = <String, int>{};
    final sourceFileModified = <String, int>{};
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
        final rel =
            relativePath.startsWith('\\') || relativePath.startsWith('/')
            ? relativePath.substring(1)
            : relativePath;
        sourceFileSizes[rel] = stat.size;
        sourceFileModified[rel] = stat.modified.microsecondsSinceEpoch;
        totalBytes += stat.size;
      }
    }
    final version = sha256
        .convert(utf8.encode(fingerprint.toString()))
        .toString();
    final fingerprintMs = fingerprintStopwatch.elapsedMilliseconds;

    final localAppData =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    final runtimeRoot =
        runtimeBaseDirectory ?? Directory('$localAppData\\WallSync');
    final runtimeParent = Directory('${runtimeRoot.path}\\$runtimeName');
    await runtimeParent.create(recursive: true);
    final runtimeDir = Directory('${runtimeParent.path}\\$version');
    final manifestFile = File('${runtimeDir.path}\\runtime.manifest');
    final runtimeExecutable = File('${runtimeDir.path}\\$executableName');

    // Reuse a runtime only after its source inventory and every file size match.
    if (await runtimeExecutable.exists() && await manifestFile.exists()) {
      try {
        final manifestContent = await manifestFile.readAsString();
        final manifestData =
            jsonDecode(manifestContent) as Map<String, dynamic>;
        final manifestFiles = manifestData['files'];
        var filesMatch =
            manifestFiles is Map &&
            manifestFiles.length == sourceFileSizes.length &&
            manifestData['version'] == version &&
            manifestData['allowHardLinks'] == allowHardLinks &&
            manifestData['fileCount'] == sourceFileSizes.length &&
            manifestData['totalBytes'] == totalBytes;
        if (filesMatch) {
          for (final entry in sourceFileSizes.entries) {
            final fileMetadata = manifestFiles[entry.key];
            if (fileMetadata is! Map ||
                fileMetadata['size'] != entry.value ||
                fileMetadata['modified'] != sourceFileModified[entry.key]) {
              filesMatch = false;
              break;
            }
            final runtimeFile = File('${runtimeDir.path}\\${entry.key}');
            try {
              final runtimeStat = await runtimeFile.stat();
              if (runtimeStat.type != FileSystemEntityType.file ||
                  runtimeStat.size != entry.value ||
                  runtimeStat.modified.microsecondsSinceEpoch !=
                      sourceFileModified[entry.key]) {
                filesMatch = false;
                break;
              }
            } on FileSystemException {
              filesMatch = false;
              break;
            }
          }
        }
        if (filesMatch) {
          logPerf(
            'AppRuntimeService',
            '$runtimeName warm reuse confirmed in ${stopwatch.elapsedMilliseconds}ms '
                '(scan=${listingMs}ms, fingerprint=${fingerprintMs}ms, '
                '${sourceFileSizes.length} file paths and sizes verified).',
          );
          return runtimeDir;
        }
        logWarning(
          'AppRuntimeService',
          '$runtimeName cache inventory or file-size verification failed; '
              'repairing runtime $version.',
        );
      } catch (e) {
        logWarning(
          'AppRuntimeService',
          '$runtimeName invalid manifest in $version ($e); syncing.',
        );
      }
    }

    // Copy only missing or mismatched files into runtimeDir.
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
            final relativePath = entity.path.substring(
              sourceDir.path.length + 1,
            );
            final destination = '${runtimeDir.path}\\$relativePath';
            final destFile = File(destination);
            final sourceSize = sourceFileSizes[relativePath] ?? 0;
            final sourceModified = sourceFileModified[relativePath];
            if (await destFile.exists()) {
              final destStat = await destFile.stat();
              if (destStat.type == FileSystemEntityType.file &&
                  destStat.size == sourceSize &&
                  destStat.modified.microsecondsSinceEpoch == sourceModified) {
                return; // File is already up-to-date
              }
            }
            await Directory(destFile.parent.path).create(recursive: true);
            // Attempt zero-copy native NTFS hard link first (0ms, 0 disk space)
            var linked = false;
            if (allowHardLinks) {
              try {
                linked = await SystemOptimizerService.instance.createHardLink(
                  target: destination,
                  existing: entity.path,
                );
              } catch (_) {}
            }
            if (!linked) {
              await entity.copy(destination);
              copiedBytes += sourceSize;
            }
            copiedCount++;
          }),
        );
      }

      final fileInventory = <String, Map<String, int>>{
        for (final entry in sourceFileSizes.entries)
          entry.key: {
            'size': entry.value,
            'modified': sourceFileModified[entry.key]!,
          },
      };
      final manifestPayload = {
        'version': version,
        'executableName': executableName,
        'allowHardLinks': allowHardLinks,
        'fileCount': sourceFileSizes.length,
        'totalBytes': totalBytes,
        'files': fileInventory,
        'completedAt': DateTime.now().toIso8601String(),
      };
      final manifestTemporaryFile = File(
        '${manifestFile.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
      );
      await manifestTemporaryFile.writeAsString(
        jsonEncode(manifestPayload),
        flush: true,
      );
      if (await manifestFile.exists()) {
        await manifestFile.delete();
      }
      await manifestTemporaryFile.rename(manifestFile.path);

      logPerf(
        'AppRuntimeService',
        '$runtimeName runtime sync completed in ${copyStopwatch.elapsedMilliseconds}ms '
            '(total ${stopwatch.elapsedMilliseconds}ms; synced $copiedCount/${files.length} files, '
            '${(copiedBytes / (1024 * 1024)).toStringAsFixed(1)}MB copied).',
      );

      return runtimeDir;
    } catch (error) {
      logError('AppRuntimeService', 'Failed to prepare runtime: $error');
      rethrow;
    }
  }
}
