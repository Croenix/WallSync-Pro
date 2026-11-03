import 'dart:io';

import 'package:flutter/services.dart';

class TaskbarAppBarConfiguration {
  const TaskbarAppBarConfiguration({
    required this.hwnd,
    required this.ownerPid,
    required this.revision,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final int hwnd;
  final int ownerPid;
  final int revision;
  final int left;
  final int top;
  final int right;
  final int bottom;
}

class TaskbarConfigurationService {
  static int _latestRevision = 0;

  TaskbarConfigurationService({
    MethodChannel channel = const MethodChannel('wallsync/live_wallpaper'),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<TaskbarAppBarConfiguration> applyNativeDock({
    required String edge,
    required int thickness,
    required int length,
    required bool autoHide,
    required int revision,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError(
        'Native taskbar AppBars are only available on Windows.',
      );
    }
    if (!const {'top', 'bottom', 'left', 'right'}.contains(edge)) {
      throw ArgumentError.value(edge, 'edge', 'Unsupported taskbar edge.');
    }
    if (thickness < 24 || thickness > 256) {
      throw RangeError.range(thickness, 24, 256, 'thickness');
    }
    if (length != 0 && length < 120) {
      throw RangeError.range(length, 120, null, 'length');
    }
    if (revision < 1) {
      throw RangeError.value(revision, 'revision', 'Must be positive.');
    }
    final requestedRevision = revision > _latestRevision
        ? revision
        : _latestRevision + 1;
    _latestRevision = requestedRevision;

    final response = await _channel
        .invokeMapMethod<String, dynamic>('configureTaskbarAppBar', {
          'edge': edge,
          'thickness': thickness,
          'length': length,
          'autoHide': autoHide,
          'revision': requestedRevision,
        });
    if (response == null || response['success'] != true) {
      final error = response == null
          ? 'No response from the native host.'
          : response['error'] ?? 'The native host rejected the configuration.';
      throw StateError(
        'Windows could not apply the taskbar AppBar configuration: '
        '$error',
      );
    }

    final hwnd = (response['hwnd'] as num?)?.toInt() ?? 0;
    final ownerPid = (response['ownerPid'] as num?)?.toInt() ?? 0;
    final confirmedRevision =
        (response['appliedRevision'] as num?)?.toInt() ?? 0;
    final bounds = (
      left: (response['left'] as num?)?.toInt() ?? 0,
      top: (response['top'] as num?)?.toInt() ?? 0,
      right: (response['right'] as num?)?.toInt() ?? 0,
      bottom: (response['bottom'] as num?)?.toInt() ?? 0,
    );
    if (hwnd == 0 || ownerPid != pid) {
      throw StateError(
        'AppBar configuration returned an invalid host HWND or owner PID.',
      );
    }
    if (confirmedRevision != requestedRevision) {
      throw StateError(
        'AppBar acknowledged revision $confirmedRevision instead of '
        '$requestedRevision.',
      );
    }
    if (bounds.right <= bounds.left || bounds.bottom <= bounds.top) {
      throw StateError('AppBar configuration returned invalid window bounds.');
    }

    _latestRevision = confirmedRevision;
    return TaskbarAppBarConfiguration(
      hwnd: hwnd,
      ownerPid: ownerPid,
      revision: confirmedRevision,
      left: bounds.left,
      top: bounds.top,
      right: bounds.right,
      bottom: bounds.bottom,
    );
  }
}
