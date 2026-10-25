import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_service.dart';

/// Information describing a validated, bundled MPV runtime executable.
class MpvRuntimeInfo {
  final String path;
  final String executableDirectory;
  final String architecture;
  final int fileSizeBytes;
  final bool hasD3DCompiler;
  final String mode;

  const MpvRuntimeInfo({
    required this.path,
    required this.executableDirectory,
    required this.architecture,
    required this.fileSizeBytes,
    required this.hasD3DCompiler,
    required this.mode,
  });

  @override
  String toString() =>
      'MpvRuntimeInfo(path: $path, arch: $architecture, size: $fileSizeBytes, '
      'hasD3DCompiler: $hasD3DCompiler, mode: $mode)';
}

/// Typed exception thrown when the bundled MPV runtime cannot be resolved or is invalid.
class MpvRuntimeMissingException implements Exception {
  final String userFacingMessage;
  final String diagnostics;
  final String? expectedPath;

  const MpvRuntimeMissingException({
    required this.userFacingMessage,
    required this.diagnostics,
    this.expectedPath,
  });

  @override
  String toString() => userFacingMessage;
}

/// Centralized resolver for the bundled MPV runtime in WallSync.
///
/// Ensures video wallpaper playback and thumbnail extraction use the exact same
/// bundled executable without requiring separate installations or guessing paths.
class MpvRuntimeResolver {
  MpvRuntimeResolver._();

  static final MpvRuntimeResolver instance = MpvRuntimeResolver._();
  static const _configuredPathKey = 'mpv_executable_path';

  MpvRuntimeInfo? _cachedInfo;
  bool _hasCachedResult = false;
  Future<MpvRuntimeInfo>? _inFlightResolution;
  String _lastFailureDiagnostics = '';

  String get lastFailureDiagnostics => _lastFailureDiagnostics;
  MpvRuntimeInfo? get cachedInfo => _cachedInfo;

  /// Resolves and validates the bundled MPV executable runtime.
  ///
  /// Throws [MpvRuntimeMissingException] if no valid bundled runtime is found.
  Future<MpvRuntimeInfo> resolve({
    bool refresh = false,
    @visibleForTesting List<String>? candidateOverrides,
  }) async {
    if (!refresh && _hasCachedResult) {
      final info = _cachedInfo;
      if (info != null) {
        return info;
      }
    }

    if (!refresh && _inFlightResolution != null) {
      return _inFlightResolution!;
    }

    late final Future<MpvRuntimeInfo> operation;
    operation = _resolveInternal(
      refresh: refresh,
      candidateOverrides: candidateOverrides,
    ).whenComplete(() {
      if (identical(_inFlightResolution, operation)) {
        _inFlightResolution = null;
      }
    });
    _inFlightResolution = operation;
    return operation;
  }

