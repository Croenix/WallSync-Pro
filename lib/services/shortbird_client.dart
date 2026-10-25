import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';
import 'settings_service.dart';

class ShortbirdClient {
  static final ShortbirdClient _instance = ShortbirdClient._internal();
  factory ShortbirdClient() => _instance;
  ShortbirdClient._internal();

  ShorebirdUpdater? _updater;
  bool _isInitialized = false;
  String _currentPatch = 'none';
  bool _isChecking = false;

  bool get isInitialized => _isInitialized;
  String get currentPatch => _currentPatch;

  /// Initializes the Shortbird push update client and reads the current patch.
  Future<void> init() async {
    if (_isInitialized) return;
    logInfo('ShortbirdClient', 'Initializing Shorebird push update engine...');

    // Shorebird code push is only available and active in Release builds.
    // Bypassing it in debug/profile modes prevents FFI symbol lookup exceptions that pause the IDE debugger.
    if (!kReleaseMode) {
      logInfo(
        'ShortbirdClient',
        'Shorebird is only active in Release mode. Bypassing initialization in debug/profile mode.',
      );
      _currentPatch = 'none';
      _isInitialized = true;
      return;
    }

    try {
      // Instantiate ShorebirdUpdater inside the try-catch block to handle any constructor-level FFI errors safely
      final updaterInstance = ShorebirdUpdater();
      _updater = updaterInstance;

      if (!updaterInstance.isAvailable) {
        logInfo(
          'ShortbirdClient',
          'Shorebird engine is not available in this build configuration.',
        );
        _currentPatch = 'none';
        _isInitialized = true;
        return;
      }

      final current = await updaterInstance.readCurrentPatch();
      if (current != null) {
        _currentPatch = 'Patch ${current.number}';
        logInfo('ShortbirdClient', 'Current active patch: $_currentPatch');
      } else {
        _currentPatch = 'none';
        logInfo('ShortbirdClient', 'No active patch detected.');
      }
    } catch (e, st) {
      logError(
        'ShortbirdClient',
        'Failed to initialize Shorebird updater',
        e,
        st,
      );
      _currentPatch = 'none';
    }

    _isInitialized = true;
    logInfo(
      'ShortbirdClient',
      'Shorebird push update engine initialized successfully.',
    );

    // Automatically start a background check
    checkForUpdatesSilently();
  }

  /// Checks for push updates in the background.
  Future<void> checkForUpdatesSilently() async {
    try {
      if (!kReleaseMode || _updater == null) {
        return;
      }
      final updaterInstance = _updater!;
      if (!updaterInstance.isAvailable) {
        logInfo(
          'ShortbirdClient',
          'Shorebird engine is not available. Skipping background update check.',
        );
        return;
      }

      logInfo('ShortbirdClient', 'Checking for push updates in background...');
      final status = await updaterInstance.checkForUpdate();
      logInfo(
        'ShortbirdClient',
        'Background update check complete. Status: $status',
      );
    } catch (e, st) {
      logError('ShortbirdClient', 'Background update check failed', e, st);
    }
  }

  /// Programmatically checks for updates.
  Future<bool> checkForUpdates() async {
    if (!_isInitialized) {
      await init();
    }
    if (!kReleaseMode || _updater == null) {
      return false;
    }
    final updaterInstance = _updater!;
    if (!updaterInstance.isAvailable) {
      logInfo(
        'ShortbirdClient',
        'Shorebird engine is not available. Skipping programmatic update check.',
      );
      return false;
    }
    if (_isChecking) return false;
    _isChecking = true;
    logInfo('ShortbirdClient', 'Programmatic update check initiated.');

    try {
      final status = await updaterInstance.checkForUpdate();
      logInfo(
        'ShortbirdClient',
        'Programmatic update check complete. Status: $status',
      );

      _isChecking = false;
      return status == UpdateStatus.outdated;
    } catch (e, st) {
      logError('ShortbirdClient', 'Update check failed', e, st);
      _isChecking = false;
      return false;
    }
  }
}
