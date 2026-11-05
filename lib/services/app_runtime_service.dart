import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'settings_service.dart';
import 'system_optimizer_service.dart';

final class _WindowsFileBasicInfo extends Struct {
  @Int64()
  external int creationTime;

  @Int64()
  external int lastAccessTime;

  @Int64()
  external int lastWriteTime;

  @Int64()
  external int changeTime;

  @Uint32()
  external int fileAttributes;
}

typedef _CreateFileWNative =
    IntPtr Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      IntPtr,
    );
typedef _CreateFileWDart =
    int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);
typedef _GetFileInformationByHandleExNative =
    Int32 Function(IntPtr, Int32, Pointer<_WindowsFileBasicInfo>, Uint32);
typedef _GetFileInformationByHandleExDart =
    int Function(int, int, Pointer<_WindowsFileBasicInfo>, int);
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);

final DynamicLibrary _windowsKernel32 = DynamicLibrary.open('kernel32.dll');
final _CreateFileWDart _createWindowsFile = _windowsKernel32
    .lookupFunction<_CreateFileWNative, _CreateFileWDart>('CreateFileW');
final _GetFileInformationByHandleExDart _getWindowsFileInformation =
    _windowsKernel32.lookupFunction<
      _GetFileInformationByHandleExNative,
      _GetFileInformationByHandleExDart
    >('GetFileInformationByHandleEx');
final _CloseHandleDart _closeWindowsHandle = _windowsKernel32
    .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');

int? _tryGetWindowsFileChangeTime(File file) {
  if (!Platform.isWindows) return null;

  final path = file.path.toNativeUtf16();
  final handle = _createWindowsFile(
    path,
    0x80000000,
    0x00000007,
    nullptr,
    3,
    0x00000080,
    0,
  );
  calloc.free(path);
  if (handle == -1) return null;

  final info = calloc<_WindowsFileBasicInfo>();
  try {
    if (_getWindowsFileInformation(
          handle,
          0,
          info,
          sizeOf<_WindowsFileBasicInfo>(),
        ) ==
        0) {
      return null;
    }
    return info.ref.changeTime;
  } finally {
    calloc.free(info);
    _closeWindowsHandle(handle);
  }
}

class _RuntimeSourceSnapshot {
  const _RuntimeSourceSnapshot({
    required this.metadataFingerprint,
    required this.integrityHashes,
    required this.version,
  });

  final String metadataFingerprint;
  final Map<String, String> integrityHashes;
  final String version;
}

class _RuntimeValidationSnapshot {
  const _RuntimeValidationSnapshot({
    required this.sourceMetadataFingerprint,
    required this.runtimeMetadataFingerprint,
    required this.manifestReadMs,
    required this.integrityVerificationMs,
  });

  final String sourceMetadataFingerprint;
  final String runtimeMetadataFingerprint;
  final int manifestReadMs;
  final int integrityVerificationMs;
}

