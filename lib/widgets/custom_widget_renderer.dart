import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/settings_service.dart';
import '../services/media_session_service.dart';
import '../services/system_metrics_service.dart';

/// Reusable renderer for custom widget layouts.
/// Used both in live overlay [DesktopWidget] and in the interactive [CustomWidgetBuilder] canvas.
class CustomWidgetRenderer extends StatelessWidget {
  final List<CustomWidgetElement> elements;
  final DateTime dateTime;
  final double? cpuUsage;
  final double? ramUsage;
  final String weatherTemp;
  final String weatherStatus;
  final String weatherLocation;
  final String weatherApparentTemp;
  final String weatherHumidity;
  final String weatherForecastJson;
  final MediaInfo? mediaInfo;
  final Uint8List? mediaThumbnailBytes;
  final BatterySnapshot? batteryInfo;
  final DiskSnapshot? diskInfo;
  final bool enableMediaControls;
  final ValueListenable<int>? mediaPosition;
  final bool? wifiEnabled;
  final bool? bluetoothEnabled;
  final Future<void> Function(bool enabled)? onWifiToggle;
  final Future<void> Function(bool enabled)? onBluetoothToggle;
  final bool isInteractive;
  final String? selectedElementId;
  final ValueChanged<String>? onSelectElement;
  final Function(String id, double dx, double dy)? onElementMoved;
  final ValueChanged<String>? onDeleteElement;
  final ValueChanged<String>? onDuplicateElement;
  final double canvasWidth;
  final double canvasHeight;

