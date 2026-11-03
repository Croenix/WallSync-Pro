import 'dart:convert';
import 'package:flutter/material.dart';

/// Supported dock placement edges on the screen.
enum DockPosition {
  bottom,
  top,
  left,
  right,
}

/// Dock item alignment along its primary axis.
enum DockAlignment {
  start,
  center,
  end,
}

/// Visual styling mode for dock background container.
enum DockBackgroundStyle {
  acrylic,
  glass,
  mica,
  solid,
  gradient,
}

/// Types of elements supported in the WallSync dock system.
class DockElementType {
  static const String appLauncher = 'app_launcher';
  static const String pinnedApp = 'pinned_app';
  static const String runningTasks = 'running_tasks';
  static const String systemTray = 'system_tray';
  static const String clock = 'clock';
  static const String date = 'date';
  static const String weatherSlot = 'weather_slot';
  static const String mediaControls = 'media_controls';
  static const String volumeSlider = 'volume_slider';
  static const String networkStatus = 'network_status';
  static const String batteryStatus = 'battery_status';
  static const String cpuSparkline = 'cpu_sparkline';
  static const String ramSparkline = 'ram_sparkline';
  static const String separator = 'separator';
  static const String spacer = 'spacer';
  static const String quickSettings = 'quick_settings';
  static const String customAction = 'custom_action';

  static const List<String> allTypes = [
    appLauncher,
    pinnedApp,
    runningTasks,
    systemTray,
    clock,
    date,
    weatherSlot,
    mediaControls,
    volumeSlider,
    networkStatus,
    batteryStatus,
    cpuSparkline,
    ramSparkline,
    separator,
    spacer,
    quickSettings,
    customAction,
  ];

  static String getDisplayName(String type) {
    switch (type) {
      case appLauncher:
        return 'WallSync Launcher';
      case pinnedApp:
        return 'Pinned Application';
      case runningTasks:
        return 'Running Tasks';
      case systemTray:
        return 'System Tray';
      case clock:
        return 'Digital Clock';
      case date:
        return 'Calendar Date';
      case weatherSlot:
        return 'Weather Widget';
      case mediaControls:
        return 'Media Player';
      case volumeSlider:
        return 'Volume Control';
      case networkStatus:
        return 'Network Monitor';
      case batteryStatus:
        return 'Battery Status';
      case cpuSparkline:
        return 'CPU Activity Meter';
      case ramSparkline:
        return 'RAM Activity Meter';
      case separator:
        return 'Vertical Divider';
      case spacer:
        return 'Flexible Spacer';
      case quickSettings:
        return 'Quick Actions';
      case customAction:
        return 'Custom Launcher';
      default:
        return type;
    }
  }

  static IconData getIcon(String type) {
    switch (type) {
      case appLauncher:
        return Icons.apps_rounded;
      case pinnedApp:
        return Icons.star_rounded;
      case runningTasks:
        return Icons.layers_rounded;
      case systemTray:
        return Icons.arrow_drop_up_rounded;
      case clock:
        return Icons.access_time_rounded;
      case date:
        return Icons.calendar_today_rounded;
      case weatherSlot:
        return Icons.cloud_rounded;
      case mediaControls:
        return Icons.play_circle_fill_rounded;
      case volumeSlider:
        return Icons.volume_up_rounded;
      case networkStatus:
        return Icons.wifi_rounded;
      case batteryStatus:
        return Icons.battery_charging_full_rounded;
      case cpuSparkline:
        return Icons.memory_rounded;
      case ramSparkline:
        return Icons.storage_rounded;
      case separator:
        return Icons.more_vert_rounded;
      case spacer:
        return Icons.space_bar_rounded;
      case quickSettings:
        return Icons.tune_rounded;
      case customAction:
        return Icons.launch_rounded;
      default:
        return Icons.widgets_rounded;
    }
  }
}

/// Individual item or widget slot placed inside the dock.
class DockItemElement {
  final String id;
  final String type;
  final String label;
  final int iconCodePoint;
  final String? iconFontFamily;
  final bool isPinned;
  final int? customColor;
  final double? customWidth;
  final String actionType;
  final String actionPayload;

  const DockItemElement({
    required this.id,
    required this.type,
    required this.label,
    this.iconCodePoint = 0xe871, // Icons.widgets_rounded default
    this.iconFontFamily,
    this.isPinned = false,
    this.customColor,
    this.customWidth,
    this.actionType = 'default',
    this.actionPayload = '',
  });

  DockItemElement copyWith({
    String? id,
    String? type,
    String? label,
    int? iconCodePoint,
    String? iconFontFamily,
    bool? isPinned,
    int? customColor,
    double? customWidth,
    String? actionType,
    String? actionPayload,
  }) {
    return DockItemElement(
      id: id ?? this.id,
      type: type ?? this.type,
      label: label ?? this.label,
      iconCodePoint: iconCodePoint ?? this.iconCodePoint,
      iconFontFamily: iconFontFamily ?? this.iconFontFamily,
      isPinned: isPinned ?? this.isPinned,
      customColor: customColor ?? this.customColor,
      customWidth: customWidth ?? this.customWidth,
      actionType: actionType ?? this.actionType,
      actionPayload: actionPayload ?? this.actionPayload,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'label': label,
        'iconCodePoint': iconCodePoint,
        'iconFontFamily': iconFontFamily,
        'isPinned': isPinned,
        if (customColor != null) 'customColor': customColor,
        if (customWidth != null) 'customWidth': customWidth,
        'actionType': actionType,
        'actionPayload': actionPayload,
      };

  factory DockItemElement.fromJson(Map<String, dynamic> json) {
    return DockItemElement(
      id: json['id'] as String? ?? UniqueKey().toString(),
      type: json['type'] as String? ?? DockElementType.customAction,
      label: json['label'] as String? ?? '',
      iconCodePoint: (json['iconCodePoint'] as num?)?.toInt() ?? 0xe871,
      iconFontFamily: json['iconFontFamily'] as String?,
      isPinned: json['isPinned'] as bool? ?? false,
      customColor: (json['customColor'] as num?)?.toInt(),
      customWidth: (json['customWidth'] as num?)?.toDouble(),
      actionType: json['actionType'] as String? ?? 'default',
      actionPayload: json['actionPayload'] as String? ?? '',
    );
  }
}

/// Dock layout, sizing, and position configuration.
class DockLayoutConfig {
  final DockPosition position;
  final DockAlignment alignment;
  final double thickness; // Height if top/bottom, Width if left/right
  final double? length; // Fixed length, or null if auto-sized
  final bool autoSize;
  final double edgeOffset; // Distance from display edge
  final double paddingHorizontal;
  final double paddingVertical;
  final double itemSpacing;
  final String multiMonitorTarget; // 'primary', 'all', or monitor index

