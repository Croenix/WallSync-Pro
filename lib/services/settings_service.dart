import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'overlay_startup_service.dart';

Future<File>? _appLogFileCache;

Future<File> _appLogFile() async {
  final cached = _appLogFileCache;
  if (cached != null) return cached;

  final future = _createAppLogFile();
  _appLogFileCache = future;
  try {
    return await future;
  } catch (_) {
    _appLogFileCache = null;
    rethrow;
  }
}

Future<File> _createAppLogFile() async {
  final appData = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
  final dirPath = '$appData\\com.example\\wallsync';
  final dir = Directory(dirPath);
  await dir.create(recursive: true);
  return File('$dirPath\\app_debug.log');
}

final List<String> _pendingLogLines = [];
bool _isFlushingLogs = false;
Timer? _logFlushDebounce;

void _scheduleLogFlush() {
  _logFlushDebounce?.cancel();
  _logFlushDebounce = Timer(
    const Duration(milliseconds: 100),
    _flushPendingLogs,
  );
}

Future<void> _flushPendingLogs() async {
  if (_isFlushingLogs || _pendingLogLines.isEmpty) return;
  _isFlushingLogs = true;
  try {
    final batch = List<String>.from(_pendingLogLines);
    _pendingLogLines.clear();

    final file = await _appLogFile();
    // Rotate log if it exceeds 10 MB to prevent unbounded storage consumption
    if (await file.exists()) {
      final len = await file.length();
      if (len > 10 * 1024 * 1024) {
        final backup = File('${file.path}.old');
        if (await backup.exists()) {
          try {
            await backup.delete();
          } catch (_) {}
        }
        try {
          await file.rename(backup.path);
        } catch (_) {}
      }
    }

    await file.writeAsString(batch.join(), mode: FileMode.append, flush: false);
  } catch (e) {
    debugPrint('LOG FLUSH ERROR: $e');
  } finally {
    _isFlushingLogs = false;
    if (_pendingLogLines.isNotEmpty) {
      _scheduleLogFlush();
    }
  }
}