class AppRuntimeService {
  static final Map<String, Future<Directory>> _inFlightPreparations = {};
  static final Map<String, _RuntimeSourceSnapshot> _sourceSnapshots = {};
  static final Map<String, _RuntimeValidationSnapshot>
  _runtimeValidationSnapshots = {};
  static const int _runtimeManifestSchemaVersion = 3;

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
    final preparationKey = [
      _sourceDirectory.absolute.path.toLowerCase(),
      (runtimeBaseDirectory ?? _defaultRuntimeRoot()).absolute.path
          .toLowerCase(),
      _executableName.toLowerCase(),
      runtimeName,
      'hardLinks=$allowHardLinks',
    ].join('|');
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
        _prepareRuntimeWithLock(
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

  Directory _defaultRuntimeRoot() {
    final localAppData =
        Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    return Directory('$localAppData\\WallSync');
  }

  Future<Directory> _prepareRuntimeWithLock(
    String runtimeName, {
    required bool allowHardLinks,
  }) async {
    final runtimeParent = Directory(
      '${(runtimeBaseDirectory ?? _defaultRuntimeRoot()).path}\\$runtimeName',
    );
    await runtimeParent.create(recursive: true);

    // The OS releases this lock if a process exits unexpectedly. Keep the lock
    // file in place so waiters always coordinate on the same file.
    final lockFile = File('${runtimeParent.path}\\.prepare.lock');
    final lock = await lockFile.open(mode: FileMode.append);
    final waitStopwatch = Stopwatch()..start();
    var locked = false;
    try {
      const maxLockAttempts = 240;
      for (var attempt = 1; attempt <= maxLockAttempts; attempt++) {
        try {
          await lock.lock(FileLock.exclusive);
          locked = true;
          break;
        } on FileSystemException catch (error) {
          final code = error.osError?.errorCode;
          final message = error.message.toLowerCase();
          final isLockConflict =
              code == 32 ||
              code == 33 ||
              message.contains('sharing violation') ||
              message.contains('locked a portion of the file');
          if (!isLockConflict || attempt == maxLockAttempts) rethrow;
          await Future<void>.delayed(
            Duration(milliseconds: math.min(250, attempt * 20)),
          );
        }
      }
      if (!locked) {
        throw StateError(
          '$runtimeName preparation lock was not acquired after '
          '$maxLockAttempts attempts.',
        );
      }
      if (waitStopwatch.elapsedMilliseconds >= 50) {
        logPerf(
          'AppRuntimeService',
          '$runtimeName preparation lock acquired after '
              '${waitStopwatch.elapsedMilliseconds}ms.',
        );
      }
      return await _prepareRuntimeInternal(
        runtimeName,
        allowHardLinks: allowHardLinks,
      );
    } finally {
      try {
        if (locked) await lock.unlock();
      } finally {
        await lock.close();
      }
    }
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

    // Stat every entry to detect additions, removals, and metadata changes.
    // Expensive binary hashing is only repeated when this snapshot changes.
    final fingerprintStopwatch = Stopwatch()..start();
    final stats = await Future.wait(entries.map((e) => e.stat()));
    final sourceChangeTimes = await Future.wait(
      entries.map(
        (entity) async =>
            entity is File ? _tryGetWindowsFileChangeTime(entity) : null,
      ),
    );
    final sourceMetadataReliable =
        !Platform.isWindows ||
        entries.asMap().entries.every(
          (entry) =>
              entry.value is! File || sourceChangeTimes[entry.key] != null,
        );
    final metadataFingerprint = StringBuffer(
      'allowHardLinks=$allowHardLinks\n',
    );
    final sourceFileSizes = <String, int>{};
    final sourceFileModified = <String, int>{};
    var totalBytes = 0;
    for (var i = 0; i < entries.length; i++) {
      final entity = entries[i];
      final stat = stats[i];
      final relativePath = entity.path.substring(sourceDir.path.length);
      metadataFingerprint
        ..write(relativePath)
        ..write('|')
        ..write(stat.type)
        ..write('|')
        ..write(stat.size)
        ..write('|')
        ..write(stat.modified.microsecondsSinceEpoch)
        ..write('|')
        ..write(sourceChangeTimes[i] ?? stat.changed.microsecondsSinceEpoch)
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
    final sourceMetadataFingerprint = metadataFingerprint.toString();
    final sourceCacheKey = [
      sourceDir.absolute.path.toLowerCase(),
      runtimeName,
      executableName.toLowerCase(),
      'hardLinks=$allowHardLinks',
    ].join('|');
    final cachedSource = _sourceSnapshots[sourceCacheKey];
    final dependencyIntegrityPaths = sourceFileSizes.keys
        .where((path) {
          final lower = path.toLowerCase();
          return lower.endsWith('.exe') ||
              lower.endsWith('.dll') ||
              lower.endsWith('.so');
        })
        .toList(growable: false);
    final sourceIntegrityStopwatch = Stopwatch()..start();
    late final Map<String, String> sourceIntegrityHashes;
    late final String version;
    final sourceSnapshotHit =
        sourceMetadataReliable &&
        cachedSource != null &&
        cachedSource.metadataFingerprint == sourceMetadataFingerprint;
    if (sourceSnapshotHit) {
      sourceIntegrityHashes = cachedSource.integrityHashes;
      version = cachedSource.version;
      _sourceSnapshots.remove(sourceCacheKey);
      _sourceSnapshots[sourceCacheKey] = cachedSource;
    } else {
      late final List<String> integrityValues;
      try {
        integrityValues = await Future.wait(
          dependencyIntegrityPaths.map(
            (path) => _sha256File(File('${sourceDir.path}\\$path')),
          ),
        );
      } on FileSystemException {
        _sourceSnapshots.remove(sourceCacheKey);
        rethrow;
      }
      sourceIntegrityHashes = Map<String, String>.unmodifiable(
        Map<String, String>.fromIterables(
          dependencyIntegrityPaths,
          integrityValues,
        ),
      );
      final versionFingerprint = StringBuffer(sourceMetadataFingerprint);
      for (final entry in sourceIntegrityHashes.entries) {
        versionFingerprint
          ..write('integrity|')
          ..write(entry.key)
          ..write('|')
          ..write(entry.value)
          ..write('\n');
      }
      version = sha256
          .convert(utf8.encode(versionFingerprint.toString()))
          .toString();
      if (sourceMetadataReliable) {
        _sourceSnapshots[sourceCacheKey] = _RuntimeSourceSnapshot(
          metadataFingerprint: sourceMetadataFingerprint,
          integrityHashes: sourceIntegrityHashes,
          version: version,
        );
      } else {
        _sourceSnapshots.remove(sourceCacheKey);
      }
    }
    final sourceIntegrityMs = sourceIntegrityStopwatch.elapsedMilliseconds;
    final fingerprintMs = fingerprintStopwatch.elapsedMilliseconds;

    final runtimeRoot = runtimeBaseDirectory ?? _defaultRuntimeRoot();
    final runtimeParent = Directory('${runtimeRoot.path}\\$runtimeName');
    await runtimeParent.create(recursive: true);
    final canonicalRuntime = Directory('${runtimeParent.path}\\$version');
    final currentPointer = File('${runtimeParent.path}\\$version.current');
    if (await currentPointer.exists()) {
      try {
        final candidateName = (await currentPointer.readAsString()).trim();
        if (RegExp(
          '^${RegExp.escape(version)}-repair-[0-9]+-[0-9]+\$',
        ).hasMatch(candidateName)) {
          final repairedRuntime = Directory(
            '${runtimeParent.path}\\$candidateName',
          );
          if (await _isRuntimeCacheValid(
            repairedRuntime,
            runtimeName: runtimeName,
            version: version,
            executableName: executableName,
            allowHardLinks: allowHardLinks,
            sourceFileSizes: sourceFileSizes,
            sourceFileModified: sourceFileModified,
            sourceIntegrityHashes: sourceIntegrityHashes,
            sourceMetadataFingerprint: sourceMetadataFingerprint,
            totalBytes: totalBytes,
          )) {
            logPerf(
              'AppRuntimeService',
              '$runtimeName warm reuse confirmed in '
                  '${stopwatch.elapsedMilliseconds}ms '
                  '(runtimeReuse=true, sourceMetadataCacheHit='
                  '$sourceSnapshotHit, scan=${listingMs}ms, '
                  'metadata=${fingerprintMs}ms, sourceHashes=${sourceIntegrityMs}ms, '
                  'files=${sourceFileSizes.length}).',
            );
            return repairedRuntime;
          }
        }
      } on FileSystemException catch (error) {
        logWarning(
          'AppRuntimeService',
          '$runtimeName cache pointer could not be read; checking the '
              'canonical runtime instead: $error',
        );
      }
    }

    if (await _isRuntimeCacheValid(
      canonicalRuntime,
      runtimeName: runtimeName,
      version: version,
      executableName: executableName,
      allowHardLinks: allowHardLinks,
      sourceFileSizes: sourceFileSizes,
      sourceFileModified: sourceFileModified,
      sourceIntegrityHashes: sourceIntegrityHashes,
      sourceMetadataFingerprint: sourceMetadataFingerprint,
      totalBytes: totalBytes,
    )) {
      logPerf(
        'AppRuntimeService',
        '$runtimeName warm reuse confirmed in ${stopwatch.elapsedMilliseconds}ms '
            '(runtimeReuse=true, sourceMetadataCacheHit='
            '$sourceSnapshotHit, scan=${listingMs}ms, '
            'metadata=${fingerprintMs}ms, sourceHashes=${sourceIntegrityMs}ms, '
            'files=${sourceFileSizes.length}).',
      );
      return canonicalRuntime;
    }

    final canonicalExists = await canonicalRuntime.exists();
    if (canonicalExists) {
      logWarning(
        'AppRuntimeService',
        '$runtimeName cache inventory or file verification failed for '
            '$version; creating an isolated repair runtime.',
      );
    }
    final runtimeDir = canonicalExists
        ? Directory(
            '${runtimeParent.path}\\$version-repair-$pid-'
            '${DateTime.now().microsecondsSinceEpoch}',
          )
        : canonicalRuntime;
    final stagingDir = Directory(
      '${runtimeParent.path}\\.staging-$version-$pid-'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    final manifestFile = File('${stagingDir.path}\\runtime.manifest');

    final copyStopwatch = Stopwatch()..start();
    await _cleanupStaleStagingDirectories(runtimeParent);
    await stagingDir.create(recursive: true);

    try {
      for (final entity in entries.whereType<Directory>()) {
        final relativePath = entity.path.substring(sourceDir.path.length + 1);
        final destination = '${stagingDir.path}\\$relativePath';
        await Directory(destination).create(recursive: true);
      }

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
            final destination = '${stagingDir.path}\\$relativePath';
            final destFile = File(destination);
            final sourceSize = sourceFileSizes[relativePath] ?? 0;
            await Directory(destFile.parent.path).create(recursive: true);
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
        'schemaVersion': _runtimeManifestSchemaVersion,
        'version': version,
        'executableName': executableName,
        'allowHardLinks': allowHardLinks,
        'fileCount': sourceFileSizes.length,
        'totalBytes': totalBytes,
        'files': fileInventory,
        'integrity': sourceIntegrityHashes,
        'completedAt': DateTime.now().toIso8601String(),
      };
      await manifestFile.writeAsString(
        jsonEncode(manifestPayload),
        flush: true,
      );
      await stagingDir.rename(runtimeDir.path);
      if (runtimeDir.path != canonicalRuntime.path) {
        final temporaryPointer = File(
          '${currentPointer.path}.$pid.'
          '${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        await temporaryPointer.writeAsString(
          runtimeDir.path.split(Platform.pathSeparator).last,
          flush: true,
        );
        if (await currentPointer.exists()) await currentPointer.delete();
        await temporaryPointer.rename(currentPointer.path);
      }

      logPerf(
        'AppRuntimeService',
        '$runtimeName runtime sync completed in ${copyStopwatch.elapsedMilliseconds}ms '
            '(total ${stopwatch.elapsedMilliseconds}ms; synced $copiedCount/${files.length} files, '
            '${(copiedBytes / (1024 * 1024)).toStringAsFixed(1)}MB copied).',
      );

      return runtimeDir;
    } catch (error) {
      if (await stagingDir.exists()) {
        try {
          await stagingDir.delete(recursive: true);
        } on FileSystemException catch (cleanupError) {
          logWarning(
            'AppRuntimeService',
            'Could not remove incomplete staging runtime '
                '${stagingDir.path}: $cleanupError',
          );
        }
      }
      logError('AppRuntimeService', 'Failed to prepare runtime: $error');
      rethrow;
    }
  }

  Future<bool> _isRuntimeCacheValid(
    Directory runtimeDir, {
    required String runtimeName,
    required String version,
    required String executableName,
    required bool allowHardLinks,
    required Map<String, int> sourceFileSizes,
    required Map<String, int> sourceFileModified,
    required Map<String, String> sourceIntegrityHashes,
    required String sourceMetadataFingerprint,
    required int totalBytes,
  }) async {
    final validationStopwatch = Stopwatch()..start();
    final runtimeCacheKey =
        '${runtimeDir.absolute.path.toLowerCase()}|$version';
    final runtimeExecutable = File('${runtimeDir.path}\\$executableName');
    final manifestFile = File('${runtimeDir.path}\\runtime.manifest');
    if (!await runtimeExecutable.exists() || !await manifestFile.exists()) {
      _runtimeValidationSnapshots.remove(runtimeCacheKey);
      return false;
    }
    try {
      final manifestReadStopwatch = Stopwatch()..start();
      final decoded = jsonDecode(await manifestFile.readAsString());
      final manifestReadMs = manifestReadStopwatch.elapsedMilliseconds;
      if (decoded is! Map<String, dynamic>) {
        _runtimeValidationSnapshots.remove(runtimeCacheKey);
        return false;
      }
      final manifestFiles = decoded['files'];
      final manifestIntegrity = decoded['integrity'];
      var filesMatch =
          manifestFiles is Map &&
          manifestFiles.length == sourceFileSizes.length &&
          manifestIntegrity is Map &&
          manifestIntegrity.length == sourceIntegrityHashes.length &&
          decoded['schemaVersion'] == _runtimeManifestSchemaVersion &&
          decoded['executableName'] == executableName &&
          decoded['version'] == version &&
          decoded['allowHardLinks'] == allowHardLinks &&
          decoded['fileCount'] == sourceFileSizes.length &&
          decoded['totalBytes'] == totalBytes;
      if (!filesMatch) {
        _runtimeValidationSnapshots.remove(runtimeCacheKey);
        return false;
      }

      for (final entry in sourceIntegrityHashes.entries) {
        if (manifestIntegrity[entry.key] != entry.value) {
          _runtimeValidationSnapshots.remove(runtimeCacheKey);
          return false;
        }
      }

      final manifestStat = await manifestFile.stat();
      final manifestChangeTime = _tryGetWindowsFileChangeTime(manifestFile);
      final fileStatStopwatch = Stopwatch()..start();
      final fileStats = await Future.wait(
        sourceFileSizes.entries.map((entry) async {
          final fileMetadata = manifestFiles[entry.key];
          if (fileMetadata is! Map ||
              fileMetadata['size'] != entry.value ||
              fileMetadata['modified'] != sourceFileModified[entry.key]) {
            return (matches: false, stat: null, changeTime: null);
          }
          try {
            final runtimeFile = File('${runtimeDir.path}\\${entry.key}');
            final runtimeStat = await runtimeFile.stat();
            return (
              matches:
                  runtimeStat.type == FileSystemEntityType.file &&
                  runtimeStat.size == entry.value &&
                  runtimeStat.modified.microsecondsSinceEpoch ==
                      sourceFileModified[entry.key],
              stat: runtimeStat,
              changeTime: _tryGetWindowsFileChangeTime(runtimeFile),
            );
          } on FileSystemException {
            return (matches: false, stat: null, changeTime: null);
          }
        }),
      );
      final fileStatsMs = fileStatStopwatch.elapsedMilliseconds;
      if (!fileStats.every((result) => result.matches)) {
        _runtimeValidationSnapshots.remove(runtimeCacheKey);
        return false;
      }

      final runtimeMetadataFingerprint = StringBuffer()
        ..write('${manifestStat.size}|')
        ..write(manifestStat.modified.microsecondsSinceEpoch)
        ..write('|')
        ..write(
          manifestChangeTime ?? manifestStat.changed.microsecondsSinceEpoch,
        )
        ..write('\n');
      for (var index = 0; index < sourceFileSizes.length; index++) {
        final entry = sourceFileSizes.entries.elementAt(index);
        final stat = fileStats[index].stat!;
        runtimeMetadataFingerprint
          ..write(entry.key)
          ..write('|')
          ..write(stat.size)
          ..write('|')
          ..write(stat.modified.microsecondsSinceEpoch)
          ..write('|')
          ..write(
            fileStats[index].changeTime ?? stat.changed.microsecondsSinceEpoch,
          )
          ..write('\n');
      }
      final runtimeMetadataReliable =
          !Platform.isWindows ||
          manifestChangeTime != null &&
              fileStats.every((result) => result.changeTime != null);
      final runtimeSnapshot = _runtimeValidationSnapshots[runtimeCacheKey];
      final runtimeMetadata = runtimeMetadataFingerprint.toString();
      if (runtimeMetadataReliable &&
          runtimeSnapshot != null &&
          runtimeSnapshot.sourceMetadataFingerprint ==
              sourceMetadataFingerprint &&
          runtimeSnapshot.runtimeMetadataFingerprint == runtimeMetadata) {
        logPerf(
          'AppRuntimeService',
          '$runtimeName runtime integrity cache hit in '
              '${validationStopwatch.elapsedMilliseconds}ms '
              '(manifestRead=${manifestReadMs}ms, fileStats=${fileStatsMs}ms, '
              'previousManifestRead=${runtimeSnapshot.manifestReadMs}ms, '
              'previousHashVerification='
              '${runtimeSnapshot.integrityVerificationMs}ms, '
              'hashes=skipped; metadata unchanged).',
        );
        return true;
      }

      final integrityStopwatch = Stopwatch()..start();
      final integrityChecks = await Future.wait(
        sourceIntegrityHashes.entries.map((entry) async {
          try {
            return await _sha256File(
                  File('${runtimeDir.path}\\${entry.key}'),
                ) ==
                entry.value;
          } on FileSystemException {
            return false;
          }
        }),
      );
      if (!integrityChecks.every((matches) => matches)) {
        _runtimeValidationSnapshots.remove(runtimeCacheKey);
        return false;
      }
      if (runtimeMetadataReliable) {
        _runtimeValidationSnapshots.removeWhere(
          (key, _) =>
              key.startsWith('${runtimeDir.absolute.path.toLowerCase()}|'),
        );
        _runtimeValidationSnapshots[runtimeCacheKey] =
            _RuntimeValidationSnapshot(
              sourceMetadataFingerprint: sourceMetadataFingerprint,
              runtimeMetadataFingerprint: runtimeMetadata,
              manifestReadMs: manifestReadMs,
              integrityVerificationMs: integrityStopwatch.elapsedMilliseconds,
            );
      } else {
        _runtimeValidationSnapshots.remove(runtimeCacheKey);
      }
      logPerf(
        'AppRuntimeService',
        '$runtimeName runtime integrity verified in '
            '${validationStopwatch.elapsedMilliseconds}ms '
            '(manifestAndStats=${manifestReadMs}ms, '
            'hashes=${integrityStopwatch.elapsedMilliseconds}ms).',
      );
      return true;
    } on FormatException catch (error) {
      _runtimeValidationSnapshots.remove(runtimeCacheKey);
      logWarning(
        'AppRuntimeService',
        '$runtimeName cache manifest is malformed at ${manifestFile.path}: '
            '$error',
      );
      return false;
    } on FileSystemException catch (error) {
      _runtimeValidationSnapshots.remove(runtimeCacheKey);
      logWarning(
        'AppRuntimeService',
        '$runtimeName cache could not be validated at ${runtimeDir.path}: '
            '$error',
      );
      return false;
    }
  }

  Future<String> _sha256File(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<void> _cleanupStaleStagingDirectories(Directory runtimeParent) async {
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    await for (final entity in runtimeParent.list(followLinks: false)) {
      if (entity is! Directory ||
          !entity.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('.staging-')) {
        continue;
      }
      try {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete(recursive: true);
        }
      } on FileSystemException catch (error) {
        logWarning(
          'AppRuntimeService',
          'Could not clean stale staging directory ${entity.path}: $error',
        );
      }
    }
  }
}