  const DockLayoutConfig({
    this.position = DockPosition.bottom,
    this.alignment = DockAlignment.center,
    this.thickness = 56.0,
    this.length,
    this.autoSize = true,
    this.edgeOffset = 10.0,
    this.paddingHorizontal = 12.0,
    this.paddingVertical = 8.0,
    this.itemSpacing = 8.0,
    this.multiMonitorTarget = 'primary',
  });

  DockLayoutConfig copyWith({
    DockPosition? position,
    DockAlignment? alignment,
    double? thickness,
    double? length,
    bool? autoSize,
    double? edgeOffset,
    double? paddingHorizontal,
    double? paddingVertical,
    double? itemSpacing,
    String? multiMonitorTarget,
  }) {
    return DockLayoutConfig(
      position: position ?? this.position,
      alignment: alignment ?? this.alignment,
      thickness: thickness ?? this.thickness,
      length: length ?? this.length,
      autoSize: autoSize ?? this.autoSize,
      edgeOffset: edgeOffset ?? this.edgeOffset,
      paddingHorizontal: paddingHorizontal ?? this.paddingHorizontal,
      paddingVertical: paddingVertical ?? this.paddingVertical,
      itemSpacing: itemSpacing ?? this.itemSpacing,
      multiMonitorTarget: multiMonitorTarget ?? this.multiMonitorTarget,
    );
  }

  Map<String, dynamic> toJson() => {
        'position': position.name,
        'alignment': alignment.name,
        'thickness': thickness,
        if (length != null) 'length': length,
        'autoSize': autoSize,
        'edgeOffset': edgeOffset,
        'paddingHorizontal': paddingHorizontal,
        'paddingVertical': paddingVertical,
        'itemSpacing': itemSpacing,
        'multiMonitorTarget': multiMonitorTarget,
      };

  factory DockLayoutConfig.fromJson(Map<String, dynamic> json) {
    DockPosition pos = DockPosition.bottom;
    if (json['position'] == 'top') pos = DockPosition.top;
    if (json['position'] == 'left') pos = DockPosition.left;
    if (json['position'] == 'right') pos = DockPosition.right;

    DockAlignment align = DockAlignment.center;
    if (json['alignment'] == 'start') align = DockAlignment.start;
    if (json['alignment'] == 'end') align = DockAlignment.end;

    return DockLayoutConfig(
      position: pos,
      alignment: align,
      thickness: (json['thickness'] as num?)?.toDouble() ?? 56.0,
      length: (json['length'] as num?)?.toDouble(),
      autoSize: json['autoSize'] as bool? ?? true,
      edgeOffset: (json['edgeOffset'] as num?)?.toDouble() ?? 10.0,
      paddingHorizontal: (json['paddingHorizontal'] as num?)?.toDouble() ?? 12.0,
      paddingVertical: (json['paddingVertical'] as num?)?.toDouble() ?? 8.0,
      itemSpacing: (json['itemSpacing'] as num?)?.toDouble() ?? 8.0,
      multiMonitorTarget: json['multiMonitorTarget'] as String? ?? 'primary',
    );
  }
}

/// Visual appearance: blur, borders, gradients, and shadows.
class DockAppearanceConfig {
  final DockBackgroundStyle style;
  final int backgroundColor;
  final List<int> gradientColors;
  final int borderColor;
  final double borderWidth;
  final double borderRadius;
  final int shadowColor;
  final double shadowBlur;
  final double shadowSpread;
  final double blurIntensity; // Acrylic/glass backdrop blur sigma
  final int activeIndicatorColor;
  final double iconSize;

  const DockAppearanceConfig({
    this.style = DockBackgroundStyle.acrylic,
    this.backgroundColor = 0xDD12151E,
    this.gradientColors = const [0xDD141B2D, 0xDD0D111A],
    this.borderColor = 0x26FFFFFF,
    this.borderWidth = 1.0,
    this.borderRadius = 18.0,
    this.shadowColor = 0x66000000,
    this.shadowBlur = 20.0,
    this.shadowSpread = 2.0,
    this.blurIntensity = 24.0,
    this.activeIndicatorColor = 0xFF38BDF8,
    this.iconSize = 22.0,
  });