Future<void> flushPendingLogs() async {
  _logFlushDebounce?.cancel();
  final stopwatch = Stopwatch()..start();
  while (_isFlushingLogs && stopwatch.elapsed < const Duration(seconds: 2)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  if (!_isFlushingLogs) await _flushPendingLogs();
}

void _enqueueLog(
  String level,
  String tag,
  String message, [
  dynamic error,
  StackTrace? stackTrace,
]) {
  if (!kDebugMode &&
      level != 'ERROR' &&
      tag != 'OverlayStartup' &&
      tag != 'OverlayStartupService' &&
      tag != 'OverlayLifecycleService' &&
      tag != 'AppRuntimeService' &&
      tag != 'Main') {
    return;
  }

  // Cap overly large log messages (e.g. base64 payloads) to prevent memory spikes & I/O freezes
  String safeMessage = message;
  if (safeMessage.length > 2000) {
    safeMessage =
        '${safeMessage.substring(0, 2000)}... [truncated ${safeMessage.length - 2000} chars]';
  }

  final logMsg = StringBuffer();
  logMsg.writeln(
    '[${DateTime.now().toIso8601String()}] [$level] [$tag] $safeMessage',
  );
  if (error != null) {
    logMsg.writeln('  Error: $error');
  }
  if (stackTrace != null) {
    logMsg.writeln('  Stacktrace:\n$stackTrace');
  }
  _pendingLogLines.add(logMsg.toString());
  _scheduleLogFlush();
}

void logInfo(String tag, String message) {
  if (kDebugMode ||
      tag == 'OverlayStartup' ||
      tag == 'OverlayStartupService' ||
      tag == 'OverlayLifecycleService') {
    final formatted =
        '[${DateTime.now().toIso8601String()}] [INFO] [$tag] $message';
    debugPrint(formatted);
    _enqueueLog('INFO', tag, message);
  }
}

void logWarning(String tag, String message) {
  if (kDebugMode) {
    final formatted =
        '[${DateTime.now().toIso8601String()}] [WARN] [$tag] $message';
    debugPrint(formatted);
    _enqueueLog('WARN', tag, message);
  }
}

void logDebug(String tag, String message) {
  if (kDebugMode) {
    final formatted =
        '[${DateTime.now().toIso8601String()}] [DEBUG] [$tag] $message';
    debugPrint(formatted);
    _enqueueLog('DEBUG', tag, message);
  }
}

void logPerf(String tag, String message) {
  if (kDebugMode ||
      tag == 'OverlayStartup' ||
      tag == 'AppRuntimeService' ||
      tag == 'Main') {
    final formatted =
        '[${DateTime.now().toIso8601String()}] [PERF] [$tag] $message';
    debugPrint(formatted);
    _enqueueLog('PERF', tag, message);
  }
}

void logError(
  String tag,
  String message, [
  dynamic error,
  StackTrace? stackTrace,
]) {
  if (kDebugMode) {
    final formatted =
        '[${DateTime.now().toIso8601String()}] [ERROR] [$tag] $message';
    debugPrint(formatted);
    if (error != null) {
      debugPrint('  Error: $error');
    }
    if (stackTrace != null) {
      debugPrint('  Stacktrace:\n$stackTrace');
    }
  }
  _enqueueLog('ERROR', tag, message, error, stackTrace);
}

/// Keys used for per-element color and font maps.
class ElementKey {
  static const String hours = 'hours';
  static const String minutes = 'minutes';
  static const String seconds = 'seconds';
  static const String ampm = 'ampm';
  static const String date = 'date';
  static const String day = 'day';
  static const String year = 'year';
  static const String separator = 'separator';
  static const String glowOuter = 'glow_outer';
  static const String glowInner = 'glow_inner';
  static const String innerBackground = 'inner_background';
  static const String neonBox = 'neon_box';
  static const String neonBadge = 'neon_badge';
  static const String neonDivider = 'neon_divider';
  static const String cpu = 'cpu';
  static const String ram = 'ram';

  // Smart Dashboard sub-elements
  static const String wifiIcon = 'wifi_icon';
  static const String wifiText = 'wifi_text';
  static const String bluetoothIcon = 'bluetooth_icon';
  static const String bluetoothText = 'bluetooth_text';
  static const String mediaTitle = 'media_title';
  static const String mediaArtist = 'media_artist';
  static const String mediaTime = 'media_time';
  static const String mediaIcon = 'media_icon';
  static const String mediaBg = 'media_bg';
  static const String weatherTemp = 'weather_temp';
  static const String weatherStatus = 'weather_status';
  static const String weatherIcon = 'weather_icon';

  static const List<String> all = [
    hours,
    minutes,
    seconds,
    ampm,
    date,
    day,
    year,
    separator,
    glowOuter,
    glowInner,
    innerBackground,
    neonBox,
    neonBadge,
    neonDivider,
    cpu,
    ram,
    wifiIcon,
    wifiText,
    bluetoothIcon,
    bluetoothText,
    mediaTitle,
    mediaArtist,
    mediaTime,
    mediaIcon,
    mediaBg,
    weatherTemp,
    weatherStatus,
    weatherIcon,
  ];

  static const Set<String> textKeys = {
    hours,
    minutes,
    seconds,
    ampm,
    date,
    day,
    year,
    neonBadge,
    cpu,
    ram,
    wifiText,
    bluetoothText,
    mediaTitle,
    mediaArtist,
    mediaTime,
    weatherTemp,
    weatherStatus,
  };
}

class MediaElementType {
  static const Set<String> all = {
    'media_pill',
    'media_title',
    'media_artist',
    'media_album',
    'media_source',
    'media_status',
    'media_artwork',
    'media_progress',
    'media_elapsed',
    'media_duration',
    'media_controls',
    'media_animation',
  };

  static bool contains(String type) => all.contains(type);
}

/// Represents a recently applied or browsed wallpaper (both static images and live videos).
class RecentWallpaperItem {
  final String id;
  final String name;
  final String pathOrUrl;
  final String type; // 'static' | 'video'
  final String? thumbnailUrl;
  final int timestamp; // epoch milliseconds

  RecentWallpaperItem({
    required this.id,
    required this.name,
    required this.pathOrUrl,
    required this.type,
    this.thumbnailUrl,
    int? timestamp,
  }) : timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;

  factory RecentWallpaperItem.fromJson(Map<String, dynamic> json) {
    return RecentWallpaperItem(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? 'Wallpaper',
      pathOrUrl: json['pathOrUrl']?.toString() ?? json['url']?.toString() ?? '',
      type: json['type']?.toString() ?? 'static',
      thumbnailUrl: json['thumbnailUrl']?.toString(),
      timestamp: json['timestamp'] is int
          ? json['timestamp'] as int
          : (int.tryParse(json['timestamp']?.toString() ?? '') ?? 0),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'pathOrUrl': pathOrUrl,
    'type': type,
    if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
    'timestamp': timestamp,
  };

  bool get isVideo =>
      type == 'video' ||
      pathOrUrl.toLowerCase().endsWith('.mp4') ||
      pathOrUrl.toLowerCase().endsWith('.webm') ||
      pathOrUrl.toLowerCase().endsWith('.mkv') ||
      pathOrUrl.toLowerCase().endsWith('.mov');

  bool get isLocal =>
      !pathOrUrl.startsWith('http://') &&
      !pathOrUrl.startsWith('https://') &&
      !pathOrUrl.startsWith('asset://');
}

/// Represents an individual drag-and-drop element inside a Custom Widget layout.
class CustomWidgetElement {
  final String id;

  /// Element type: 'hours', 'minutes', 'seconds', 'ampm', 'time_colon', 'full_time',
  /// 'day', 'date', 'month', 'year', 'full_date',
  /// 'cpu_bar', 'ram_bar', 'space_bar', 'battery_bar', 'accent_bar',
  /// 'weather_temp', 'weather_status', 'weather_icon', 'weather_pill',
  /// 'media_pill', 'media_title', 'media_artist', 'media_album',
  /// 'media_source', 'media_status', 'media_artwork', 'media_progress',
  /// 'media_elapsed', 'media_duration', 'media_controls', 'media_animation',
  /// 'wifi_icon', 'bluetooth_icon', 'custom_text', 'neon_box'
  final String type;
  double x;
  double y;
  double width;
  double height;
  String text;
  String fontFamily;
  int color;
  int? activeColor;
  int? disabledColor;
  double fontSize;
  double letterSpacing;
  bool isBold;
  double opacity;
  double rotation;
  List<int>? gradientColors;

  CustomWidgetElement({
    required this.id,
    required this.type,
    this.x = 20.0,
    this.y = 20.0,
    this.width = 100.0,
    this.height = 30.0,
    this.text = '',
    this.fontFamily = 'Montserrat',
    this.color = 0xFFFFFFFF,
    this.activeColor,
    this.disabledColor,
    this.fontSize = 16.0,
    this.letterSpacing = 0.0,
    this.isBold = false,
    this.opacity = 1.0,
    this.rotation = 0.0,
    this.gradientColors,
  });

  factory CustomWidgetElement.fromJson(Map<String, dynamic> json) {
    List<int>? grad;
    if (json['gradientColors'] is List) {
      grad = (json['gradientColors'] as List).whereType<int>().toList();
    }
    return CustomWidgetElement(
      id:
          json['id']?.toString() ??
          'elem_${DateTime.now().microsecondsSinceEpoch}',
      type: json['type']?.toString() ?? 'custom_text',
      x: (json['x'] as num?)?.toDouble() ?? 20.0,
      y: (json['y'] as num?)?.toDouble() ?? 20.0,
      width: (json['width'] as num?)?.toDouble() ?? 100.0,
      height: (json['height'] as num?)?.toDouble() ?? 30.0,
      text: json['text']?.toString() ?? '',
      fontFamily: json['fontFamily']?.toString() ?? 'Montserrat',
      color: json['color'] is int ? json['color'] as int : 0xFFFFFFFF,
      activeColor: json['activeColor'] is int
          ? json['activeColor'] as int
          : null,
      disabledColor: json['disabledColor'] is int
          ? json['disabledColor'] as int
          : null,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 16.0,
      letterSpacing: (json['letterSpacing'] as num?)?.toDouble() ?? 0.0,
      isBold: json['isBold'] is bool ? json['isBold'] as bool : false,
      opacity: (json['opacity'] as num?)?.toDouble() ?? 1.0,
      rotation: (json['rotation'] as num?)?.toDouble() ?? 0.0,
      gradientColors: grad,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'text': text,
    'fontFamily': fontFamily,
    'color': color,
    if (activeColor != null) 'activeColor': activeColor,
    if (disabledColor != null) 'disabledColor': disabledColor,
    'fontSize': fontSize,
    'letterSpacing': letterSpacing,
    'isBold': isBold,
    'opacity': opacity,
    'rotation': rotation,
    if (gradientColors != null) 'gradientColors': gradientColors,
  };

  CustomWidgetElement copyWith({
    String? id,
    String? type,
    double? x,
    double? y,
    double? width,
    double? height,
    String? text,
    String? fontFamily,
    int? color,
    int? activeColor,
    int? disabledColor,
    double? fontSize,
    double? letterSpacing,
    bool? isBold,
    double? opacity,
    double? rotation,
    List<int>? gradientColors,
  }) {
    return CustomWidgetElement(
      id: id ?? this.id,
      type: type ?? this.type,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      text: text ?? this.text,
      fontFamily: fontFamily ?? this.fontFamily,
      color: color ?? this.color,
      activeColor: activeColor ?? this.activeColor,
      disabledColor: disabledColor ?? this.disabledColor,
      fontSize: fontSize ?? this.fontSize,
      letterSpacing: letterSpacing ?? this.letterSpacing,
      isBold: isBold ?? this.isBold,
      opacity: opacity ?? this.opacity,
      rotation: rotation ?? this.rotation,
      gradientColors:
          gradientColors ??
          (this.gradientColors != null
              ? List<int>.from(this.gradientColors!)
              : null),
    );
  }

  static List<CustomWidgetElement> defaultCustomLayout() {
    return [
      CustomWidgetElement(
        id: 'default_day',
        type: 'day',
        x: 24.0,
        y: 20.0,
        width: 180.0,
        height: 20.0,
        fontFamily: 'Product Sans',
        fontSize: 12.0,
        letterSpacing: 2.0,
        isBold: true,
        color: 0xFFF18734,
      ),
      CustomWidgetElement(
        id: 'default_hours',
        type: 'hours',
        x: 24.0,
        y: 44.0,
        width: 76.0,
        height: 60.0,
        fontFamily: 'Montserrat',
        fontSize: 54.0,
        letterSpacing: -1.0,
        isBold: true,
        color: 0xFFFFFFFF,
      ),
      CustomWidgetElement(
        id: 'default_colon',
        type: 'time_colon',
        x: 104.0,
        y: 44.0,
        width: 16.0,
        height: 60.0,
        fontFamily: 'Montserrat',
        fontSize: 48.0,
        isBold: true,
        color: 0xFFF18734,
      ),
      CustomWidgetElement(
        id: 'default_minutes',
        type: 'minutes',
        x: 122.0,
        y: 44.0,
        width: 76.0,
        height: 60.0,
        fontFamily: 'Montserrat',
        fontSize: 54.0,
        letterSpacing: -1.0,
        isBold: true,
        color: 0xFFFFFFFF,
      ),
      CustomWidgetElement(
        id: 'default_ampm',
        type: 'ampm',
        x: 202.0,
        y: 50.0,
        width: 32.0,
        height: 20.0,
        fontFamily: 'Montserrat',
        fontSize: 12.0,
        letterSpacing: 1.0,
        isBold: true,
        color: 0xFFF18734,
      ),
      CustomWidgetElement(
        id: 'default_accent_bar',
        type: 'accent_bar',
        x: 24.0,
        y: 110.0,
        width: 64.0,
        height: 3.5,
        color: 0xFFF18734,
      ),
      CustomWidgetElement(
        id: 'default_date',
        type: 'full_date',
        x: 24.0,
        y: 122.0,
        width: 210.0,
        height: 22.0,
        fontFamily: 'Montserrat',
        fontSize: 12.0,
        letterSpacing: 0.8,
        color: 0xFFCBD5E1,
      ),
      CustomWidgetElement(
        id: 'default_cpu',
        type: 'cpu_bar',
        x: 260.0,
        y: 28.0,
        width: 190.0,
        height: 34.0,
        fontFamily: 'Montserrat',
        fontSize: 11.0,
        color: 0xFF00FFCC,
      ),
      CustomWidgetElement(
        id: 'default_ram',
        type: 'ram_bar',
        x: 260.0,
        y: 70.0,
        width: 190.0,
        height: 34.0,
        fontFamily: 'Montserrat',
        fontSize: 11.0,
        color: 0xFFA855F7,
      ),
      CustomWidgetElement(
        id: 'default_weather',
        type: 'weather_pill',
        x: 260.0,
        y: 112.0,
        width: 190.0,
        height: 34.0,
        fontFamily: 'Montserrat',
        fontSize: 11.0,
        color: 0xFF38BDF8,
      ),
      CustomWidgetElement(
        id: 'default_wifi',
        type: 'wifi_icon',
        x: 24.0,
        y: 154.0,
        width: 22.0,
        height: 22.0,
        color: 0xFFF18734,
      ),
      CustomWidgetElement(
        id: 'default_bluetooth',
        type: 'bluetooth_icon',
        x: 52.0,
        y: 154.0,
        width: 22.0,
        height: 22.0,
        color: 0xFFF18734,
      ),
      CustomWidgetElement(
        id: 'default_media',
        type: 'media_pill',
        x: 24.0,
        y: 190.0,
        width: 426.0,
        height: 42.0,
        color: 0xFF00FF55,
      ),
    ];
  }
}

/// Represents a user-designed and saved custom widget configuration.
class SavedCustomWidget {
  final String id;
  final String name;
  final List<CustomWidgetElement> elements;
  final double width;
  final double height;
  final int createdAt; // epoch ms

  SavedCustomWidget({
    required this.id,
    required this.name,
    required this.elements,
    this.width = 480.0,
    this.height = 260.0,
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  factory SavedCustomWidget.fromJson(Map<String, dynamic> json) {
    List<CustomWidgetElement> elems = [];
    if (json['elements'] is List) {
      for (final item in json['elements'] as List) {
        if (item is Map) {
          try {
            elems.add(
              CustomWidgetElement.fromJson(Map<String, dynamic>.from(item)),
            );
          } catch (_) {}
        }
      }
    }
    if (elems.isEmpty) {
      elems = CustomWidgetElement.defaultCustomLayout();
    }
    return SavedCustomWidget(
      id:
          json['id']?.toString() ??
          'custom_${DateTime.now().microsecondsSinceEpoch}',
      name: json['name']?.toString() ?? 'Custom Widget',
      elements: elems,
      width: (json['width'] as num?)?.toDouble() ?? 480.0,
      height: (json['height'] as num?)?.toDouble() ?? 260.0,
      createdAt: json['createdAt'] is int
          ? json['createdAt'] as int
          : (int.tryParse(json['createdAt']?.toString() ?? '') ??
                DateTime.now().millisecondsSinceEpoch),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'elements': elements.map((e) => e.toJson()).toList(),
    'width': width,
    'height': height,
    'createdAt': createdAt,
  };

  SavedCustomWidget copyWith({
    String? id,
    String? name,
    List<CustomWidgetElement>? elements,
    double? width,
    double? height,
    int? createdAt,
  }) {
    return SavedCustomWidget(
      id: id ?? this.id,
      name: name ?? this.name,
      elements: elements ?? this.elements.map((e) => e.copyWith()).toList(),
      width: width ?? this.width,
      height: height ?? this.height,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

class WidgetSettings {
  String
  backgroundType; // 'glass_dark', 'glass_light', 'gradient', 'curated', 'custom', 'animated'
  int curatedIndex;
  String? customImagePath;

  // Global fallback color & font (used when element-specific ones aren't set)
  int textColor;
  String fontFamily;
  double fontSizeMultiplier;

  // Per-element overrides: key → ARGB int color / font family string / scale double.
  // An empty map means "use global settings for all elements".
  Map<String, int> elementColors;
  Map<String, List<int>> elementGradients;
  Map<String, String> elementFonts;
  Map<String, double> elementSizes;

  // Global gradient text / elements styling
  bool useGlobalGradient;
  List<int> globalGradientColors;

  // Animated background selection: '' | 'matrix' | 'particles' | 'aurora' | 'waves' | 'neon_pulse'
  String animatedBg;

  // User-saved color palette (up to 12 entries stored as ARGB ints)
  List<int> colorPalette;

  // Solid background color & Custom gradient colors list
  int solidColor;
  List<int> customGradientColors;

  // Active wallpaper settings
  String activeWallpaperType; // 'static' | 'animated' | 'none'
  String? activeWallpaperPath; // local file path to the cached/static wallpaper
  String activeWallpaperAnimatedBg; // animated wallpaper preset (e.g. 'matrix')
  String wallpaperFit; // 'fill' | 'fit' | 'stretch'
  double videoWallpaperVolume;
  bool videoWallpaperMuted;
  bool videoWallpaperLoop;
  bool videoWallpaperPaused;
  bool videoWallpaperPauseOnFullscreen;
  bool videoWallpaperPauseOnBatterySaver;
  double videoWallpaperSpeed;
  bool colorBoost;
  List<RecentWallpaperItem> recentWallpapers;

  bool use24HourFormat;
  bool showSeconds;
  bool alwaysOnTop;
  double opacity;
  double? posX;
  double? posY;
  double width;
  double height;
  bool isLocked;
  bool startOnBoot;
  bool exitOverlay;
  bool showOuterFrame;
  bool editorMode;
  double sizeFactor;

  // 3D position & rotation controls
  String widgetTemplate; // 'classic' | 'minimal' | 'cyber' | 'split' | 'neon'
  Map<String, double> elementTranslateX;
  Map<String, double> elementTranslateY;
  Map<String, double> elementTranslateZ;
  Map<String, double> elementRotateX;
  Map<String, double> elementRotateY;
  Map<String, double> elementRotateZ;

  String weatherLocation;
  String weatherTemp;
  String weatherStatus;
  String weatherLocationResolved;

  bool showWifi;
  bool wifiEnabled;
  bool showBluetooth;
  bool bluetoothEnabled;
  bool showMediaControl;
  int mediaThemeColor;
  bool showWeather;
  int weatherThemeColor;
  bool showCpu;
  bool showRam;
  bool showNeonBadge;
  List<CustomWidgetElement> customElements;
  List<SavedCustomWidget> savedCustomWidgets;

  double? separatorWidth;
  double? separatorHeight;

  double get effectiveSeparatorWidth {
    if (separatorWidth != null) return separatorWidth!;
    return widgetTemplate == 'minimal' ? 2.0 : 80.0;
  }

  double get effectiveSeparatorHeight {
    if (separatorHeight != null) return separatorHeight!;
    return widgetTemplate == 'minimal' ? 24.0 : 1.5;
  }

  static Map<String, Map<String, double>> get templateDefaults => {
    'classic': {'width': 360.0, 'height': 200.0, 'sizeFactor': 1.0},
    'minimal': {'width': 300.0, 'height': 100.0, 'sizeFactor': 1.0},
    'cyber': {'width': 240.0, 'height': 280.0, 'sizeFactor': 0.9},
    'split': {'width': 320.0, 'height': 160.0, 'sizeFactor': 1.0},
    'neon': {'width': 390.0, 'height': 240.0, 'sizeFactor': 1.0},
    'animated_neon': {'width': 400.0, 'height': 400.0, 'sizeFactor': 0.8},
    'sleep_weather': {'width': 420.0, 'height': 300.0, 'sizeFactor': 1.0},
    'robik': {'width': 430.0, 'height': 220.0, 'sizeFactor': 1.0},
    'atomic_clock': {'width': 440.0, 'height': 220.0, 'sizeFactor': 1.0},
    'custom': {'width': 480.0, 'height': 260.0, 'sizeFactor': 1.0},
  };

  WidgetSettings({
    this.backgroundType = 'none',
    this.curatedIndex = 0,
    this.customImagePath,
    this.textColor = 0xFFFFFFFF,
    this.fontFamily = 'Segoe UI',
    this.fontSizeMultiplier = 1.0,
    Map<String, int>? elementColors,
    Map<String, List<int>>? elementGradients,
    Map<String, String>? elementFonts,
    Map<String, double>? elementSizes,
    this.useGlobalGradient = false,
    List<int>? globalGradientColors,
    this.animatedBg = '',
    List<int>? colorPalette,
    this.activeWallpaperType = 'none',
    this.activeWallpaperPath,
    this.activeWallpaperAnimatedBg = '',
    this.wallpaperFit = 'fill',
    this.videoWallpaperVolume = 0.5,
    this.videoWallpaperMuted = false,
    this.videoWallpaperLoop = true,
    this.videoWallpaperPaused = false,
    this.videoWallpaperPauseOnFullscreen = true,
    this.videoWallpaperPauseOnBatterySaver = true,
    this.videoWallpaperSpeed = 1.0,
    this.colorBoost = false,
    this.use24HourFormat = false,
    this.showSeconds = true,
    this.alwaysOnTop = true,
    this.opacity = 1.0,
    this.posX,
    this.posY,
    this.width = 360.0,
    this.height = 200.0,
    this.isLocked = false,
    this.startOnBoot = true,
    this.exitOverlay = false,
    this.showOuterFrame = true,
    this.widgetTemplate = 'classic',
    this.editorMode = true,
    this.sizeFactor = 1.0,
    Map<String, double>? elementTranslateX,
    Map<String, double>? elementTranslateY,
    Map<String, double>? elementTranslateZ,
    Map<String, double>? elementRotateX,
    Map<String, double>? elementRotateY,
    Map<String, double>? elementRotateZ,
    this.separatorWidth,
    this.separatorHeight,
    this.solidColor = 0xFF1E1E2A,
    this.weatherLocation = '',
    this.weatherTemp = '',
    this.weatherStatus = '',
    this.weatherLocationResolved = '',
    this.showWifi = true,
    this.wifiEnabled = true,
    this.showBluetooth = true,
    this.bluetoothEnabled = true,
    this.showMediaControl = true,
    this.mediaThemeColor = 0xFF00FF55,
    this.showWeather = true,
    this.weatherThemeColor = 0xFF00FF55,
    this.showCpu = true,
    this.showRam = true,
    this.showNeonBadge = true,
    List<int>? customGradientColors,
    List<RecentWallpaperItem>? recentWallpapers,
    List<CustomWidgetElement>? customElements,
    List<SavedCustomWidget>? savedCustomWidgets,
  }) : elementColors = elementColors ?? {},
       elementGradients = elementGradients ?? {},
       globalGradientColors = globalGradientColors ?? [0xFF00F0FF, 0xFFD946EF],
       elementFonts = elementFonts ?? {},
       elementSizes = elementSizes ?? {},
       colorPalette = colorPalette ?? [],
       customGradientColors = customGradientColors ?? [0xFF8E2DE2, 0xFF4A00E0],
       recentWallpapers = recentWallpapers ?? [],
       customElements =
           customElements ?? CustomWidgetElement.defaultCustomLayout(),
       savedCustomWidgets = savedCustomWidgets ?? [],
       elementTranslateX = elementTranslateX ?? {},
       elementTranslateY = elementTranslateY ?? {},
       elementTranslateZ = elementTranslateZ ?? {},
       elementRotateX = elementRotateX ?? {},
       elementRotateY = elementRotateY ?? {},
       elementRotateZ = elementRotateZ ?? {};

  /// Returns the effective gradient (list of ARGB ints) for a given element key,
  /// or null if the element should use solid color rendering.
  List<int>? gradientFor(String key) {
    if (elementGradients.containsKey(key) &&
        elementGradients[key] != null &&
        elementGradients[key]!.length >= 2) {
      return elementGradients[key]!;
    }
    if (useGlobalGradient && globalGradientColors.length >= 2) {
      // Containers/backgrounds should not inherit global text gradient automatically
      if (key == 'neon_box' ||
          key == 'inner_background' ||
          key == 'media_bg' ||
          key == 'glow_outer' ||
          key == 'glow_inner') {
        return null;
      }
      return globalGradientColors;
    }
    return null;
  }

  /// Returns the effective color for a given element key.
  int colorFor(String key) {
    if (elementColors.containsKey(key)) {
      return elementColors[key]!;
    }
    if (textColor != 0xFFFFFFFF) {
      return textColor;
    }
    switch (widgetTemplate) {
      case 'minimal':
        if (key == 'hours' || key == 'minutes' || key == 'seconds') {
          return 0xFFF1F5F9;
        }
        if (key == 'separator') return 0x6694A3B8; // 0.4 opacity of 0xFF94A3B8
        return 0xFF94A3B8;
      case 'cyber':
        if (key == 'hours') return 0xFFFACC15;
        if (key == 'minutes') return 0xFF06B6D4;
        if (key == 'seconds') return 0xFFA855F7;
        return 0xFF10B981;
      case 'split':
        if (key == 'hours' || key == 'seconds') return 0xFFF43F5E;
        if (key == 'minutes') return 0xFFFFFFFF;
        if (key == 'separator') return 0xFFF43F5E;
        return 0xFFE9D5FF;
      case 'neon':
        if (key == 'hours' || key == 'minutes' || key == 'ampm') {
          return 0xFFD946EF; // Signature Neon Magenta / Fuchsia
        }
        if (key == 'separator' || key == 'seconds') {
          return 0xFF00F0FF; // Signature Electric Cyan / Ice Blue
        }
        if (key == 'day' || key == 'date' || key == 'year') {
          return 0xFF38BDF8; // Glowing Sky Blue
        }
        if (key == 'neon_box') {
          return 0xFF3B82F6; // Electric Blue glass border & aura
        }
        if (key == 'neon_badge') {
          return 0xFF00FFCC; // Neon Mint / Cyber Turquoise
        }
        if (key == 'neon_divider') {
          return 0xFFD946EF; // Glowing Neon Magenta
        }
        if (key == 'cpu') {
          return 0xFF00FFCC; // Neon Mint / Cyan for CPU
        }
        if (key == 'ram') {
          return 0xFFA855F7; // Neon Purple / Orchid for RAM
        }
        return 0xFF3B82F6;
      case 'animated_neon':
        if (key == 'hours' ||
            key == 'minutes' ||
            key == 'date' ||
            key == 'year') {
          return 0xFFFFFFFF;
        }
        if (key == 'seconds' || key == 'day') return 0xFF8DCAED;
        if (key == 'ampm') return 0xFF6AAEE9;
        if (key == 'glow_outer' || key == 'glow_inner') return 0xFF1A23F2;
        if (key == 'inner_background') return 0x331A23F2;
        return 0xFFFFFFFF;
      case 'sleep_weather':
        if (key == 'hours' ||
            key == 'minutes' ||
            key == 'seconds' ||
            key == 'ampm') {
          return 0xFFFFFFFF;
        }
        if (key == 'day' || key == 'date' || key == 'year') {
          return 0xFFE2E8F0;
        }
        if (key == 'media_bg') {
          return 0xFF00FF55; // Signature Neon Green pill
        }
        if (key == 'media_icon' ||
            key == 'media_title' ||
            key == 'media_artist' ||
            key == 'media_time') {
          return 0xFF000000; // Contrasting Black on Neon Green
        }
        if (key == 'bluetoothIcon') {
          return 0xFF00FF55; // Neon green bluetooth
        }
        if (key == 'wifiIcon') {
          return 0xFFFFFFFF;
        }
        if (key == 'weatherIcon') {
          return 0xFF00FF55; // Neon green weather icon
        }
        if (key == 'weatherTemp' || key == 'weatherStatus') {
          return 0xFFE2E8F0;
        }
        return 0xFFFFFFFF;
      case 'robik':
        if (key == 'hours' || key == 'minutes' || key == 'seconds') {
          return 0xFFFFFFFF;
        }
        if (key == 'day' ||
            key == 'separator' ||
            key == 'weatherIcon' ||
            key == 'wifiIcon' ||
            key == 'bluetoothIcon' ||
            key == 'mediaIcon') {
          return 0xFFF18734;
        }
        if (key == 'date' || key == 'year') {
          return 0xFFCBD5E1;
        }
        return 0xFFF18734;
      case 'atomic_clock':
        if (key == 'day') return 0xFFFFFFFF;
        if (key == 'date') return 0xFFE2E8F0;
        if (key == 'hours' || key == 'minutes' || key == 'seconds') {
          return 0xFFFFFFFF;
        }
        return 0xFFFFFFFF;
      case 'classic':
      default:
        if (key == 'hours' || key == 'minutes' || key == 'seconds') {
          return 0xFFFFFFFF;
        }
        if (key == 'separator') return 0xFFFFD700;
        return 0xFFFFD700;
    }
  }

  /// Returns the effective font for a given element key.
  String fontFor(String key) {
    if (elementFonts.containsKey(key)) {
      return elementFonts[key]!;
    }
    if (fontFamily != 'Segoe UI') {
      return fontFamily;
    }
    switch (widgetTemplate) {
      case 'minimal':
        return 'Consolas';
      case 'cyber':
        return 'Impact';
      case 'split':
        return 'Arial';
      case 'neon':
        if (key == 'hours' ||
            key == 'minutes' ||
            key == 'seconds' ||
            key == 'cpu' ||
            key == 'ram' ||
            key == 'neon_badge') {
          return 'Montserrat';
        }
        return 'Segoe UI';
      case 'animated_neon':
      case 'sleep_weather':
        return 'Segoe UI';
      case 'robik':
        if (key == 'hours' || key == 'minutes' || key == 'seconds') {
          return 'Montserrat';
        }
        return 'Product Sans';
      case 'atomic_clock':
        return 'Anurati';
      case 'classic':
      default:
        return 'Georgia';
    }
  }

  double translateXFor(String key) => elementTranslateX[key] ?? 0.0;
  double translateYFor(String key) => elementTranslateY[key] ?? 0.0;
  double translateZFor(String key) => elementTranslateZ[key] ?? 0.0;
  double rotateXFor(String key) => elementRotateX[key] ?? 0.0;
  double rotateYFor(String key) => elementRotateY[key] ?? 0.0;
  double rotateZFor(String key) => elementRotateZ[key] ?? 0.0;

  double sizeFor(String key, double defaultSize) {
    final scale = elementSizes[key] ?? 1.0;
    return defaultSize * scale;
  }

  factory WidgetSettings.fromJson(Map<String, dynamic> json) {
    // Parse per-element color map (stored as {"hours": 4294967295, ...})
    Map<String, int> elementColors = {};
    if (json['elementColors'] is Map) {
      (json['elementColors'] as Map).forEach((k, v) {
        if (v is int) elementColors[k.toString()] = v;
      });
    }

    // Parse per-element gradient map
    Map<String, List<int>> elementGradients = {};
    if (json['elementGradients'] is Map) {
      (json['elementGradients'] as Map).forEach((k, v) {
        if (v is List) {
          final colors = v.whereType<int>().toList();
          if (colors.isNotEmpty) {
            elementGradients[k.toString()] = colors;
          }
        }
      });
    }

    // Parse global gradient colors list
    List<int> globalGrad = [];
    if (json['globalGradientColors'] is List) {
      globalGrad = (json['globalGradientColors'] as List)
          .whereType<int>()
          .toList();
    }

    // Parse per-element font map
    Map<String, String> elementFonts = {};
    if (json['elementFonts'] is Map) {
      (json['elementFonts'] as Map).forEach((k, v) {
        if (v is String) elementFonts[k.toString()] = v;
      });
    }

    // Parse color palette list
    List<int> palette = [];
    if (json['colorPalette'] is List) {
      palette = (json['colorPalette'] as List).whereType<int>().toList();
    }

    Map<String, double> parseDoubleMap(dynamic source) {
      Map<String, double> result = {};
      if (source is Map) {
        source.forEach((k, v) {
          if (v is num) result[k.toString()] = v.toDouble();
        });
      }
      return result;
    }

    String bgType = json['backgroundType'] ?? 'none';
    if (bgType == 'glass_dark' || bgType == 'glass_light') {
      bgType = 'none';
    }

    // Parse custom gradient colors list
    List<int> customGrad = [];
    if (json['customGradientColors'] is List) {
      customGrad = (json['customGradientColors'] as List)
          .whereType<int>()
          .toList();
    }

    // Parse recent wallpapers history
    List<RecentWallpaperItem> recentWallpapers = [];
    if (json['recentWallpapers'] is List) {
      for (final item in json['recentWallpapers'] as List) {
        if (item is Map) {
          try {
            recentWallpapers.add(
              RecentWallpaperItem.fromJson(Map<String, dynamic>.from(item)),
            );
          } catch (_) {}
        }
      }
    }

    // Parse custom elements
    List<CustomWidgetElement> customElems = [];
    if (json['customElements'] is List) {
      for (final item in json['customElements'] as List) {
        if (item is Map) {
          try {
            customElems.add(
              CustomWidgetElement.fromJson(Map<String, dynamic>.from(item)),
            );
          } catch (_) {}
        }
      }
    }
    if (customElems.isEmpty) {
      customElems = CustomWidgetElement.defaultCustomLayout();
    }

    // Parse saved custom widgets
    List<SavedCustomWidget> savedWidgets = [];
    if (json['savedCustomWidgets'] is List) {
      for (final item in json['savedCustomWidgets'] as List) {
        if (item is Map) {
          try {
            savedWidgets.add(
              SavedCustomWidget.fromJson(Map<String, dynamic>.from(item)),
            );
          } catch (_) {}
        }
      }
    }

    return WidgetSettings(
      backgroundType: bgType,
      curatedIndex: json['curatedIndex'] ?? 0,
      customImagePath: json['customImagePath'],
      textColor: json['textColor'] ?? 0xFFFFFFFF,
      fontFamily: json['fontFamily'] ?? 'Segoe UI',
      fontSizeMultiplier: (json['fontSizeMultiplier'] ?? 1.0).toDouble(),
      elementColors: elementColors,
      elementGradients: elementGradients,
      useGlobalGradient: json['useGlobalGradient'] ?? false,
      globalGradientColors: globalGrad.isNotEmpty ? globalGrad : null,
      elementFonts: elementFonts,
      elementSizes: parseDoubleMap(json['elementSizes']),
      animatedBg: json['animatedBg'] ?? '',
      colorPalette: palette,
      solidColor: json['solidColor'] ?? 0xFF1E1E2A,
      customGradientColors: customGrad.isNotEmpty ? customGrad : null,
      recentWallpapers: recentWallpapers,
      customElements: customElems,
      savedCustomWidgets: savedWidgets,
      activeWallpaperType: json['activeWallpaperType'] ?? 'none',
      activeWallpaperPath: json['activeWallpaperPath'],
      activeWallpaperAnimatedBg: json['activeWallpaperAnimatedBg'] ?? '',
      wallpaperFit: json['wallpaperFit'] ?? 'fill',
      videoWallpaperVolume: (json['videoWallpaperVolume'] ?? 0.5).toDouble(),
      videoWallpaperMuted: json['videoWallpaperMuted'] ?? false,
      videoWallpaperLoop: json['videoWallpaperLoop'] ?? true,
      videoWallpaperPaused: json['videoWallpaperPaused'] ?? false,
      videoWallpaperPauseOnFullscreen:
          json['videoWallpaperPauseOnFullscreen'] ?? true,
      videoWallpaperPauseOnBatterySaver:
          json['videoWallpaperPauseOnBatterySaver'] ?? true,
      videoWallpaperSpeed: (json['videoWallpaperSpeed'] ?? 1.0).toDouble(),
      colorBoost: json['colorBoost'] ?? false,
      use24HourFormat: json['use24HourFormat'] ?? false,
      showSeconds: json['showSeconds'] ?? true,
      alwaysOnTop: json['alwaysOnTop'] ?? true,
      opacity: (json['opacity'] ?? 0.85).toDouble(),
      posX: json['posX'] != null ? (json['posX'] as num).toDouble() : null,
      posY: json['posY'] != null ? (json['posY'] as num).toDouble() : null,
      width: (json['width'] ?? 360.0).toDouble(),
      height: (json['height'] ?? 200.0).toDouble(),
      isLocked: json['isLocked'] ?? false,
      startOnBoot: json['startOnBoot'] ?? false,
      exitOverlay: json['exitOverlay'] ?? false,
      showOuterFrame: json['showOuterFrame'] ?? true,
      widgetTemplate: json['widgetTemplate'] ?? 'classic',
      editorMode: json['editorMode'] ?? false,
      sizeFactor: (json['sizeFactor'] ?? 1.0).toDouble(),
      elementTranslateX: parseDoubleMap(json['elementTranslateX']),
      elementTranslateY: parseDoubleMap(json['elementTranslateY']),
      elementTranslateZ: parseDoubleMap(json['elementTranslateZ']),
      elementRotateX: parseDoubleMap(json['elementRotateX']),
      elementRotateY: parseDoubleMap(json['elementRotateY']),
      elementRotateZ: parseDoubleMap(json['elementRotateZ']),
      separatorWidth: json['separatorWidth'] != null
          ? (json['separatorWidth'] as num).toDouble()
          : null,
      separatorHeight: json['separatorHeight'] != null
          ? (json['separatorHeight'] as num).toDouble()
          : null,
      weatherLocation: json['weatherLocation'] ?? '',
      weatherTemp: json['weatherTemp'] ?? '',
      weatherStatus: json['weatherStatus'] ?? '',
      weatherLocationResolved: json['weatherLocationResolved'] ?? '',
      showWifi: json['showWifi'] ?? true,
      wifiEnabled: json['wifiEnabled'] ?? true,
      showBluetooth: json['showBluetooth'] ?? true,
      bluetoothEnabled: json['bluetoothEnabled'] ?? true,
      showMediaControl: json['showMediaControl'] ?? true,
      mediaThemeColor: json['mediaThemeColor'] ?? 0xFF00FF55,
      showWeather: json['showWeather'] ?? true,
      weatherThemeColor: json['weatherThemeColor'] ?? 0xFF00FF55,
      showCpu: json['showCpu'] ?? true,
      showRam: json['showRam'] ?? true,
      showNeonBadge: json['showNeonBadge'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'backgroundType': backgroundType,
      'curatedIndex': curatedIndex,
      'customImagePath': customImagePath,
      'textColor': textColor,
      'fontFamily': fontFamily,
      'fontSizeMultiplier': fontSizeMultiplier,
      'elementColors': elementColors,
      'elementGradients': elementGradients,
      'useGlobalGradient': useGlobalGradient,
      'globalGradientColors': globalGradientColors,
      'elementFonts': elementFonts,
      'elementSizes': elementSizes,
      'animatedBg': animatedBg,
      'colorPalette': colorPalette,
      'solidColor': solidColor,
      'customGradientColors': customGradientColors,
      'activeWallpaperType': activeWallpaperType,
      'activeWallpaperPath': activeWallpaperPath,
      'activeWallpaperAnimatedBg': activeWallpaperAnimatedBg,
      'wallpaperFit': wallpaperFit,
      'videoWallpaperVolume': videoWallpaperVolume,
      'videoWallpaperMuted': videoWallpaperMuted,
      'videoWallpaperLoop': videoWallpaperLoop,
      'videoWallpaperPaused': videoWallpaperPaused,
      'videoWallpaperPauseOnFullscreen': videoWallpaperPauseOnFullscreen,
      'videoWallpaperPauseOnBatterySaver': videoWallpaperPauseOnBatterySaver,
      'videoWallpaperSpeed': videoWallpaperSpeed,
      'colorBoost': colorBoost,
      'use24HourFormat': use24HourFormat,
      'showSeconds': showSeconds,
      'alwaysOnTop': alwaysOnTop,
      'opacity': opacity,
      'posX': posX,
      'posY': posY,
      'width': width,
      'height': height,
      'isLocked': isLocked,
      'startOnBoot': startOnBoot,
      'exitOverlay': exitOverlay,
      'showOuterFrame': showOuterFrame,
      'widgetTemplate': widgetTemplate,
      'editorMode': editorMode,
      'sizeFactor': sizeFactor,
      'elementTranslateX': elementTranslateX,
      'elementTranslateY': elementTranslateY,
      'elementTranslateZ': elementTranslateZ,
      'elementRotateX': elementRotateX,
      'elementRotateY': elementRotateY,
      'elementRotateZ': elementRotateZ,
      'separatorWidth': separatorWidth,
      'separatorHeight': separatorHeight,
      'weatherLocation': weatherLocation,
      'weatherTemp': weatherTemp,
      'weatherStatus': weatherStatus,
      'weatherLocationResolved': weatherLocationResolved,
      'showWifi': showWifi,
      'wifiEnabled': wifiEnabled,
      'showBluetooth': showBluetooth,
      'bluetoothEnabled': bluetoothEnabled,
      'showMediaControl': showMediaControl,
      'mediaThemeColor': mediaThemeColor,
      'showWeather': showWeather,
      'weatherThemeColor': weatherThemeColor,
      'showCpu': showCpu,
      'showRam': showRam,
      'showNeonBadge': showNeonBadge,
      'customElements': customElements.map((e) => e.toJson()).toList(),
      'savedCustomWidgets': savedCustomWidgets.map((w) => w.toJson()).toList(),
      'recentWallpapers': recentWallpapers.map((r) => r.toJson()).toList(),
    };
  }

  /// Creates a copy with some fields overridden.
  WidgetSettings copyWith({
    String? backgroundType,
    int? curatedIndex,
    String? customImagePath,
    int? textColor,
    String? fontFamily,
    double? fontSizeMultiplier,
    Map<String, int>? elementColors,
    Map<String, List<int>>? elementGradients,
    Map<String, String>? elementFonts,
    Map<String, double>? elementSizes,
    bool? useGlobalGradient,
    List<int>? globalGradientColors,
    String? animatedBg,
    List<int>? colorPalette,
    String? activeWallpaperType,
    String? activeWallpaperPath,
    String? activeWallpaperAnimatedBg,
    String? wallpaperFit,
    double? videoWallpaperVolume,
    bool? videoWallpaperMuted,
    bool? videoWallpaperLoop,
    bool? videoWallpaperPaused,
    bool? videoWallpaperPauseOnFullscreen,
    bool? videoWallpaperPauseOnBatterySaver,
    double? videoWallpaperSpeed,
    bool? colorBoost,
    bool? use24HourFormat,
    bool? showSeconds,
    bool? alwaysOnTop,
    double? opacity,
    double? posX,
    double? posY,
    double? width,
    double? height,
    bool? isLocked,
    bool? startOnBoot,
    bool? exitOverlay,
    bool? showOuterFrame,
    String? widgetTemplate,
    bool? editorMode,
    double? sizeFactor,
    Map<String, double>? elementTranslateX,
    Map<String, double>? elementTranslateY,
    Map<String, double>? elementTranslateZ,
    Map<String, double>? elementRotateX,
    Map<String, double>? elementRotateY,
    Map<String, double>? elementRotateZ,
    double? separatorWidth,
    double? separatorHeight,
    int? solidColor,
    List<int>? customGradientColors,
    String? weatherLocation,
    String? weatherTemp,
    String? weatherStatus,
    String? weatherLocationResolved,
    bool? showWifi,
    bool? wifiEnabled,
    bool? showBluetooth,
    bool? bluetoothEnabled,
    bool? showMediaControl,
    int? mediaThemeColor,
    bool? showWeather,
    int? weatherThemeColor,
    bool? showCpu,
    bool? showRam,
    bool? showNeonBadge,
    List<RecentWallpaperItem>? recentWallpapers,
    List<CustomWidgetElement>? customElements,
    List<SavedCustomWidget>? savedCustomWidgets,
  }) {
    return WidgetSettings(
      backgroundType: backgroundType ?? this.backgroundType,
      curatedIndex: curatedIndex ?? this.curatedIndex,
      customImagePath: customImagePath ?? this.customImagePath,
      textColor: textColor ?? this.textColor,
      fontFamily: fontFamily ?? this.fontFamily,
      fontSizeMultiplier: fontSizeMultiplier ?? this.fontSizeMultiplier,
      elementColors: elementColors ?? Map.from(this.elementColors),
      elementGradients:
          elementGradients ??
          Map.from(
            this.elementGradients.map((k, v) => MapEntry(k, List<int>.from(v))),
          ),
      useGlobalGradient: useGlobalGradient ?? this.useGlobalGradient,
      globalGradientColors:
          globalGradientColors ?? List.from(this.globalGradientColors),
      elementFonts: elementFonts ?? Map.from(this.elementFonts),
      elementSizes: elementSizes ?? Map.from(this.elementSizes),
      animatedBg: animatedBg ?? this.animatedBg,
      colorPalette: colorPalette ?? List.from(this.colorPalette),
      solidColor: solidColor ?? this.solidColor,
      customGradientColors:
          customGradientColors ?? List.from(this.customGradientColors),
      activeWallpaperType: activeWallpaperType ?? this.activeWallpaperType,
      activeWallpaperPath: activeWallpaperPath ?? this.activeWallpaperPath,
      activeWallpaperAnimatedBg:
          activeWallpaperAnimatedBg ?? this.activeWallpaperAnimatedBg,
      wallpaperFit: wallpaperFit ?? this.wallpaperFit,
      videoWallpaperVolume: videoWallpaperVolume ?? this.videoWallpaperVolume,
      videoWallpaperMuted: videoWallpaperMuted ?? this.videoWallpaperMuted,
      videoWallpaperLoop: videoWallpaperLoop ?? this.videoWallpaperLoop,
      videoWallpaperPaused: videoWallpaperPaused ?? this.videoWallpaperPaused,
      videoWallpaperPauseOnFullscreen:
          videoWallpaperPauseOnFullscreen ??
          this.videoWallpaperPauseOnFullscreen,
      videoWallpaperPauseOnBatterySaver:
          videoWallpaperPauseOnBatterySaver ??
          this.videoWallpaperPauseOnBatterySaver,
      videoWallpaperSpeed: videoWallpaperSpeed ?? this.videoWallpaperSpeed,
      colorBoost: colorBoost ?? this.colorBoost,
      use24HourFormat: use24HourFormat ?? this.use24HourFormat,
      showSeconds: showSeconds ?? this.showSeconds,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      opacity: opacity ?? this.opacity,
      posX: posX ?? this.posX,
      posY: posY ?? this.posY,
      width: width ?? this.width,
      height: height ?? this.height,
      isLocked: isLocked ?? this.isLocked,
      startOnBoot: startOnBoot ?? this.startOnBoot,
      exitOverlay: exitOverlay ?? this.exitOverlay,
      showOuterFrame: showOuterFrame ?? this.showOuterFrame,
      widgetTemplate: widgetTemplate ?? this.widgetTemplate,
      editorMode: editorMode ?? this.editorMode,
      sizeFactor: sizeFactor ?? this.sizeFactor,
      elementTranslateX: elementTranslateX ?? Map.from(this.elementTranslateX),
      elementTranslateY: elementTranslateY ?? Map.from(this.elementTranslateY),
      elementTranslateZ: elementTranslateZ ?? Map.from(this.elementTranslateZ),
      elementRotateX: elementRotateX ?? Map.from(this.elementRotateX),
      elementRotateY: elementRotateY ?? Map.from(this.elementRotateY),
      elementRotateZ: elementRotateZ ?? Map.from(this.elementRotateZ),
      separatorWidth: separatorWidth ?? this.separatorWidth,
      separatorHeight: separatorHeight ?? this.separatorHeight,
      weatherLocation: weatherLocation ?? this.weatherLocation,
      weatherTemp: weatherTemp ?? this.weatherTemp,
      weatherStatus: weatherStatus ?? this.weatherStatus,
      weatherLocationResolved:
          weatherLocationResolved ?? this.weatherLocationResolved,
      showWifi: showWifi ?? this.showWifi,
      wifiEnabled: wifiEnabled ?? this.wifiEnabled,
      showBluetooth: showBluetooth ?? this.showBluetooth,
      bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
      showMediaControl: showMediaControl ?? this.showMediaControl,
      mediaThemeColor: mediaThemeColor ?? this.mediaThemeColor,
      showWeather: showWeather ?? this.showWeather,
      weatherThemeColor: weatherThemeColor ?? this.weatherThemeColor,
      showCpu: showCpu ?? this.showCpu,
      showRam: showRam ?? this.showRam,
      showNeonBadge: showNeonBadge ?? this.showNeonBadge,
      recentWallpapers: recentWallpapers ?? List.from(this.recentWallpapers),
      customElements:
          customElements ??
          this.customElements.map((e) => e.copyWith()).toList(),
      savedCustomWidgets:
          savedCustomWidgets ??
          this.savedCustomWidgets.map((w) => w.copyWith()).toList(),
    );
  }
}

class SettingsService {
  static Future<void> _settingsWriteQueue = Future<void>.value();

  Future<T> _serializeSettingsWrite<T>(Future<T> Function() operation) {
    final previous = _settingsWriteQueue;
    final completion = Completer<void>();
    _settingsWriteQueue = completion.future;
    return () async {
      try {
        await previous;
        return await operation();
      } finally {
        completion.complete();
      }
    }();
  }

  Directory? _cachedAppDir;

  Future<Directory> getAppDirectory() async {
    final cached = _cachedAppDir;
    if (cached != null) return cached;
    if (Platform.isWindows) {
      final appData =
          Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
      final dirPath = '$appData\\com.example\\wallsync';
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _cachedAppDir = dir;
      return dir;
    } else {
      final dir = await getApplicationSupportDirectory();
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _cachedAppDir = dir;
      return dir;
    }
  }

  Future<File> get settingsFile async {
    final directory = await getAppDirectory();
    return File('${directory.path}/overlay_settings.json');
  }

  Future<File> get lockFile async {
    final directory = await getAppDirectory();
    return File('${directory.path}/overlay.lock');
  }

  Future<File> get pidFile async {
    final directory = await getAppDirectory();
    return File('${directory.path}/overlay.pid');
  }

  Future<File> get _settingsLockFile async {
    final directory = await getAppDirectory();
    return File('${directory.path}/overlay_settings.lock');
  }

  WidgetSettings _cachedSettings = WidgetSettings();
  bool _settingsLoadSucceeded = false;

  bool get settingsLoadSucceeded => _settingsLoadSucceeded;

  Future<WidgetSettings> loadSettings() async {
    _settingsLoadSucceeded = false;
    try {
      final file = await settingsFile;
      if (!await file.exists()) {
        _settingsLoadSucceeded = true;
        return _cachedSettings;
      }

      int retries = 3;
      while (retries > 0) {
        try {
          final content = await file.readAsString();
          if (content.trim().isNotEmpty) {
            final Map<String, dynamic> json = jsonDecode(content);
            _cachedSettings = WidgetSettings.fromJson(json);
            _settingsLoadSucceeded = true;
            return _cachedSettings;
          }
          throw const FormatException('Settings file is empty.');
        } catch (e) {
          retries--;
          if (retries > 0) {
            await Future.delayed(const Duration(milliseconds: 50));
            continue;
          }
          logWarning(
            'SettingsService',
            'Could not read settings file; preserving cached settings and '
                'skipping startup registration synchronization: $e',
          );
        }
        break;
      }
    } catch (e) {
      logError(
        'SettingsService',
        'Failed to access settings file, returning cached settings',
        e,
      );
    }
    return _cachedSettings;
  }

  Future<void> saveSettings(WidgetSettings settings) => _serializeSettingsWrite(
    () async {
      RandomAccessFile? raf;
      final totalSw = Stopwatch()..start();
      try {
        final previousStartOnBoot = _cachedSettings.startOnBoot;
        final lock = await _settingsLockFile;
        final lockSw = Stopwatch()..start();
        raf = await lock.open(mode: FileMode.append);
        await raf.lock(FileLock.exclusive).timeout(const Duration(seconds: 3));
        final lockMs = lockSw.elapsedMilliseconds;

        final writeSw = Stopwatch()..start();
        await _writeSettings(settings);
        final writeMs = writeSw.elapsedMilliseconds;

        var shortcutMs = 0;
        if (previousStartOnBoot != settings.startOnBoot) {
          final shortcutSw = Stopwatch()..start();
          await _updateStartupShortcut(settings.startOnBoot);
          shortcutMs = shortcutSw.elapsedMilliseconds;
        }
        final totalMs = totalSw.elapsedMilliseconds;
        logPerf(
          'SettingsService',
          'Settings saved to file: total=${totalMs}ms '
              '(lockAcquire=${lockMs}ms, write=${writeMs}ms, '
              'shortcutSync=${shortcutMs}ms).',
        );
      } catch (e, stackTrace) {
        logError(
          'SettingsService',
          'Failed to save settings to file',
          e,
          stackTrace,
        );
        rethrow;
      } finally {
        if (raf != null) {
          try {
            await raf.unlock();
          } catch (_) {}
          try {
            await raf.close();
          } catch (_) {}
        }
      }
    },
  );

  /// Applies a partial update to the latest persisted settings without
  /// overwriting changes made by another app process.
  Future<WidgetSettings> updateSettings(
    WidgetSettings Function(WidgetSettings current) update,
  ) => _serializeSettingsWrite(() async {
    final lock = await _settingsLockFile;
    RandomAccessFile? raf;
    try {
      raf = await lock.open(mode: FileMode.append);
      await raf.lock(FileLock.exclusive).timeout(const Duration(seconds: 3));

      final current = await loadSettings();
      final updated = update(current);
      await _writeSettings(updated);
      if (current.startOnBoot != updated.startOnBoot) {
        await _updateStartupShortcut(updated.startOnBoot);
      }
      return updated;
    } catch (e, stackTrace) {
      logError('SettingsService', 'Failed to update settings', e, stackTrace);
      rethrow;
    } finally {
      if (raf != null) {
        try {
          await raf.unlock();
        } catch (_) {}
        try {
          await raf.close();
        } catch (_) {}
      }
    }
  });

  Future<void> _writeSettings(WidgetSettings settings) async {
    final file = await settingsFile;
    final jsonStr = jsonEncode(settings.toJson());
    if (await file.exists()) {
      try {
        if (await file.readAsString() == jsonStr) {
          _cachedSettings = settings;
          return;
        }
      } on FileSystemException catch (error) {
        logWarning(
          'SettingsService',
          'Could not compare existing settings before saving: $error',
        );
      }
    }
    final tempFile = File(
      '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await tempFile.writeAsString(jsonStr, flush: true);
      bool renamed = false;
      for (int i = 0; i < 3; i++) {
        try {
          await tempFile.rename(file.path);
          renamed = true;
          break;
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 40));
        }
      }
      if (!renamed) {
        await file.writeAsString(jsonStr, flush: true);
      }
      _cachedSettings = settings;
    } finally {
      if (await tempFile.exists()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _updateStartupShortcut(bool startOnBoot) async {
    if (!Platform.isWindows) return;
    if (kDebugMode) {
      logInfo(
        'SettingsService',
        'Skipping Windows startup task registration from a debug executable; '
            'the installed release app will synchronize the saved preference.',
      );
      return;
    }

    try {
      await OverlayStartupService(
        logInfo: logInfo,
        logWarning: logWarning,
      ).sync(startOnBoot);
    } catch (e, st) {
      logError(
        'SettingsService',
        'Could not synchronize the Windows startup registration; the saved '
            'preference remains in settings and a later launch may retry.',
        e,
        st,
      );
      rethrow;
    }
  }

  Future<void> syncStartupRegistration(bool startOnBoot) =>
      _updateStartupShortcut(startOnBoot);
}