  Future<MpvRuntimeInfo> _resolveInternal({
    bool refresh = false,
    @visibleForTesting List<String>? candidateOverrides,
  }) async {
    final stopwatch = Stopwatch()..start();
    String? configuredPath;
    try {
      final preferences = await SharedPreferences.getInstance();
      configuredPath = preferences.getString(_configuredPathKey)?.trim();
    } catch (_) {
      // In test environments where SharedPreferences is not mocked
    }
    final environmentPath = Platform.environment['WALLSYNC_MPV_PATH']?.trim();

    final candidates =
        candidateOverrides ??
        _candidatePaths(
          configuredPath: configuredPath,
          environmentPath: environmentPath,
          executablePath: Platform.resolvedExecutable,
          currentDirectory: Directory.current.path,
          environment: Platform.environment,
        );

    final mode = kDebugMode
        ? 'Debug'
        : kProfileMode
        ? 'Profile'
        : 'Release';
    final checks = <String>[];
    final expectedPath = candidates.isNotEmpty ? candidates.first : null;

    logInfo(
      'MpvRuntimeResolver',
      'Beginning MPV runtime resolution: mode=$mode; '
      'appDirectory=${File(Platform.resolvedExecutable).parent.path}; '
      'configuredOverride=${_logPath(configuredPath)}; '
      'envOverride=${_logPath(environmentPath)}; '
      'candidatesChecked=${candidates.length}.',
    );

    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      final failure = await _readabilityFailure(candidate);
      checks.add('[#${i + 1}] $candidate -> ${failure ?? "OK"}');

      if (failure == null) {
        final file = File(candidate);
        final absPath = file.absolute.path;
        final parentDir = file.parent.path;
        final fileSize = await file.length();
        final arch = await _detectArchitecture(file);
        final d3dFile = File(_join(parentDir, 'd3dcompiler_43.dll'));
        final hasD3D = await d3dFile.exists();

        final runtimeInfo = MpvRuntimeInfo(
          path: absPath,
          executableDirectory: parentDir,
          architecture: arch,
          fileSizeBytes: fileSize,
          hasD3DCompiler: hasD3D,
          mode: mode,
        );

        _cachedInfo = runtimeInfo;
        _hasCachedResult = true;
        _lastFailureDiagnostics = '';

        logInfo(
          'MpvRuntimeResolver',
          'Selected bundled MPV runtime: path=$absPath; arch=$arch; '
          'size=$fileSize bytes; hasD3DCompiler=$hasD3D; mode=$mode; '
          'lookupElapsed=${stopwatch.elapsedMilliseconds}ms.',
        );
        return runtimeInfo;
      }
    }

    _cachedInfo = null;
    _hasCachedResult = true;
    _lastFailureDiagnostics =
        'Mode: $mode | Elapsed: ${stopwatch.elapsedMilliseconds}ms | '
        'Expected bundled path: $expectedPath | Checks:\n${checks.join('\n')}';

    logWarning(
      'MpvRuntimeResolver',
      'Bundled MPV runtime not found. Checks performed:\n${checks.join('\n')}',
    );