  DockAppearanceConfig copyWith({
    DockBackgroundStyle? style,
    int? backgroundColor,
    List<int>? gradientColors,
    int? borderColor,
    double? borderWidth,
    double? borderRadius,
    int? shadowColor,
    double? shadowBlur,
    double? shadowSpread,
    double? blurIntensity,
    int? activeIndicatorColor,
    double? iconSize,
  }) {
    return DockAppearanceConfig(
      style: style ?? this.style,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      gradientColors: gradientColors ?? this.gradientColors,
      borderColor: borderColor ?? this.borderColor,
      borderWidth: borderWidth ?? this.borderWidth,
      borderRadius: borderRadius ?? this.borderRadius,
      shadowColor: shadowColor ?? this.shadowColor,
      shadowBlur: shadowBlur ?? this.shadowBlur,
      shadowSpread: shadowSpread ?? this.shadowSpread,
      blurIntensity: blurIntensity ?? this.blurIntensity,
      activeIndicatorColor: activeIndicatorColor ?? this.activeIndicatorColor,
      iconSize: iconSize ?? this.iconSize,
    );
  }

  Map<String, dynamic> toJson() => {
        'style': style.name,
        'backgroundColor': backgroundColor,
        'gradientColors': gradientColors,
        'borderColor': borderColor,
        'borderWidth': borderWidth,
        'borderRadius': borderRadius,
        'shadowColor': shadowColor,
        'shadowBlur': shadowBlur,
        'shadowSpread': shadowSpread,
        'blurIntensity': blurIntensity,
        'activeIndicatorColor': activeIndicatorColor,
        'iconSize': iconSize,
      };

  factory DockAppearanceConfig.fromJson(Map<String, dynamic> json) {
    DockBackgroundStyle st = DockBackgroundStyle.acrylic;
    switch (json['style']) {
      case 'glass':
        st = DockBackgroundStyle.glass;
        break;
      case 'mica':
        st = DockBackgroundStyle.mica;
        break;
      case 'solid':
        st = DockBackgroundStyle.solid;
        break;
      case 'gradient':
        st = DockBackgroundStyle.gradient;
        break;
      default:
        st = DockBackgroundStyle.acrylic;
    }

    List<int> grad = const [0xDD141B2D, 0xDD0D111A];
    if (json['gradientColors'] is List) {
      grad = (json['gradientColors'] as List).map((e) => (e as num).toInt()).toList();
    }

    return DockAppearanceConfig(
      style: st,
      backgroundColor: (json['backgroundColor'] as num?)?.toInt() ?? 0xDD12151E,
      gradientColors: grad,
      borderColor: (json['borderColor'] as num?)?.toInt() ?? 0x26FFFFFF,
      borderWidth: (json['borderWidth'] as num?)?.toDouble() ?? 1.0,
      borderRadius: (json['borderRadius'] as num?)?.toDouble() ?? 18.0,
      shadowColor: (json['shadowColor'] as num?)?.toInt() ?? 0x66000000,
      shadowBlur: (json['shadowBlur'] as num?)?.toDouble() ?? 20.0,
      shadowSpread: (json['shadowSpread'] as num?)?.toDouble() ?? 2.0,
      blurIntensity: (json['blurIntensity'] as num?)?.toDouble() ?? 24.0,
      activeIndicatorColor: (json['activeIndicatorColor'] as num?)?.toInt() ?? 0xFF38BDF8,
      iconSize: (json['iconSize'] as num?)?.toDouble() ?? 22.0,
    );
  }
}

/// Dock hover magnification, bounce, pulse, and auto-hide animations.
class DockAnimationConfig {
  final bool enableHoverScale;
  final double hoverScaleFactor; // e.g. 1.0 to 2.2
  final double hoverDistance; // Fisheye neighboring influence distance in px
  final double hoverLift; // Y-translation on hover (e.g. -6 to -14 px)
  final bool enableIconBounce;
  final bool enableRunningPulse;
  final int animationDurationMs;
  final String curveName; // 'easeOutBack', 'easeInOutCubic', 'easeOutQuad'
  final bool enableAutoHide;
  final int autoHideDelayMs;
  final bool reducedMotion;

  const DockAnimationConfig({
    this.enableHoverScale = true,
    this.hoverScaleFactor = 1.35,
    this.hoverDistance = 75.0,
    this.hoverLift = 6.0,
    this.enableIconBounce = true,
    this.enableRunningPulse = true,
    this.animationDurationMs = 180,
    this.curveName = 'easeOutCubic',
    this.enableAutoHide = false,
    this.autoHideDelayMs = 1200,
    this.reducedMotion = false,
  });

  DockAnimationConfig copyWith({
    bool? enableHoverScale,
    double? hoverScaleFactor,
    double? hoverDistance,
    double? hoverLift,
    bool? enableIconBounce,
    bool? enableRunningPulse,
    int? animationDurationMs,
    String? curveName,
    bool? enableAutoHide,
    int? autoHideDelayMs,
    bool? reducedMotion,
  }) {
    return DockAnimationConfig(
      enableHoverScale: enableHoverScale ?? this.enableHoverScale,
      hoverScaleFactor: hoverScaleFactor ?? this.hoverScaleFactor,
      hoverDistance: hoverDistance ?? this.hoverDistance,
      hoverLift: hoverLift ?? this.hoverLift,
      enableIconBounce: enableIconBounce ?? this.enableIconBounce,
      enableRunningPulse: enableRunningPulse ?? this.enableRunningPulse,
      animationDurationMs: animationDurationMs ?? this.animationDurationMs,
      curveName: curveName ?? this.curveName,
      enableAutoHide: enableAutoHide ?? this.enableAutoHide,
      autoHideDelayMs: autoHideDelayMs ?? this.autoHideDelayMs,
      reducedMotion: reducedMotion ?? this.reducedMotion,
    );
  }

  Curve get curve {
    switch (curveName) {
      case 'easeOutBack':
        return Curves.easeOutBack;
      case 'easeInOutCubic':
        return Curves.easeInOutCubic;
      case 'easeOutQuad':
        return Curves.easeOutQuad;
      case 'elasticOut':
        return Curves.elasticOut;
      case 'easeOutCubic':
      default:
        return Curves.easeOutCubic;
    }
  }

