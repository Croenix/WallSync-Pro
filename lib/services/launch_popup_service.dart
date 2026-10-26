import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../config/api.dart';
import '../widgets/launch_popup_dialog.dart';
import 'settings_service.dart';

/// Configuration model representing the promotional launch poster popup.
class LaunchPopupConfig {
  final bool enabled;
  final String imageUrl;
  final String actionText;
  final String actionUrl;
  final String id;
  final int updatedAt;

  const LaunchPopupConfig({
    required this.enabled,
    required this.imageUrl,
    this.actionText = 'Continue',
    this.actionUrl = '',
    this.id = 'popup_default',
    this.updatedAt = 0,
  });

  factory LaunchPopupConfig.fromJson(Map<String, dynamic> json) {
    return LaunchPopupConfig(
      enabled: json['enabled'] == true,
      imageUrl: (json['imageUrl'] ?? '').toString().trim(),
      actionText: (json['actionText'] != null &&
              json['actionText'].toString().trim().isNotEmpty)
          ? json['actionText'].toString().trim()
          : 'Continue',
      actionUrl: (json['actionUrl'] ?? '').toString().trim(),
      id: (json['id'] ?? 'popup_default').toString(),
      updatedAt: json['updatedAt'] is int
          ? json['updatedAt'] as int
          : (int.tryParse(json['updatedAt']?.toString() ?? '') ?? 0),
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'imageUrl': imageUrl,
    'actionText': actionText,
    'actionUrl': actionUrl,
    'id': id,
    'updatedAt': updatedAt,
  };
}

/// Service that coordinates the one-time promotional launch poster popup with the
/// WallSync Admin Panel.
///
/// Strict rules enforced:
/// 1. Only displays once per application open/session.
/// 2. If the Admin Panel status is disabled, the popup is NEVER shown.
/// 3. If there is NO connection to the Admin Panel API (offline/server down),
///    the popup is NEVER shown.
class LaunchPopupService {
  LaunchPopupService._();
  static final LaunchPopupService instance = LaunchPopupService._();

  bool _hasShownThisSession = false;
  bool get hasShownThisSession => _hasShownThisSession;

  /// Visible for testing to reset the one-time session guard.
  @visibleForTesting
  void resetSessionForTesting() {
    _hasShownThisSession = false;
  }

  /// Fetches the latest popup configuration directly from the Admin Panel API.
  ///
  /// Returns null if:
  /// - Admin Panel is offline or unreachable
  /// - The popup is disabled in Admin Panel (`enabled == false`)
  /// - The poster image URL is empty
  Future<LaunchPopupConfig?> fetchConfig({HttpClient? customClient}) async {
    // 1. Primary: Query the active Admin Panel Node.js backend
    final configFromApi = await _fetchFromEndpoint(
      ApiConfig.popupEndpoint,
      customClient: customClient,
    );
    if (configFromApi != null) {
      if (!configFromApi.enabled || configFromApi.imageUrl.isEmpty) {
        return null;
      }
      return configFromApi;
    }

    // 2. Secondary Fallback: Query Firebase Realtime Database /popup_pro.json
    final rtdbPopupUrl =
        '${ApiConfig.defaultRtdbUrl}/popup_pro.json';
    final configFromRtdb = await _fetchFromEndpoint(
      rtdbPopupUrl,
      customClient: customClient,
      isRtdb: true,
    );
    if (configFromRtdb != null) {
      if (!configFromRtdb.enabled || configFromRtdb.imageUrl.isEmpty) {
        return null;
      }
      return configFromRtdb;
    }

    // Not connected to Admin Panel or API — do not show
    logInfo(
      'LaunchPopupService',
      'No active connection to Admin Panel API or popup is disabled. Popup suppressed.',
    );
    return null;
  }

  Future<LaunchPopupConfig?> _fetchFromEndpoint(
    String endpoint, {
    HttpClient? customClient,
    bool isRtdb = false,
  }) async {
    HttpClient? client;
    try {
      client = customClient ?? (HttpClient()..connectionTimeout = const Duration(seconds: 4));
      final uri = Uri.parse(endpoint);
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 4));
      final res = await req.close().timeout(const Duration(seconds: 4));

      if (res.statusCode == 200) {
        final bodyStr = await res.transform(utf8.decoder).join().timeout(
          const Duration(seconds: 4),
        );
        final data = jsonDecode(bodyStr);
        if (data is Map<String, dynamic>) {
          if (isRtdb) {
            return LaunchPopupConfig.fromJson(data);
          } else if (data['popup'] is Map<String, dynamic>) {
            return LaunchPopupConfig.fromJson(
              Map<String, dynamic>.from(data['popup'] as Map),
            );
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      if (customClient == null) {
        client?.close(force: true);
      }
    }
  }

  /// Evaluates whether to show the popup and presents the dialog once on launch.
  Future<void> checkAndShowPopup(BuildContext context) async {
    // Rule: One-time per application launch session
    if (_hasShownThisSession) {
      return;
    }

    final config = await fetchConfig();
    if (config == null || !config.enabled || config.imageUrl.isEmpty) {
      return;
    }

    if (!context.mounted) {
      return;
    }

    _hasShownThisSession = true;
    logInfo(
      'LaunchPopupService',
      'Presenting launch poster popup: "${config.id}" (Image: ${config.imageUrl})',
    );

    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss promotional popup',
      barrierColor: Colors.black.withValues(alpha: 0.75),
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        return LaunchPopupDialog(config: config);
      },
      transitionBuilder: (dialogContext, animation, secondaryAnimation, child) {
        final curvedValue = Curves.easeOutBack.transform(animation.value);
        return Transform.scale(
          scale: 0.85 + (0.15 * curvedValue),
          child: Opacity(
            opacity: animation.value.clamp(0.0, 1.0),
            child: child,
          ),
        );
      },
    );
  }
}