    throw MpvRuntimeMissingException(
      userFacingMessage:
          'Built-in video wallpaper engine (MPV) was not found in the application directory. '
          'Please reinstall or update WallSync.',
      diagnostics: _lastFailureDiagnostics,
      expectedPath: expectedPath,
    );
  }

  /// Convenience method that returns the resolved absolute path or throws [MpvRuntimeMissingException].
  Future<String> requireExecutablePath({
    bool refresh = false,
    @visibleForTesting List<String>? candidateOverrides,
  }) async {
    final info = await resolve(
      refresh: refresh,
      candidateOverrides: candidateOverrides,
    );
    return info.path;
  }

  /// Convenience method for non-throwing lookup (used by background thumbnail extractor).
  Future<String?> findExecutablePath({
    bool refresh = false,
    @visibleForTesting List<String>? candidateOverrides,
  }) async {
    try {
      final info = await resolve(
        refresh: refresh,
        candidateOverrides: candidateOverrides,
      );
      return info.path;
    } on MpvRuntimeMissingException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Configures a custom MPV path for debugging or testing.
  Future<void> setConfiguredPath(String? path) async {
    final normalized = path?.trim();
    final preferences = await SharedPreferences.getInstance();
    if (normalized == null || normalized.isEmpty) {
      await preferences.remove(_configuredPathKey);
    } else {
      await preferences.setString(_configuredPathKey, normalized);
    }
    invalidateCache();
  }

  /// Clears the cached resolution result.
  void invalidateCache() {
    _cachedInfo = null;
    _hasCachedResult = false;
    _lastFailureDiagnostics = '';
  }

  @visibleForTesting
  static List<String> candidatePathsForTesting({
    String? configuredPath,
    String? environmentPath,
    required String executablePath,
    required String currentDirectory,
    required Map<String, String> environment,
  }) => _candidatePaths(
    configuredPath: configuredPath,
    environmentPath: environmentPath,
    executablePath: executablePath,
    currentDirectory: currentDirectory,
    environment: environment,
  );

  static List<String> _candidatePaths({
    String? configuredPath,
    String? environmentPath,
    required String executablePath,
    required String currentDirectory,
    required Map<String, String> environment,
  }) {
    final executableDirectory = File(executablePath).parent.path;
    final parentExecutableDirectory = Directory(executableDirectory).parent.path;

    final candidates = <String>[
      // 1. Explicit environment or test override
      if (environmentPath != null && environmentPath.isNotEmpty)
        environmentPath,
      if (configuredPath != null && configuredPath.isNotEmpty) configuredPath,

      // 2. Primary bundled application locations (Release / Installed / Debug)
      _join(executableDirectory, 'plugins', 'mpv', 'mpv.exe'),
      _join(executableDirectory, 'runtime', 'mpv', 'mpv.exe'),
      _join(executableDirectory, 'mpv.exe'),

      // 3. Parent directory of binary (e.g. runner subdirectory)
      _join(parentExecutableDirectory, 'plugins', 'mpv', 'mpv.exe'),
      _join(parentExecutableDirectory, 'runtime', 'mpv', 'mpv.exe'),
      _join(parentExecutableDirectory, 'mpv.exe'),

      // 4. Project workspace root during development
      _join(currentDirectory, 'plugins', 'mpv', 'mpv.exe'),
      _join(currentDirectory, 'runtime', 'mpv', 'mpv.exe'),
      _join(currentDirectory, 'mpv.exe'),

      // 5. LocalAppData fallback (installed app directory)
      if (environment['LOCALAPPDATA']?.isNotEmpty ?? false) ...[
        _join(
          environment['LOCALAPPDATA']!,
          'WallSync',
          'plugins',
          'mpv',
          'mpv.exe',
        ),
        _join(
          environment['LOCALAPPDATA']!,
          'WallSync',
          'runtime',
          'mpv',
          'mpv.exe',
        ),
      ],
    ];

    final seen = <String>{};
    return candidates
        .where((candidate) {
          final key = File(candidate).absolute.path.toLowerCase();
          return seen.add(key);
        })
        .toList(growable: false);
  }

  static String _join(
    String first,
    String second, [
    String? third,
    String? fourth,
    String? fifth,
  ]) {
    return [
      first,
      second,
      ?third,
      ?fourth,
      ?fifth,
    ].join(Platform.pathSeparator);
  }

  static Future<String?> _readabilityFailure(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return 'missing (file does not exist)';
      final size = await file.length();
      if (size == 0) return 'empty (file size is 0 bytes)';
      final handle = await file.open(mode: FileMode.read);
      await handle.close();
      return null;
    } on FileSystemException catch (error) {
      return 'inaccessible (OS error ${error.osError?.errorCode ?? 'unknown'}: ${error.message})';
    } catch (e) {
      return 'error: $e';
    }
  }

  static Future<String> _detectArchitecture(File file) async {
    try {
      final raf = await file.open(mode: FileMode.read);
      try {
        final header = await raf.read(64);
        if (header.length >= 64 && header[0] == 0x4d && header[1] == 0x5a) {
          final peOffset =
              header[0x3c] |
              (header[0x3d] << 8) |
              (header[0x3e] << 16) |
              (header[0x3f] << 24);
          await raf.setPosition(peOffset);
          final peSig = await raf.read(4);
          if (peSig.length == 4 &&
              peSig[0] == 0x50 &&
              peSig[1] == 0x45 &&
              peSig[2] == 0 &&
              peSig[3] == 0) {
            final coff = await raf.read(20);
            final machine = coff[0] | (coff[1] << 8);
            if (machine == 0x8664) return 'x64';
            if (machine == 0x014c) return 'x86';
            if (machine == 0xaa64) return 'arm64';
            return '0x${machine.toRadixString(16)}';
          }
        }
      } finally {
        await raf.close();
      }
    } catch (_) {}
    return 'unknown';
  }

  static String _logPath(String? path) =>
      path == null || path.isEmpty ? '<not configured>' : path;
}
