import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'settings_service.dart';

/// Representation of an incoming or broadcast push notification.
class AppNotification {
  final String id;
  final String title;
  final String message;
  final String type; // 'update' | 'wallpaper' | 'announcement' | 'info'
  final String? version;
  final String? actionUrl;
  final int timestamp;

  const AppNotification({
    required this.id,
    required this.title,
    required this.message,
    this.type = 'update',
    this.version,
    this.actionUrl,
    required this.timestamp,
  });

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    return AppNotification(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? 'WallSync Notification').toString(),
      message: (json['message'] ?? '').toString(),
      type: (json['type'] ?? 'update').toString(),
      version: json['version']?.toString(),
      actionUrl: json['actionUrl']?.toString() ?? json['url']?.toString(),
      timestamp: json['timestamp'] is int
          ? json['timestamp'] as int
          : (int.tryParse(json['timestamp']?.toString() ?? '') ??
                DateTime.now().millisecondsSinceEpoch),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'message': message,
    'type': type,
    'version': version,
    'actionUrl': actionUrl,
    'timestamp': timestamp,
  };
}

/// Service that handles native Windows Desktop Notifications and synchronization
/// with the WallSync admin backend push notification system.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const String _prefLastSeenKey = 'wallsync_last_seen_notification_id';
  String? _lastSeenId;
  bool _initialized = false;
  File? _cachedToastScript;
  bool isTestMode = false;

  final _notificationStreamCtrl = StreamController<AppNotification>.broadcast();

  /// Stream of new notifications for foreground UI listeners
  Stream<AppNotification> get onNotification => _notificationStreamCtrl.stream;

  /// Initializes the notification service and loads last seen notification ID
  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _lastSeenId = prefs.getString(_prefLastSeenKey);
      _initialized = true;
      logInfo(
        'NotificationService',
        'Notification service initialized. Last seen ID: $_lastSeenId',
      );

      // Prepare toast helper script on Windows
      if (Platform.isWindows && !isTestMode) {
        unawaited(_ensureToastScriptExists());
      }
    } catch (e, st) {
      logError(
        'NotificationService',
        'Failed to initialize NotificationService',
        e,
        st,
      );
    }
  }

  /// Ensures a helper PowerShell script exists in AppData for reliable toasts
  Future<File?> _ensureToastScriptExists() async {
    if (_cachedToastScript != null && await _cachedToastScript!.exists()) {
      return _cachedToastScript;
    }

    try {
      final localAppData =
          Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['APPDATA'] ??
          Directory.systemTemp.path;
      final scriptDir = Directory('$localAppData\\WallSync\\scripts');
      if (!await scriptDir.exists()) {
        await scriptDir.create(recursive: true);
      }

      final scriptFile = File('${scriptDir.path}\\send_toast.ps1');
      const scriptCode = r'''
param(
    [string]$Title = "WallSync",
    [string]$Message = ""
)

try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    $textNodes = $template.GetElementsByTagName("text")
    if ($textNodes.Count -gt 0) {
        $textNodes.Item(0).AppendChild($template.CreateTextNode($Title)) | Out-Null
    }
    if ($textNodes.Count -gt 1) {
        $textNodes.Item(1).AppendChild($template.CreateTextNode($Message)) | Out-Null
    }
    $toast = [Windows.UI.Notifications.ToastNotification]::new($template)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("WallSync").Show($toast)
} catch {
    # Fallback to tray balloon notification if WinRT toast is restricted
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.BalloonTipTitle = $Title
        $notify.BalloonTipText = $Message
        $notify.Visible = $true
        $notify.ShowBalloonTip(4000)
        $notify.Dispose()
    } catch {}
}
''';

      await scriptFile.writeAsString(scriptCode, flush: true);
      _cachedToastScript = scriptFile;
      return scriptFile;
    } catch (e) {
      logInfo('NotificationService', 'Could not cache toast script: $e');
      return null;
    }
  }

  /// Displays a native Windows desktop notification outside the application.
  Future<bool> showDesktopNotification({
    required String title,
    required String message,
    String? id,
    String? type,
    String? url,
  }) async {
    final cleanTitle = title.trim().isEmpty
        ? 'WallSync Notification'
        : title.trim();
    final cleanMessage = message.trim();

    // Notify in-app stream listeners
    if (!_notificationStreamCtrl.isClosed) {
      _notificationStreamCtrl.add(
        AppNotification(
          id: id ?? 'local_${DateTime.now().millisecondsSinceEpoch}',
          title: cleanTitle,
          message: cleanMessage,
          type: type ?? 'update',
          actionUrl: url,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }

    if (!Platform.isWindows || isTestMode) {
      if (id != null && id.isNotEmpty) {
        await markAsSeen(id);
      }
      return true;
    }

    try {
      final scriptFile = await _ensureToastScriptExists();
      if (scriptFile != null && await scriptFile.exists()) {
        final res = await Process.run('powershell', [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          scriptFile.path,
          '-Title',
          cleanTitle,
          '-Message',
          cleanMessage,
        ]);
        if (res.exitCode == 0) {
          logInfo(
            'NotificationService',
            'Desktop toast displayed successfully: "$cleanTitle"',
          );
          if (id != null && id.isNotEmpty) {
            await markAsSeen(id);
          }
          return true;
        }
      }

      logError(
        'NotificationService',
        'Toast helper script is unavailable or exited unsuccessfully',
      );
      return false;
    } catch (e, st) {
      logError(
        'NotificationService',
        'Failed to show desktop notification',
        e,
        st,
      );
      return false;
    }
  }

  /// Processes an incoming notification payload from the server heartbeat or SSE.
  /// If it has not been seen yet, displays a desktop notification.
  Future<void> processIncomingNotification(Map<String, dynamic> data) async {
    try {
      if (!_initialized) {
        await init();
      }

      final notif = AppNotification.fromJson(data);
      if (notif.id.isEmpty) return;

      if (_lastSeenId == notif.id) {
        // Already shown to user on this machine
        return;
      }

      logInfo(
        'NotificationService',
        'New unread notification received from server: [${notif.id}] ${notif.title}',
      );

      await showDesktopNotification(
        title: notif.title,
        message: notif.message,
        id: notif.id,
        type: notif.type,
        url: notif.actionUrl,
      );
    } catch (e, st) {
      logError(
        'NotificationService',
        'Error processing incoming notification',
        e,
        st,
      );
    }
  }

  /// Persists notification ID as seen so duplicate popups do not occur
  Future<void> markAsSeen(String id) async {
    _lastSeenId = id;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefLastSeenKey, id);
    } catch (_) {}
  }

  /// Resets the seen notification tracker (useful for testing)
  Future<void> resetSeenHistory() async {
    _lastSeenId = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefLastSeenKey);
    } catch (_) {}
  }
}