  const CustomWidgetRenderer({
    super.key,
    required this.elements,
    required this.dateTime,
    this.cpuUsage,
    this.ramUsage,
    this.weatherTemp = '',
    this.weatherStatus = '',
    this.weatherLocation = '',
    this.weatherApparentTemp = '',
    this.weatherHumidity = '',
    this.weatherForecastJson = '',
    this.mediaInfo,
    this.mediaThumbnailBytes,
    this.batteryInfo,
    this.diskInfo,
    this.enableMediaControls = false,
    this.mediaPosition,
    this.wifiEnabled,
    this.bluetoothEnabled,
    this.onWifiToggle,
    this.onBluetoothToggle,
    this.isInteractive = false,
    this.selectedElementId,
    this.onSelectElement,
    this.onElementMoved,
    this.onDeleteElement,
    this.onDuplicateElement,
    this.canvasWidth = 480.0,
    this.canvasHeight = 260.0,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: (elements.toList()..sort((a, b) => a.depth.compareTo(b.depth)))
          .map((elem) {
            final isSelected = isInteractive && elem.id == selectedElementId;
            final rendered = _buildElement(context, elem);
            final elementContent = _buildElementContent(elem, rendered);

            if (!isInteractive) {
              return Positioned(
                left: elem.x,
                top: elem.y,
                child: Opacity(
                  opacity: elem.opacity.clamp(0.0, 1.0),
                  child: elementContent,
                ),
              );
            }

            // Interactive canvas element with dragging & selection
            return Positioned(
              left: elem.x,
              top: elem.y,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  onSelectElement?.call(elem.id);
                },
                onPanUpdate: (details) {
                  final newX = (elem.x + details.delta.dx).clamp(
                    0.0,
                    canvasWidth - 20.0,
                  );
                  final newY = (elem.y + details.delta.dy).clamp(
                    0.0,
                    canvasHeight - 20.0,
                  );
                  onElementMoved?.call(elem.id, newX, newY);
                },
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFF38BDF8)
                          : Colors.white.withValues(alpha: 0.12),
                      width: isSelected ? 1.8 : 0.8,
                    ),
                    borderRadius: BorderRadius.circular(6),
                    color: isSelected
                        ? const Color(0xFF38BDF8).withValues(alpha: 0.08)
                        : Colors.transparent,
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: Opacity(
                          opacity: elem.opacity.clamp(0.0, 1.0),
                          child: elementContent,
                        ),
                      ),
                      if (isSelected) ...[
                        // Selection handle at top-right
                        Positioned(
                          right: -8,
                          top: -8,
                          child: Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: const Color(0xFF38BDF8),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white,
                                width: 1.5,
                              ),
                            ),
                            child: const Icon(
                              Icons.open_with_rounded,
                              size: 9,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          })
          .toList(),
    );
  }

  Widget _buildElementContent(CustomWidgetElement element, Widget child) {
    final clipped = element.cornerRadius > 0
        ? ClipRRect(
            borderRadius: BorderRadius.circular(element.cornerRadius),
            child: child,
          )
        : child;
    final transform = Matrix4.identity()
      ..setEntry(3, 2, 0.001)
      ..translateByDouble(0, 0, element.depth, 1)
      ..rotateX(element.rotationX * math.pi / 180)
      ..rotateY(element.rotationY * math.pi / 180)
      ..rotateZ(element.rotation * math.pi / 180)
      ..scaleByDouble(element.scaleX, element.scaleY, 1, 1);
    return Transform(
      alignment: Alignment.center,
      transform: transform,
      child: _AnimatedElement(
        animationType: element.animationType,
        child: clipped,
      ),
    );
  }

  Widget _buildElement(BuildContext context, CustomWidgetElement elem) {
    switch (elem.type) {
      case 'hours':
        final hoursStr = DateFormat('hh').format(dateTime);
        return _styledText(hoursStr, elem);

      case 'minutes':
        final minStr = DateFormat('mm').format(dateTime);
        return _styledText(minStr, elem);

      case 'seconds':
        final secStr = DateFormat('ss').format(dateTime);
        return _styledText(secStr, elem);

      case 'time_colon':
        final colonText = elem.text.isNotEmpty ? elem.text : ':';
        return _styledText(colonText, elem);

      case 'ampm':
        final ampmStr = DateFormat('a').format(dateTime).toUpperCase();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Color(elem.color).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: Color(elem.color).withValues(alpha: 0.4),
              width: 1,
            ),
          ),
          child: _styledText(ampmStr, elem),
        );

      case 'full_time':
        final fullTime = DateFormat('hh:mm:ss a').format(dateTime);
        return _styledText(fullTime, elem);

      case 'day':
        final dayStr = DateFormat('EEEE').format(dateTime).toUpperCase();
        return _styledText(dayStr, elem);

      case 'date':
        final dateNum = '${dateTime.day}';
        return _styledText(dateNum, elem);

      case 'month':
        final monthStr = DateFormat('MMMM').format(dateTime).toUpperCase();
        return _styledText(monthStr, elem);

      case 'year':
        final yearStr = '${dateTime.year}';
        return _styledText(yearStr, elem);

      case 'full_date':
        final dayNum = DateFormat('d').format(dateTime);
        final monthName = DateFormat('MMMM').format(dateTime).toUpperCase();
        final yearNum = DateFormat('yyyy').format(dateTime);
        final fullDate = '$dayNum $monthName $yearNum';
        return _styledText(fullDate, elem);

      case 'fluent_calendar':
        return _FluentCalendarWidget(
          dateTime: dateTime,
          width: elem.width > 0 ? elem.width : 300,
          height: elem.height > 0 ? elem.height : 260,
          accentColor: Color(elem.color),
          selectedColor: Color(elem.activeColor ?? elem.color),
          fontFamily: elem.fontFamily,
          allowInteraction: !isInteractive,
        );

      case 'accent_bar':
        return Container(
          width: elem.width > 0 ? elem.width : 64.0,
          height: elem.height > 0 ? elem.height : 4.0,
          decoration: BoxDecoration(
            color: Color(elem.color),
            borderRadius: BorderRadius.circular(elem.height / 2),
            boxShadow: [
              BoxShadow(
                color: Color(elem.color).withValues(alpha: 0.5),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
        );

      case 'glow_outer':
        return Container(
          width: elem.width > 0 ? elem.width : 160,
          height: elem.height > 0 ? elem.height : 80,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Color(elem.color).withValues(alpha: 0.18),
                blurRadius: 16,
                spreadRadius: 1,
              ),
            ],
          ),
        );

      case 'holo_panel':
        return _HoloPanel(
          width: elem.width > 0 ? elem.width : 320,
          height: elem.height > 0 ? elem.height : 180,
          color: Color(elem.color),
        );

      case 'cpu_bar':
        return _buildUsageBar(
          label: 'CPU',
          percentage: cpuUsage,
          icon: Icons.memory_rounded,
          color: Color(elem.color),
          width: elem.width > 0 ? elem.width : 180.0,
          fontFamily: elem.fontFamily,
          fontSize: elem.fontSize,
          detail: 'Current load',
        );

      case 'ram_bar':
        return _buildUsageBar(
          label: 'RAM',
          percentage: ramUsage,
          icon: Icons.storage_rounded,
          color: Color(elem.color),
          width: elem.width > 0 ? elem.width : 180.0,
          fontFamily: elem.fontFamily,
          fontSize: elem.fontSize,
          detail: 'Memory in use',
        );

      case 'space_bar':
        return _buildUsageBar(
          label: diskInfo == null
              ? 'SPACE'
              : '${diskInfo!.drive.toUpperCase()} SPACE',
          percentage: diskInfo?.usedPercentage,
          icon: Icons.pie_chart_outline_rounded,
          color: Color(elem.color),
          width: elem.width > 0 ? elem.width : 180.0,
          fontFamily: elem.fontFamily,
          fontSize: elem.fontSize,
          detail: diskInfo == null
              ? 'Unavailable'
              : '${_formatBytes(diskInfo!.usedBytes)} used / ${_formatBytes(diskInfo!.totalBytes)} · ${_formatBytes(diskInfo!.freeBytes)} free',
        );

      case 'battery_bar':
        return _buildUsageBar(
          label: 'BATTERY',
          percentage: batteryInfo?.percentage?.toDouble(),
          icon: batteryInfo?.isCharging == true
              ? Icons.battery_charging_full_rounded
              : Icons.battery_std_rounded,
          color: Color(elem.color),
          width: elem.width > 0 ? elem.width : 180.0,
          fontFamily: elem.fontFamily,
          fontSize: elem.fontSize,
          detail: batteryInfo == null
              ? 'Unavailable'
              : [
                  batteryInfo!.status,
                  if (batteryInfo!.remainingLabel != null)
                    batteryInfo!.remainingLabel!,
                ].join(' · '),
        );

      case 'weather_temp':
        final tempStr = weatherTemp.isNotEmpty
            ? '${_formatWeatherTemperature(weatherTemp, elem.weatherUnit)}°${elem.weatherUnit}'
            : '—';
        return _styledText(tempStr, elem);

      case 'weather_status':
        final statusStr = weatherStatus.isNotEmpty
            ? weatherStatus.toUpperCase()
            : 'WEATHER UNAVAILABLE';
        return _styledText(statusStr, elem);

      case 'weather_location':
        return _styledText(
          weatherLocation.isNotEmpty ? weatherLocation : 'LOCATION UNAVAILABLE',
          elem,
        );

      case 'weather_feels_like':
        return _styledText(
          weatherApparentTemp.isNotEmpty
              ? 'FEELS LIKE ${_formatWeatherTemperature(weatherApparentTemp, elem.weatherUnit)}°${elem.weatherUnit}'
              : 'FEELS LIKE —',
          elem,
        );

      case 'weather_humidity':
        return _styledText(
          weatherHumidity.isNotEmpty
              ? 'HUMIDITY $weatherHumidity%'
              : 'HUMIDITY —',
          elem,
        );

      case 'weather_forecast':
        return _buildWeatherForecast(elem);

      case 'weather_icon':
        return Icon(
          _getWeatherIconData(weatherStatus),
          color: Color(elem.color),
          size: elem.width > 0 ? elem.width : elem.fontSize * 1.5,
        );

      case 'weather_pill':
        return Container(
          width: elem.width > 0 ? elem.width : 190.0,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Color(elem.color).withValues(alpha: 0.25),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _getWeatherIconData(weatherStatus),
                color: Color(elem.color),
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                weatherTemp.isNotEmpty
                    ? '${_formatWeatherTemperature(weatherTemp, elem.weatherUnit)}°${elem.weatherUnit}'
                    : '—',
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: elem.fontFamily,
                  fontSize: elem.fontSize,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  weatherStatus.isNotEmpty
                      ? weatherStatus.toUpperCase()
                      : 'WEATHER UNAVAILABLE',
                  style: TextStyle(
                    color: Colors.white70,
                    fontFamily: elem.fontFamily,
                    fontSize: elem.fontSize * 0.85,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );

      case 'media_pill':
        return _buildMediaPill(elem);

      case 'media_title':
        return _buildMediaText(_mediaTitle, elem);

      case 'media_artist':
        return _buildMediaText(mediaInfo?.artist ?? '', elem);

      case 'media_album':
        return _buildMediaText(mediaInfo?.album ?? '', elem);

      case 'media_source':
        return _buildMediaText(mediaInfo?.source ?? '', elem);

      case 'media_status':
        final status = mediaInfo?.status ?? 'Idle';
        return _buildMediaText(
          status.toLowerCase() == 'closed' ? 'Idle' : status,
          elem,
        );

      case 'media_artwork':
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: elem.width > 0 ? elem.width : 64,
            height: elem.height > 0 ? elem.height : 64,
            child: mediaThumbnailBytes == null
                ? ColoredBox(
                    color: Color(elem.color).withValues(alpha: 0.15),
                    child: Icon(
                      mediaInfo?.title.isNotEmpty == true
                          ? Icons.album_rounded
                          : Icons.music_off_rounded,
                      color: Color(elem.color),
                    ),
                  )
                : Image.memory(
                    mediaThumbnailBytes!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stackTrace) => ColoredBox(
                      color: Color(elem.color).withValues(alpha: 0.15),
                      child: Icon(
                        Icons.album_rounded,
                        color: Color(elem.color),
                      ),
                    ),
                  ),
          ),
        );

      case 'media_progress':
        final duration = mediaInfo?.duration ?? 0;
        if (mediaInfo?.hasDuration != true ||
            mediaInfo?.hasPosition != true ||
            duration <= 0) {
          return const SizedBox.shrink();
        }
        Widget progressFor(int position) => SizedBox(
          width: elem.width > 0 ? elem.width : 180,
          child: LinearProgressIndicator(
            value: (position / duration).clamp(0.0, 1.0),
            minHeight: elem.height > 0 ? elem.height : 4,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation<Color>(Color(elem.color)),
          ),
        );
        final positionListenable = mediaPosition;
        return positionListenable == null
            ? progressFor(mediaInfo?.position ?? 0)
            : ValueListenableBuilder<int>(
                valueListenable: positionListenable,
                builder: (context, position, _) => progressFor(position),
              );

      case 'media_elapsed':
      case 'media_duration':
        final isElapsed = elem.type == 'media_elapsed';
        if (isElapsed
            ? mediaInfo?.hasPosition != true
            : mediaInfo?.hasDuration != true) {
          return const SizedBox.shrink();
        }
        final time = isElapsed
            ? mediaInfo?.position ?? 0
            : mediaInfo?.duration ?? 0;
        if (!isElapsed && (mediaInfo?.duration ?? 0) <= 0) {
          return const SizedBox.shrink();
        }
        if (!isElapsed || mediaPosition == null) {
          return _buildMediaText(_formatMediaTime(time), elem);
        }
        return ValueListenableBuilder<int>(
          valueListenable: mediaPosition!,
          builder: (context, position, _) =>
              _buildMediaText(_formatMediaTime(position), elem),
        );

      case 'media_controls':
        if (!enableMediaControls || isInteractive) {
          return Icon(
            Icons.play_circle_outline_rounded,
            color: Color(elem.color),
            size: elem.fontSize * 1.5,
          );
        }
        return Wrap(
          spacing: 0,
          children: _buildMediaControlButtons(Color(elem.color), compact: true),
        );

      case 'media_animation':
        return mediaInfo?.isPlaying == true
            ? _MediaActivityIndicator(color: Color(elem.color))
            : const SizedBox.shrink();

      case 'wifi_icon':
        return _buildConnectivityIcon(
          elem: elem,
          enabled: wifiEnabled,
          activeIcon: Icons.wifi_rounded,
          disabledIcon: Icons.wifi_off_rounded,
          onToggle: onWifiToggle,
        );

      case 'bluetooth_icon':
        return _buildConnectivityIcon(
          elem: elem,
          enabled: bluetoothEnabled,
          activeIcon: Icons.bluetooth_rounded,
          disabledIcon: Icons.bluetooth_disabled_rounded,
          onToggle: onBluetoothToggle,
        );

      case 'neon_box':
        return Container(
          width: elem.width > 0 ? elem.width : 160.0,
          height: elem.height > 0 ? elem.height : 80.0,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Color(elem.color).withValues(alpha: 0.6),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Color(elem.color).withValues(alpha: 0.2),
                blurRadius: 16,
                spreadRadius: 2,
              ),
            ],
          ),
        );

      case 'custom_text':
      default:
        final display = elem.text.isNotEmpty ? elem.text : 'WallSync Widget';
        return _styledText(display, elem);
    }
  }

  Widget _buildWeatherForecast(CustomWidgetElement elem) {
    final forecastJson = weatherForecastJson.trim();
    if (forecastJson.isEmpty) return _styledText('FORECAST UNAVAILABLE', elem);

    try {
      final decoded = jsonDecode(forecastJson);
      if (decoded is! List) return _styledText('FORECAST UNAVAILABLE', elem);
      final forecasts = decoded
          .whereType<Map>()
          .take(3)
          .map((item) {
            final time = item['time']?.toString() ?? '';
            final temperature = item['temp']?.toString() ?? '';
            final status = item['status']?.toString() ?? '';
            return [
              time,
              temperature.isEmpty
                  ? ''
                  : '${_formatWeatherTemperature(temperature, elem.weatherUnit)}°${elem.weatherUnit}',
              status,
            ].where((part) => part.isNotEmpty).join('  ·  ');
          })
          .where((line) => line.isNotEmpty)
          .toList(growable: false);
      if (forecasts.isEmpty) {
        return _styledText('FORECAST UNAVAILABLE', elem);
      }
      return SizedBox(
        width: elem.width > 0 ? elem.width : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: forecasts
              .map((line) => _styledText(line, elem))
              .toList(growable: false),
        ),
      );
    } on FormatException catch (error) {
      debugPrint('CustomWidgetRenderer: Invalid weather forecast data: $error');
      return _styledText('FORECAST UNAVAILABLE', elem);
    }
  }

  Widget _buildConnectivityIcon({
    required CustomWidgetElement elem,
    required bool? enabled,
    required IconData activeIcon,
    required IconData disabledIcon,
    required Future<void> Function(bool enabled)? onToggle,
  }) {
    final isEnabled = enabled == true;
    final color = Color(
      enabled == null
          ? elem.color
          : isEnabled
          ? (elem.activeColor ?? elem.color)
          : (elem.disabledColor ?? elem.color),
    );
    final iconSize = elem.width > 0
        ? elem.width
        : (elem.fontSize > 0 ? elem.fontSize : 22.0);
    final icon = Icon(
      enabled == false ? disabledIcon : activeIcon,
      color: color,
      size: iconSize,
    );
    if (enabled == null) {
      return Tooltip(message: 'Adapter status unavailable', child: icon);
    }
    if (onToggle == null || isInteractive) return icon;
    return Tooltip(
      message:
          '${elem.type == 'wifi_icon' ? 'Wi-Fi' : 'Bluetooth'} '
          '${isEnabled ? 'on' : 'off'} — click to ${isEnabled ? 'turn off' : 'turn on'}',
      child: InkWell(
        onTap: () => onToggle(!isEnabled),
        borderRadius: BorderRadius.circular(6),
        child: icon,
      ),
    );
  }

  Widget _styledText(String text, CustomWidgetElement elem) {
    final shadows = elem.shadowBlur > 0
        ? [
            Shadow(
              color: Color(
                elem.shadowColor ?? elem.color,
              ).withValues(alpha: 0.65),
              blurRadius: elem.shadowBlur,
              offset: Offset(elem.shadowOffsetX, elem.shadowOffsetY),
            ),
          ]
        : null;
    Text textLayer({required Paint? foreground, Color? color}) => Text(
      text,
      style: TextStyle(
        fontFamily: elem.fontFamily,
        fontSize: elem.fontSize,
        fontWeight: elem.isBold ? FontWeight.bold : FontWeight.normal,
        color: color,
        foreground: foreground,
        letterSpacing: elem.letterSpacing,
        shadows: shadows,
      ),
    );

    Widget fill = textLayer(foreground: null, color: Color(elem.color));
    if (elem.gradientColors != null && elem.gradientColors!.length > 1) {
      final gradient = elem.gradientRadial
          ? RadialGradient(colors: elem.gradientColors!.map(Color.new).toList())
          : LinearGradient(
              colors: elem.gradientColors!.map(Color.new).toList(),
            );
      fill = ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) => gradient.createShader(bounds),
        child: textLayer(foreground: null, color: Colors.white),
      );
    }

    if (elem.strokeWidth > 0) {
      final outline = textLayer(
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = elem.strokeWidth
          ..color = Color(elem.strokeColor ?? elem.color),
      );
      fill = Stack(alignment: Alignment.centerLeft, children: [outline, fill]);
    }

    return SizedBox(width: elem.width > 0 ? elem.width : null, child: fill);
  }

  Widget _buildMediaText(String text, CustomWidgetElement elem) {
    if (text.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: elem.width > 0 ? elem.width : null,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: elem.fontFamily,
          fontSize: elem.fontSize,
          fontWeight: elem.isBold ? FontWeight.bold : FontWeight.normal,
          color: Color(elem.color),
          letterSpacing: elem.letterSpacing,
        ),
      ),
    );
  }

  String get _mediaTitle {
    if (mediaInfo?.title.isNotEmpty == true) return mediaInfo!.title;
    if (mediaInfo?.source.isNotEmpty == true) return mediaInfo!.source;
    if (mediaInfo != null && mediaInfo!.status.toLowerCase() != 'closed') {
      return 'Media metadata unavailable';
    }
    return 'No media playing';
  }

  Widget _buildMediaPill(CustomWidgetElement elem) {
    final hasTrackTitle = mediaInfo?.title.isNotEmpty == true;
    final hasMedia =
        hasTrackTitle ||
        mediaInfo?.source.isNotEmpty == true ||
        (mediaInfo != null && mediaInfo!.status.toLowerCase() != 'closed');
    final title = _mediaTitle;
    final subtitle = [
      mediaInfo?.artist,
      mediaInfo?.album,
      if (hasTrackTitle) mediaInfo?.source,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' • ');
    final color = Color(elem.color);
    final preferredWidth = elem.width > 0 ? elem.width : 400.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? preferredWidth.clamp(0.0, constraints.maxWidth).toDouble()
            : preferredWidth;
        final compact = width < 210;
        final artwork = Container(
          width: 30,
          height: 30,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(7),
          ),
          child: mediaThumbnailBytes == null
              ? Icon(
                  hasMedia ? Icons.music_note_rounded : Icons.music_off_rounded,
                  color: color,
                  size: 16,
                )
              : Image.memory(
                  mediaThumbnailBytes!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) =>
                      Icon(Icons.album_rounded, color: color, size: 16),
                ),
        );
        final metadata = Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: Colors.white,
                  fontFamily: elem.fontFamily,
                  fontSize: elem.fontSize,
                  fontWeight: FontWeight.bold,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white60,
                    fontFamily: elem.fontFamily,
                    fontSize: elem.fontSize * 0.8,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        );
        final controlsEnabled = enableMediaControls && !isInteractive;
        final content = compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [artwork, const SizedBox(width: 8), metadata]),
                  if (controlsEnabled)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 0,
                        children: _buildMediaControlButtons(
                          color,
                          compact: true,
                        ),
                      ),
                    ),
                ],
              )
            : Row(
                children: [
                  artwork,
                  const SizedBox(width: 10),
                  metadata,
                  if (controlsEnabled)
                    ..._buildMediaControlButtons(color, compact: false),
                ],
              );

        return Container(
          width: width,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 14,
            vertical: 8,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: content,
        );
      },
    );
  }

  List<Widget> _buildMediaControlButtons(Color color, {required bool compact}) {
    final minSize = compact ? 24.0 : 28.0;
    Widget button({
      required String tooltip,
      required IconData icon,
      required bool enabled,
      required Future<bool> Function() action,
    }) {
      return IconButton(
        tooltip: tooltip,
        onPressed: enabled
            ? () async {
                await action();
              }
            : null,
        icon: Icon(icon),
        color: color,
        disabledColor: Colors.white24,
        iconSize: compact ? 16 : 20,
        visualDensity: VisualDensity.compact,
        constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
        padding: EdgeInsets.zero,
      );
    }

    return [
      button(
        tooltip: 'Previous track',
        icon: Icons.skip_previous_rounded,
        enabled: mediaInfo?.canGoPrevious == true,
        action: MediaSessionService().previous,
      ),
      button(
        tooltip: mediaInfo?.isPlaying == true ? 'Pause' : 'Play',
        icon: mediaInfo?.isPlaying == true
            ? Icons.pause_rounded
            : Icons.play_arrow_rounded,
        enabled: mediaInfo?.isPlaying == true
            ? mediaInfo?.canPause == true
            : mediaInfo?.canPlay == true,
        action: mediaInfo?.isPlaying == true
            ? MediaSessionService().pause
            : MediaSessionService().play,
      ),
      button(
        tooltip: 'Next track',
        icon: Icons.skip_next_rounded,
        enabled: mediaInfo?.canGoNext == true,
        action: MediaSessionService().next,
      ),
    ];
  }

  String _formatMediaTime(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainder = seconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
  }

  Widget _buildUsageBar({
    required String label,
    required double? percentage,
    required IconData icon,
    required Color color,
    required double width,
    required String fontFamily,
    required double fontSize,
    required String detail,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2), width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 12, color: color),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontFamily: fontFamily,
                      fontSize: fontSize * 0.9,
                      fontWeight: FontWeight.w700,
                      color: Colors.white70,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
              Text(
                percentage == null
                    ? 'N/A'
                    : '${percentage.clamp(0, 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  fontFamily: fontFamily,
                  fontSize: fontSize * 0.9,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: fontFamily,
              fontSize: fontSize * 0.72,
              color: Colors.white54,
            ),
          ),
          if (percentage != null) ...[
            const SizedBox(height: 5),
            Container(
              width: double.infinity,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(2),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: (percentage.clamp(0, 100) / 100.0).clamp(
                  0.02,
                  1.0,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: [
                      BoxShadow(
                        color: color.withValues(alpha: 0.4),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    const gib = 1024 * 1024 * 1024;
    return '${(bytes / gib).toStringAsFixed(1)} GB';
  }

  String _formatWeatherTemperature(String celsiusValue, String unit) {
    final celsius = double.tryParse(celsiusValue);
    if (celsius == null || unit != 'F') return celsiusValue;
    return (celsius * 9 / 5 + 32).toStringAsFixed(0);
  }

  IconData _getWeatherIconData(String status) {
    if (status.isEmpty) return Icons.cloud_off_rounded;
    final lower = status.toLowerCase();
    if (lower.contains('clear') || lower.contains('sunny')) {
      return Icons.wb_sunny_rounded;
    } else if (lower.contains('drizzle') || lower.contains('rain')) {
      return Icons.water_drop_rounded;
    } else if (lower.contains('fog') || lower.contains('mist')) {
      return Icons.filter_drama_rounded;
    } else if (lower.contains('snow')) {
      return Icons.ac_unit_rounded;
    } else if (lower.contains('thunderstorm')) {
      return Icons.thunderstorm_rounded;
    }
    return Icons.wb_cloudy_rounded;
  }
}

class _MediaActivityIndicator extends StatefulWidget {
  const _MediaActivityIndicator({required this.color});

  final Color color;

  @override
  State<_MediaActivityIndicator> createState() =>
      _MediaActivityIndicatorState();
}

class _MediaActivityIndicatorState extends State<_MediaActivityIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => SizedBox(
        width: 22,
        height: 18,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(3, (index) {
            final phase = (_controller.value + index / 3) % 1;
            return Container(
              width: 3,
              height: 5 + phase * 11,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _HoloPanel extends StatefulWidget {
  const _HoloPanel({
    required this.width,
    required this.height,
    required this.color,
  });

  final double width;
  final double height;
  final Color color;

  @override
  State<_HoloPanel> createState() => _HoloPanelState();
}

class _HoloPanelState extends State<_HoloPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 7),
    value: 0.5,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotionPreference();
  }

  void _syncMotionPreference() {
    final shouldAnimate =
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.of(context).disableAnimations;
    if (shouldAnimate && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!shouldAnimate && _controller.isAnimating) {
      _controller
        ..stop()
        ..value = 0.5;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final phase = _controller.value * math.pi * 2;
          final transform = Matrix4.identity()
            ..setEntry(3, 2, 0.0012)
            ..rotateX(math.sin(phase) * 0.025)
            ..rotateY(math.cos(phase) * 0.035);

          return Transform(
            alignment: Alignment.center,
            transform: transform,
            child: Container(
              width: widget.width,
              height: widget.height,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xE81B2934), Color(0xE80B121C)],
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: widget.color.withValues(alpha: 0.6),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: widget.color.withValues(alpha: 0.16),
                    blurRadius: 14,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AnimatedElement extends StatefulWidget {
  const _AnimatedElement({required this.animationType, required this.child});

  final String animationType;
  final Widget child;

  @override
  State<_AnimatedElement> createState() => _AnimatedElementState();
}

class _AnimatedElementState extends State<_AnimatedElement>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _AnimatedElement oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animationType != widget.animationType) _syncAnimation();
  }

  void _syncAnimation() {
    final shouldAnimate =
        widget.animationType != 'none' &&
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.of(context).disableAnimations;
    if (shouldAnimate && !_controller.isAnimating) {
      _controller.repeat(reverse: widget.animationType != 'rotate');
    } else if (!shouldAnimate && _controller.isAnimating) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.animationType == 'none') return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final phase = _controller.value;
        switch (widget.animationType) {
          case 'pulse':
            return Transform.scale(scale: 0.94 + phase * 0.12, child: child);
          case 'float':
            return Transform.translate(
              offset: Offset(0, -4 * math.sin(phase * math.pi)),
              child: child,
            );
          case 'rotate':
            return Transform.rotate(angle: phase * math.pi * 2, child: child);
          default:
            return child!;
        }
      },
    );
  }
}

class _FluentCalendarWidget extends StatefulWidget {
  const _FluentCalendarWidget({
    required this.dateTime,
    required this.width,
    required this.height,
    required this.accentColor,
    required this.selectedColor,
    required this.fontFamily,
    required this.allowInteraction,
  });

  final DateTime dateTime;
  final double width;
  final double height;
  final Color accentColor;
  final Color selectedColor;
  final String fontFamily;
  final bool allowInteraction;

  @override
  State<_FluentCalendarWidget> createState() => _FluentCalendarWidgetState();
}

class _FluentCalendarWidgetState extends State<_FluentCalendarWidget>
    with SingleTickerProviderStateMixin {
  late DateTime _displayedMonth = DateTime(
    widget.dateTime.year,
    widget.dateTime.month,
  );
  late DateTime _selectedDate = DateUtils.dateOnly(widget.dateTime);
  late final AnimationController _todayPulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotionPreference();
  }

  @override
  void didUpdateWidget(covariant _FluentCalendarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final currentMonth = DateTime(widget.dateTime.year, widget.dateTime.month);
    final previousMonth = DateTime(
      oldWidget.dateTime.year,
      oldWidget.dateTime.month,
    );
    if (currentMonth != previousMonth &&
        _displayedMonth.year == previousMonth.year &&
        _displayedMonth.month == previousMonth.month) {
      _displayedMonth = currentMonth;
    }
    if (DateUtils.isSameDay(_selectedDate, oldWidget.dateTime)) {
      _selectedDate = DateUtils.dateOnly(widget.dateTime);
    }
  }

  void _syncMotionPreference() {
    final shouldAnimate =
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.of(context).disableAnimations;
    if (shouldAnimate && !_todayPulse.isAnimating) {
      _todayPulse.repeat(reverse: true);
    } else if (!shouldAnimate && _todayPulse.isAnimating) {
      _todayPulse
        ..stop()
        ..value = 0.5;
    }
  }

  @override
  void dispose() {
    _todayPulse.dispose();
    super.dispose();
  }

  void _changeMonth(int offset) {
    setState(() {
      _displayedMonth = DateTime(
        _displayedMonth.year,
        _displayedMonth.month + offset,
      );
    });
  }

  List<DateTime?> _monthCells(int firstDayOfWeek) {
    final firstOfMonth = DateTime(_displayedMonth.year, _displayedMonth.month);
    final leadingDays = (firstOfMonth.weekday % 7 - firstDayOfWeek + 7) % 7;
    final daysInMonth = DateUtils.getDaysInMonth(
      _displayedMonth.year,
      _displayedMonth.month,
    );
    return List<DateTime?>.generate(42, (index) {
      final day = index - leadingDays + 1;
      if (day < 1 || day > daysInMonth) return null;
      return DateTime(_displayedMonth.year, _displayedMonth.month, day);
    });
  }

  Widget _monthButton({required String tooltip, required IconData icon}) {
    if (!widget.allowInteraction) return const SizedBox(width: 30, height: 30);
    return IconButton(
      tooltip: tooltip,
      onPressed: () => _changeMonth(tooltip == 'Next month' ? 1 : -1),
      icon: Icon(icon, size: 17),
      color: Colors.white70,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildDayCell(DateTime? date) {
    if (date == null) return const SizedBox.shrink();
    final isToday = DateUtils.isSameDay(date, widget.dateTime);
    final isSelected = DateUtils.isSameDay(date, _selectedDate);
    final color = isSelected ? widget.selectedColor : widget.accentColor;

    Widget day = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isSelected ? color.withValues(alpha: 0.88) : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: isToday && !isSelected
              ? widget.accentColor.withValues(alpha: 0.85)
              : Colors.transparent,
        ),
      ),
      child: Text(
        '${date.day}',
        style: TextStyle(
          fontFamily: widget.fontFamily,
          fontSize: 12,
          fontWeight: isSelected || isToday ? FontWeight.w700 : FontWeight.w400,
          color: isSelected
              ? Colors.white
              : Colors.white.withValues(alpha: 0.86),
        ),
      ),
    );

    if (isToday && !isSelected) {
      day = AnimatedBuilder(
        animation: _todayPulse,
        builder: (context, child) =>
            Opacity(opacity: 0.72 + _todayPulse.value * 0.28, child: child),
        child: day,
      );
    }

    return Semantics(
      button: widget.allowInteraction,
      selected: isSelected,
      label: DateFormat.yMMMMEEEEd().format(date),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: widget.allowInteraction
            ? () => setState(() => _selectedDate = date)
            : null,
        child: Center(child: day),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final firstDayOfWeek = localizations.firstDayOfWeekIndex;
    final weekdays = List.generate(
      7,
      (index) => localizations.narrowWeekdays[(firstDayOfWeek + index) % 7],
    );
    final monthCells = _monthCells(firstDayOfWeek);

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xE8212933), Color(0xE8121820)],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 18,
              offset: const Offset(0, 7),
            ),
          ],
        ),
        child: Column(
          children: [
            SizedBox(
              height: 34,
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: widget.accentColor.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(
                      Icons.calendar_month_rounded,
                      size: 17,
                      color: widget.accentColor,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.12),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: Text(
                        DateFormat.yMMMM().format(_displayedMonth),
                        key: ValueKey(
                          '${_displayedMonth.year}-${_displayedMonth.month}',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: widget.fontFamily,
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  _monthButton(
                    tooltip: 'Previous month',
                    icon: Icons.chevron_left_rounded,
                  ),
                  _monthButton(
                    tooltip: 'Next month',
                    icon: Icons.chevron_right_rounded,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 18,
              child: Row(
                children: weekdays
                    .map(
                      (weekday) => Expanded(
                        child: Center(
                          child: Text(
                            weekday,
                            style: TextStyle(
                              fontFamily: widget.fontFamily,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.45),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 3),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => GridView.builder(
                  padding: EdgeInsets.zero,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: monthCells.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    mainAxisExtent: constraints.maxHeight / 6,
                  ),
                  itemBuilder: (context, index) =>
                      _buildDayCell(monthCells[index]),
                ),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 16,
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: widget.accentColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      DateFormat('EEE, MMM d').format(_selectedDate),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: widget.fontFamily,
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.58),
                      ),
                    ),
                  ),
                  if (widget.allowInteraction)
                    TextButton(
                      onPressed: () => setState(() {
                        _displayedMonth = DateTime(
                          widget.dateTime.year,
                          widget.dateTime.month,
                        );
                        _selectedDate = DateUtils.dateOnly(widget.dateTime);
                      }),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(36, 16),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: widget.accentColor,
                      ),
                      child: const Text(
                        'Today',
                        style: TextStyle(fontSize: 10),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