  Map<String, dynamic> toJson() => {
        'enableHoverScale': enableHoverScale,
        'hoverScaleFactor': hoverScaleFactor,
        'hoverDistance': hoverDistance,
        'hoverLift': hoverLift,
        'enableIconBounce': enableIconBounce,
        'enableRunningPulse': enableRunningPulse,
        'animationDurationMs': animationDurationMs,
        'curveName': curveName,
        'enableAutoHide': enableAutoHide,
        'autoHideDelayMs': autoHideDelayMs,
        'reducedMotion': reducedMotion,
      };

  factory DockAnimationConfig.fromJson(Map<String, dynamic> json) {
    return DockAnimationConfig(
      enableHoverScale: json['enableHoverScale'] as bool? ?? true,
      hoverScaleFactor: (json['hoverScaleFactor'] as num?)?.toDouble() ?? 1.35,
      hoverDistance: (json['hoverDistance'] as num?)?.toDouble() ?? 75.0,
      hoverLift: (json['hoverLift'] as num?)?.toDouble() ?? 6.0,
      enableIconBounce: json['enableIconBounce'] as bool? ?? true,
      enableRunningPulse: json['enableRunningPulse'] as bool? ?? true,
      animationDurationMs: (json['animationDurationMs'] as num?)?.toInt() ?? 180,
      curveName: json['curveName'] as String? ?? 'easeOutCubic',
      enableAutoHide: json['enableAutoHide'] as bool? ?? false,
      autoHideDelayMs: (json['autoHideDelayMs'] as num?)?.toInt() ?? 1200,
      reducedMotion: json['reducedMotion'] as bool? ?? false,
    );
  }
}

/// The complete desktop template model representing a dock/taskbar configuration.
class DesktopStudioTemplate {
  static const String currentSchemaVersion = 'wallsync.dock.template.v1';

  final String id;
  final String name;
  final String author;
  final String version;
  final String description;
  final String category;
  final List<String> tags;
  final String schemaVersion;
  final bool isBuiltIn;
  final DockLayoutConfig layout;
  final DockAppearanceConfig appearance;
  final DockAnimationConfig animation;
  final List<DockItemElement> elements;
  final String createdAt;
  final String updatedAt;

  const DesktopStudioTemplate({
    required this.id,
    required this.name,
    this.author = 'WallSync Design Team',
    this.version = '1.0.0',
    this.description = '',
    this.category = 'Modern',
    this.tags = const ['desktop', 'dock', 'wallsync'],
    this.schemaVersion = currentSchemaVersion,
    this.isBuiltIn = false,
    this.layout = const DockLayoutConfig(),
    this.appearance = const DockAppearanceConfig(),
    this.animation = const DockAnimationConfig(),
    this.elements = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  DesktopStudioTemplate copyWith({
    String? id,
    String? name,
    String? author,
    String? version,
    String? description,
    String? category,
    List<String>? tags,
    String? schemaVersion,
    bool? isBuiltIn,
    DockLayoutConfig? layout,
    DockAppearanceConfig? appearance,
    DockAnimationConfig? animation,
    List<DockItemElement>? elements,
    String? createdAt,
    String? updatedAt,
  }) {
    return DesktopStudioTemplate(
      id: id ?? this.id,
      name: name ?? this.name,
      author: author ?? this.author,
      version: version ?? this.version,
      description: description ?? this.description,
      category: category ?? this.category,
      tags: tags ?? this.tags,
      schemaVersion: schemaVersion ?? this.schemaVersion,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      layout: layout ?? this.layout,
      appearance: appearance ?? this.appearance,
      animation: animation ?? this.animation,
      elements: elements ?? this.elements,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'author': author,
        'version': version,
        'description': description,
        'category': category,
        'tags': tags,
        'schemaVersion': schemaVersion,
        'isBuiltIn': isBuiltIn,
        'layout': layout.toJson(),
        'appearance': appearance.toJson(),
        'animation': animation.toJson(),
        'elements': elements.map((e) => e.toJson()).toList(),
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  String toFormattedJson() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  /// Validates a template JSON map and returns a list of validation errors.
  /// If empty, the template is completely valid.
  static List<String> validate(Map<String, dynamic> json) {
    final errors = <String>[];
    if (json['schemaVersion'] != currentSchemaVersion) {
      errors.add(
        'Incompatible schema version: expected "$currentSchemaVersion", found "${json['schemaVersion']}"',
      );
    }
    if (json['id'] == null || (json['id'] as String).trim().isEmpty) {
      errors.add('Missing or empty template "id".');
    }
    if (json['name'] == null || (json['name'] as String).trim().isEmpty) {
      errors.add('Missing or empty template "name".');
    }
    if (json['elements'] != null && json['elements'] is! List) {
      errors.add('"elements" must be an array.');
    } else if (json['elements'] != null) {
      final list = json['elements'] as List;
      for (int i = 0; i < list.length; i++) {
        final item = list[i];
        if (item is! Map<String, dynamic>) {
          errors.add('Element at index $i is not a valid JSON object.');
        } else if (item['type'] == null || !DockElementType.allTypes.contains(item['type'])) {
          errors.add('Element at index $i has unrecognized type: "${item['type']}".');
        }
      }
    }
    return errors;
  }

  factory DesktopStudioTemplate.fromJson(Map<String, dynamic> json) {
    final elementsList = <DockItemElement>[];
    if (json['elements'] is List) {
      for (final e in (json['elements'] as List)) {
        if (e is Map<String, dynamic>) {
          elementsList.add(DockItemElement.fromJson(e));
        }
      }
    }

    final tagsList = <String>[];
    if (json['tags'] is List) {
      for (final t in (json['tags'] as List)) {
        if (t != null) tagsList.add(t.toString());
      }
    }

    return DesktopStudioTemplate(
      id: json['id'] as String? ?? 'template_${DateTime.now().millisecondsSinceEpoch}',
      name: json['name'] as String? ?? 'Untitled Template',
      author: json['author'] as String? ?? 'WallSync User',
      version: json['version'] as String? ?? '1.0.0',
      description: json['description'] as String? ?? '',
      category: json['category'] as String? ?? 'Modern',
      tags: tagsList.isNotEmpty ? tagsList : const ['desktop', 'dock'],
      schemaVersion: json['schemaVersion'] as String? ?? currentSchemaVersion,
      isBuiltIn: json['isBuiltIn'] as bool? ?? false,
      layout: json['layout'] is Map<String, dynamic>
          ? DockLayoutConfig.fromJson(json['layout'] as Map<String, dynamic>)
          : const DockLayoutConfig(),
      appearance: json['appearance'] is Map<String, dynamic>
          ? DockAppearanceConfig.fromJson(json['appearance'] as Map<String, dynamic>)
          : const DockAppearanceConfig(),
      animation: json['animation'] is Map<String, dynamic>
          ? DockAnimationConfig.fromJson(json['animation'] as Map<String, dynamic>)
          : const DockAnimationConfig(),
      elements: elementsList,
      createdAt: json['createdAt'] as String? ?? DateTime.now().toIso8601String(),
      updatedAt: json['updatedAt'] as String? ?? DateTime.now().toIso8601String(),
    );
  }

  // ===========================================================================
  // BUILT-IN WALLSYNC PRESETS (8 Clean-Room Original Desktop Presets)
  // ===========================================================================

  /// 1. Classic Taskbar
  static DesktopStudioTemplate classicTaskbar() {
    final now = DateTime.now().toIso8601String();
    return DesktopStudioTemplate(
      id: 'wallsync.preset.classic_taskbar',
      name: 'Classic Taskbar',
      author: 'WallSync Team',
      version: '1.0.0',
      description: 'Traditional full-width bottom desktop taskbar with start launcher, task list, system tray, and clock.',
      category: 'Productivity',
      tags: ['classic', 'windows', 'taskbar', 'full-width'],
      isBuiltIn: true,
      layout: const DockLayoutConfig(
        position: DockPosition.bottom,
        alignment: DockAlignment.center,
        thickness: 48.0,
        autoSize: false,
        edgeOffset: 0.0,
        paddingHorizontal: 16.0,
        paddingVertical: 6.0,
        itemSpacing: 6.0,
      ),
      appearance: const DockAppearanceConfig(
        style: DockBackgroundStyle.solid,
        backgroundColor: 0xF210131B,
        borderColor: 0x1FFFFFFF,
        borderWidth: 1.0,
        borderRadius: 0.0,
        shadowColor: 0x4D000000,
        shadowBlur: 16.0,
        blurIntensity: 18.0,
        activeIndicatorColor: 0xFF38BDF8,
        iconSize: 20.0,
      ),
      animation: const DockAnimationConfig(
        enableHoverScale: false,
        hoverScaleFactor: 1.05,
        hoverDistance: 30.0,
        hoverLift: 2.0,
        enableIconBounce: false,
        enableRunningPulse: false,
        animationDurationMs: 120,
      ),
      elements: const [
        DockItemElement(
          id: 'classic_start',
          type: DockElementType.appLauncher,
          label: 'Start Menu',
          iconCodePoint: 0xe871,
        ),
        DockItemElement(
          id: 'classic_tasks',
          type: DockElementType.runningTasks,
          label: 'Active Applications',
        ),
        DockItemElement(
          id: 'classic_spacer',
          type: DockElementType.spacer,
          label: 'Flexible Spacer',
        ),
        DockItemElement(
          id: 'classic_tray',
          type: DockElementType.systemTray,
          label: 'System Notification Area',
        ),
        DockItemElement(
          id: 'classic_net',
          type: DockElementType.networkStatus,
          label: 'Network',
        ),
        DockItemElement(
          id: 'classic_vol',
          type: DockElementType.volumeSlider,
          label: 'Volume',
        ),
        DockItemElement(
          id: 'classic_clock',
          type: DockElementType.clock,
          label: 'Clock',
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 2. Minimal Floating Taskbar
  static DesktopStudioTemplate minimalFloating() {
    final now = DateTime.now().toIso8601String();
    return DesktopStudioTemplate(
      id: 'wallsync.preset.minimal_floating',
      name: 'Minimal Floating Taskbar',
      author: 'WallSync Team',
      version: '1.0.0',
      description: 'Sleek, floating pill container with rounded edges, subtle acrylic blur, and minimal essential controls.',
      category: 'Minimal',
      tags: ['minimal', 'floating', 'acrylic', 'pill'],
      isBuiltIn: true,
      layout: const DockLayoutConfig(
        position: DockPosition.bottom,
        alignment: DockAlignment.center,
        thickness: 50.0,
        autoSize: true,
        edgeOffset: 14.0,
        paddingHorizontal: 16.0,
        paddingVertical: 7.0,
        itemSpacing: 10.0,
      ),
      appearance: const DockAppearanceConfig(
        style: DockBackgroundStyle.acrylic,
        backgroundColor: 0xC8141824,
        borderColor: 0x33FFFFFF,
        borderWidth: 1.2,
        borderRadius: 25.0,
        shadowColor: 0x80000000,
        shadowBlur: 28.0,
        blurIntensity: 30.0,
        activeIndicatorColor: 0xFF06B6D4,
        iconSize: 22.0,
      ),
      animation: const DockAnimationConfig(
        enableHoverScale: true,
        hoverScaleFactor: 1.25,
        hoverDistance: 60.0,
        hoverLift: 4.0,
        enableIconBounce: true,
        enableRunningPulse: true,
        animationDurationMs: 160,
      ),
      elements: const [
        DockItemElement(
          id: 'min_launcher',
          type: DockElementType.appLauncher,
          label: 'WallSync',
          iconCodePoint: 0xe871,
        ),
        DockItemElement(
          id: 'min_sep1',
          type: DockElementType.separator,
          label: 'Divider',
        ),
        DockItemElement(
          id: 'min_tasks',
          type: DockElementType.runningTasks,
          label: 'Tasks',
        ),
        DockItemElement(
          id: 'min_sep2',
          type: DockElementType.separator,
          label: 'Divider',
        ),
        DockItemElement(
          id: 'min_clock',
          type: DockElementType.clock,
          label: 'Clock',
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 3. Centered Dynamic Dock
  static DesktopStudioTemplate centeredDock() {
    final now = DateTime.now().toIso8601String();
    return DesktopStudioTemplate(
      id: 'wallsync.preset.centered_dock',
      name: 'Centered Dynamic Dock',
      author: 'WallSync Team',
      version: '1.0.0',
      description: 'Dynamic centered dock with fisheye hover magnification, running app indicator dots, and smooth icon lift.',
      category: 'Modern',
      tags: ['dock', 'fisheye', 'magnification', 'centered', 'smooth'],
      isBuiltIn: true,
      layout: const DockLayoutConfig(
        position: DockPosition.bottom,
        alignment: DockAlignment.center,
        thickness: 60.0,
        autoSize: true,
        edgeOffset: 12.0,
        paddingHorizontal: 18.0,
        paddingVertical: 8.0,
        itemSpacing: 12.0,
      ),
      appearance: const DockAppearanceConfig(
        style: DockBackgroundStyle.glass,
        backgroundColor: 0xA6182030,
        borderColor: 0x40FFFFFF,
        borderWidth: 1.5,
        borderRadius: 22.0,
        shadowColor: 0x99000000,
        shadowBlur: 32.0,
        shadowSpread: 1.0,
        blurIntensity: 32.0,
        activeIndicatorColor: 0xFF38BDF8,
        iconSize: 26.0,
      ),
      animation: const DockAnimationConfig(
        enableHoverScale: true,
        hoverScaleFactor: 1.48,
        hoverDistance: 90.0,
        hoverLift: 8.0,
        enableIconBounce: true,
        enableRunningPulse: true,
        animationDurationMs: 190,
        curveName: 'easeOutBack',
      ),
      elements: const [
        DockItemElement(
          id: 'dock_launcher',
          type: DockElementType.appLauncher,
          label: 'WallSync',
          iconCodePoint: 0xe871,
        ),
        DockItemElement(
          id: 'dock_pinned1',
          type: DockElementType.pinnedApp,
          label: 'Browser',
          iconCodePoint: 0xe894, // Icons.language
          actionType: 'app',
          actionPayload: 'https://www.google.com',
        ),
        DockItemElement(
          id: 'dock_pinned2',
          type: DockElementType.pinnedApp,
          label: 'Code',
          iconCodePoint: 0xe86f, // Icons.code
          actionType: 'app',
          actionPayload: 'code',
        ),
        DockItemElement(
          id: 'dock_pinned3',
          type: DockElementType.pinnedApp,
          label: 'Terminal',
          iconCodePoint: 0xe853, // Icons.terminal
          actionType: 'app',
          actionPayload: 'wt',
        ),
        DockItemElement(
          id: 'dock_sep',
          type: DockElementType.separator,
          label: 'Divider',
        ),
        DockItemElement(
          id: 'dock_tasks',
          type: DockElementType.runningTasks,
          label: 'Running Apps',
        ),
        DockItemElement(
          id: 'dock_sep2',
          type: DockElementType.separator,
          label: 'Divider',
        ),
        DockItemElement(
          id: 'dock_clock',
          type: DockElementType.clock,
          label: 'Time',
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 4. Bottom Floating Shelf
  static DesktopStudioTemplate floatingShelf() {
    final now = DateTime.now().toIso8601String();
    return DesktopStudioTemplate(
      id: 'wallsync.preset.floating_shelf',
      name: 'Bottom Floating Shelf',
      author: 'WallSync Team',
      version: '1.0.0',
      description: 'Spacious floating shelf organizing apps on the left, media playback center, and system vitals on the right.',
      category: 'Productivity',
      tags: ['shelf', 'spacious', 'media', 'productivity'],
      isBuiltIn: true,
      layout: const DockLayoutConfig(
        position: DockPosition.bottom,
        alignment: DockAlignment.center,
        thickness: 54.0,
        autoSize: true,
        edgeOffset: 16.0,
        paddingHorizontal: 20.0,
        paddingVertical: 8.0,
        itemSpacing: 12.0,
      ),
      appearance: const DockAppearanceConfig(
        style: DockBackgroundStyle.acrylic,
        backgroundColor: 0xD0121722,
        borderColor: 0x2EFFFFFF,
        borderWidth: 1.2,
        borderRadius: 20.0,
        shadowColor: 0x73000000,
        shadowBlur: 24.0,
        blurIntensity: 26.0,
        activeIndicatorColor: 0xFF10B981,
        iconSize: 22.0,
      ),
      animation: const DockAnimationConfig(
        enableHoverScale: true,
        hoverScaleFactor: 1.28,
        hoverDistance: 65.0,
        hoverLift: 5.0,
        enableIconBounce: true,
        enableRunningPulse: false,
        animationDurationMs: 160,
      ),
      elements: const [
        DockItemElement(
          id: 'shelf_launcher',
          type: DockElementType.appLauncher,
          label: 'WallSync',
          iconCodePoint: 0xe871,
        ),
        DockItemElement(
          id: 'shelf_tasks',
          type: DockElementType.runningTasks,
          label: 'Open Windows',
        ),
        DockItemElement(
          id: 'shelf_sep1',
          type: DockElementType.separator,
          label: 'Divider',
        ),
        DockItemElement(
          id: 'shelf_media',
          type: DockElementType.mediaControls,
          label: 'Now Playing',
        ),
        DockItemElement(
          id: 'shelf_sep2',
          type: DockElementType.separator,
          label: 'Divider',
        ),
        DockItemElement(
          id: 'shelf_cpu',
          type: DockElementType.cpuSparkline,
          label: 'CPU',
        ),
        DockItemElement(
          id: 'shelf_ram',
          type: DockElementType.ramSparkline,
          label: 'RAM',
        ),
        DockItemElement(
          id: 'shelf_clock',
          type: DockElementType.clock,
          label: 'Clock',
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 5. Top Desktop Bar
  static DesktopStudioTemplate topDesktopBar() {
    final now = DateTime.now().toIso8601String();
    return DesktopStudioTemplate(
      id: 'wallsync.preset.top_desktop_bar',
      name: 'Top Desktop Bar',
      author: 'WallSync Team',
      version: '1.0.0',
      description: 'Streamlined top panel with date/time centered, quick launchers on the left, and hardware vitals on the right.',
      category: 'Productivity',
      tags: ['top-bar', 'panel', 'streamlined', 'modern'],
      isBuiltIn: true,
      layout: const DockLayoutConfig(
        position: DockPosition.top,
        alignment: DockAlignment.center,
        thickness: 38.0,
        autoSize: false,
        edgeOffset: 0.0,
        paddingHorizontal: 16.0,
        paddingVertical: 4.0,
        itemSpacing: 8.0,
      ),
      appearance: const DockAppearanceConfig(
        style: DockBackgroundStyle.solid,
        backgroundColor: 0xEE0B0E14,
        borderColor: 0x1FFFFFFF,
        borderWidth: 0.8,
        borderRadius: 0.0,
        shadowColor: 0x59000000,
        shadowBlur: 14.0,
        blurIntensity: 16.0,
        activeIndicatorColor: 0xFF6366F1,
        iconSize: 18.0,
      ),
      animation: const DockAnimationConfig(
        enableHoverScale: false,
        hoverScaleFactor: 1.1,
        hoverDistance: 35.0,
        hoverLift: 1.0,
        enableIconBounce: false,
        enableRunningPulse: true,
        animationDurationMs: 140,
      ),
      elements: const [
        DockItemElement(
          id: 'top_launcher',
          type: DockElementType.appLauncher,
          label: 'WallSync Pro',
          iconCodePoint: 0xe871,
        ),
        DockItemElement(
          id: 'top_tasks',
          type: DockElementType.runningTasks,
          label: 'Tasks',
        ),
        DockItemElement(
          id: 'top_spacer1',
          type: DockElementType.spacer,
          label: 'Spacer',
        ),
        DockItemElement(
          id: 'top_date',
          type: DockElementType.date,
          label: 'Date',
        ),
        DockItemElement(
          id: 'top_clock',
          type: DockElementType.clock,
          label: 'Time',
        ),
        DockItemElement(
          id: 'top_spacer2',
          type: DockElementType.spacer,
          label: 'Spacer',
        ),
        DockItemElement(
          id: 'top_weather',
          type: DockElementType.weatherSlot,
          label: 'Weather',
        ),
        DockItemElement(
          id: 'top_net',
          type: DockElementType.networkStatus,
          label: 'Net',
        ),
        DockItemElement(
          id: 'top_vol',
          type: DockElementType.volumeSlider,
          label: 'Volume',
        ),
        DockItemElement(
          id: 'top_quick',
          type: DockElementType.quickSettings,
          label: 'Settings',
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 6. Compact Application Launcher
  static DesktopStudioTemplate compactLauncher() {
    final now = DateTime.now().toIso8601String();
    return DesktopStudioTemplate(
      id: 'wallsync.preset.compact_launcher',
      name: 'Compact Application Launcher',
      author: 'WallSync Team',
      version: '1.0.0',
      description: 'Ultra-compact quick launcher widget designed to be positioned in screen corners or side edges.',
      category: 'Compact',
      tags: ['compact', 'launcher', 'minimal', 'corner'],
      isBuiltIn: true,
      layout: const DockLayoutConfig(
        position: DockPosition.bottom,
        alignment: DockAlignment.start,
        thickness: 52.0,
        autoSize: true,
        edgeOffset: 16.0,
        paddingHorizontal: 12.0,
        paddingVertical: 6.0,
        itemSpacing: 8.0,
      ),
      appearance: const DockAppearanceConfig(
        style: DockBackgroundStyle.glass,
        backgroundColor: 0xB8111622,
        borderColor: 0x3DFFFFFF,
        borderWidth: 1.2,
        borderRadius: 16.0,
        shadowColor: 0x8A000000,
        shadowBlur: 24.0,
        blurIntensity: 28.0,
        activeIndicatorColor: 0xFFF59E0B,
        iconSize: 22.0,
      ),
      animation: const DockAnimationConfig(
        enableHoverScale: true,
        hoverScaleFactor: 1.3,
        hoverDistance: 60.0,
        hoverLift: 4.0,
        enableIconBounce: true,
        enableRunningPulse: false,
        animationDurationMs: 150,
      ),
      elements: const [
        DockItemElement(
          id: 'compact_launcher',
          type: DockElementType.appLauncher,
          label: 'WallSync',
          iconCodePoint: 0xe871,
        ),
        DockItemElement(
          id: 'compact_browser',
          type: DockElementType.pinnedApp,
          label: 'Browser',
          iconCodePoint: 0xe894,
        ),
        DockItemElement(
          id: 'compact_files',
          type: DockElementType.pinnedApp,
          label: 'Explorer',
          iconCodePoint: 0xe2c7, // Icons.folder
        ),
        DockItemElement(
          id: 'compact_quick',
          type: DockElementType.quickSettings,
          label: 'Quick Actions',
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 7. Widget-Focused Desktop Bar
  static DesktopStudioTemplate widgetFocusedBar() {
    final now = DateTime.now().toIso8601String();
    return DesktopStudioTemplate(
      id: 'wallsync.preset.widget_focused_bar',
      name: 'Widget-Focused Desktop Bar',
      author: 'WallSync Team',
      version: '1.0.0',
      description: 'Vitals and information dashboard bar with live CPU/RAM sparklines, weather forecast, and interactive media controls.',
      category: 'Gaming',
      tags: ['gaming', 'hardware', 'metrics', 'widgets', 'media'],
      isBuiltIn: true,
      layout: const DockLayoutConfig(
        position: DockPosition.bottom,
        alignment: DockAlignment.center,
        thickness: 56.0,
        autoSize: true,
        edgeOffset: 12.0,
        paddingHorizontal: 20.0,
        paddingVertical: 8.0,
        itemSpacing: 14.0,
      ),
      appearance: const DockAppearanceConfig(
        style: DockBackgroundStyle.gradient,
        backgroundColor: 0xDB0F172A,
        gradientColors: [0xDD0F172A, 0xDD1E1B4B],
        borderColor: 0x4738BDF8,
        borderWidth: 1.4,
        borderRadius: 22.0,
        shadowColor: 0x99000000,
        shadowBlur: 30.0,
        blurIntensity: 28.0,
        activeIndicatorColor: 0xFF38BDF8,
        iconSize: 22.0,
      ),
      animation: const DockAnimationConfig(
        enableHoverScale: true,
        hoverScaleFactor: 1.25,
        hoverDistance: 65.0,
        hoverLift: 5.0,
        enableIconBounce: true,
        enableRunningPulse: true,
        animationDurationMs: 170,
      ),
      elements: const [
        DockItemElement(
          id: 'vitals_launcher',
          type: DockElementType.appLauncher,
          label: 'WallSync',
          iconCodePoint: 0xe871,
        ),
        DockItemElement(
          id: 'vitals_sep1',
          type: DockElementType.separator,
          label: 'Divider',
        ),
        DockItemElement(
          id: 'vitals_cpu',
          type: DockElementType.cpuSparkline,
          label: 'CPU Usage',
        ),
        DockItemElement(
          id: 'vitals_ram',
          type: DockElementType.ramSparkline,
          label: 'RAM Usage',
        ),
        DockItemElement(
          id: 'vitals_sep2',
          type: DockElementType.separator,
          label: 'Divider',
        ),
        DockItemElement(
          id: 'vitals_weather',
          type: DockElementType.weatherSlot,
          label: 'Weather Forecast',
        ),
        DockItemElement(
          id: 'vitals_sep3',
          type: DockElementType.separator,
          label: 'Divider',
        ),
        DockItemElement(
          id: 'vitals_media',
          type: DockElementType.mediaControls,
          label: 'Active Media',
        ),
        DockItemElement(
          id: 'vitals_clock',
          type: DockElementType.clock,
          label: 'Current Time',
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
  }

  /// 8. Fully Custom Layout
  static DesktopStudioTemplate customLayout() {
    final now = DateTime.now().toIso8601String();
    return DesktopStudioTemplate(
      id: 'wallsync.preset.custom_layout',
      name: 'Custom Studio Canvas',
      author: 'WallSync Team',
      version: '1.0.0',
      description: 'Blank starting layout ready for user customization with elements, custom spacing, and bespoke styling.',
      category: 'Custom',
      tags: ['blank', 'custom', 'starter'],
      isBuiltIn: true,
      layout: const DockLayoutConfig(
        position: DockPosition.bottom,
        alignment: DockAlignment.center,
        thickness: 54.0,
        autoSize: true,
        edgeOffset: 12.0,
        paddingHorizontal: 16.0,
        paddingVertical: 8.0,
        itemSpacing: 10.0,
      ),
      appearance: const DockAppearanceConfig(
        style: DockBackgroundStyle.acrylic,
        backgroundColor: 0xCC151926,
        borderColor: 0x30FFFFFF,
        borderWidth: 1.0,
        borderRadius: 20.0,
        shadowColor: 0x73000000,
        shadowBlur: 24.0,
        blurIntensity: 24.0,
        activeIndicatorColor: 0xFFEC4899,
        iconSize: 22.0,
      ),
      animation: const DockAnimationConfig(
        enableHoverScale: true,
        hoverScaleFactor: 1.35,
        hoverDistance: 70.0,
        hoverLift: 6.0,
        enableIconBounce: true,
        enableRunningPulse: true,
        animationDurationMs: 180,
      ),
      elements: const [
        DockItemElement(
          id: 'custom_start',
          type: DockElementType.appLauncher,
          label: 'Launcher',
          iconCodePoint: 0xe871,
        ),
        DockItemElement(
          id: 'custom_tasks',
          type: DockElementType.runningTasks,
          label: 'Tasks',
        ),
        DockItemElement(
          id: 'custom_sep',
          type: DockElementType.separator,
          label: 'Divider',
        ),
        DockItemElement(
          id: 'custom_clock',
          type: DockElementType.clock,
          label: 'Clock',
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Returns all 8 built-in presets.
  static List<DesktopStudioTemplate> get builtInPresets => [
        centeredDock(),
        minimalFloating(),
        floatingShelf(),
        classicTaskbar(),
        topDesktopBar(),
        widgetFocusedBar(),
        compactLauncher(),
        customLayout(),
      ];
}
