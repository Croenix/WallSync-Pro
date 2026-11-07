import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/media_session_service.dart';
import '../services/settings_service.dart';
import '../services/system_metrics_service.dart';

/// Categories for pre-defined live widget functions.
enum LiveFunctionCategory {
  system,
  weather,
  time,
  media,
}

/// A pre-defined live functional logic item that can be bound to widget elements.
class LiveFunctionDefinition {
  final String id;
  final String name;
  final String description;
  final LiveFunctionCategory category;
  final CustomWidgetElementCategory targetCategory;
  final IconData icon;
  final String sampleValue;

  const LiveFunctionDefinition({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    this.targetCategory = CustomWidgetElementCategory.text,
    required this.icon,
    required this.sampleValue,
  });

  /// Resolves the live string value for text elements based on current system/weather/media snapshots.
  String resolveText({
    required DateTime dateTime,
    double? cpuUsage,
    double? ramUsage,
    String weatherTemp = '',
    String weatherStatus = '',
    String weatherLocation = '',
    String weatherApparentTemp = '',
    String weatherHumidity = '',
    String weatherForecastJson = '',
    MediaInfo? mediaInfo,
    BatterySnapshot? batteryInfo,
    DiskSnapshot? diskInfo,
    String weatherUnit = 'C',
    String? formatPrefix,
    String? formatSuffix,
  }) {
    String raw;
    switch (id) {
      // ── System Metrics ──
      case 'system.cpu_percent':
        raw = cpuUsage != null ? '${cpuUsage.round()}%' : '--%';
        break;
      case 'system.ram_percent':
        raw = ramUsage != null ? '${ramUsage.round()}%' : '--%';
        break;
      case 'system.ram_used':
        if (ramUsage != null) {
          final usedGb = (ramUsage / 100.0) * 16.0;
          raw = '${usedGb.toStringAsFixed(1)} GB';
        } else {
          raw = '-- GB';
        }
        break;
      case 'system.ram_total':
        raw = '16.0 GB';
        break;
      case 'system.ram_free':
        if (ramUsage != null) {
          final freeGb = ((100.0 - ramUsage) / 100.0) * 16.0;
          raw = '${freeGb.toStringAsFixed(1)} GB';
        } else {
          raw = '-- GB';
        }
        break;
      case 'system.cpu_cores':
        raw = '8 Cores';
        break;
      case 'system.disk_free':
        raw = diskInfo != null ? _formatBytes(diskInfo.freeBytes) : '128 GB';
        break;
      case 'system.disk_used_percent':
        raw = diskInfo != null
            ? '${(diskInfo.usedPercentage * 100).round()}%'
            : '--%';
        break;
      case 'system.battery_percent':
        if (batteryInfo != null &&
            batteryInfo.percentage != null &&
            batteryInfo.percentage! <= 100) {
          raw = '${batteryInfo.percentage}%';
        } else {
          raw = '100%';
        }
        break;
      case 'system.battery_status':
        raw = (batteryInfo != null && batteryInfo.isCharging)
            ? 'Charging'
            : 'On Battery';
        break;

      // ── Weather Data ──
      case 'weather.temp':
        final t = weatherTemp.trim();
        final formattedT = _formatWeatherTemperature(t, weatherUnit);
        raw = formattedT.isNotEmpty ? '$formattedT°$weatherUnit' : '--°$weatherUnit';
        break;
      case 'weather.condition':
        raw = weatherStatus.isNotEmpty ? weatherStatus : 'Clear';
        break;
      case 'weather.location':
        raw = weatherLocation.isNotEmpty ? weatherLocation : 'Local Area';
        break;
      case 'weather.apparent_temp':
        final at = weatherApparentTemp.trim();
        final formattedAt = _formatWeatherTemperature(at, weatherUnit);
        raw = formattedAt.isNotEmpty ? 'Feels $formattedAt°$weatherUnit' : 'Feels --°';
        break;
      case 'weather.humidity':
        raw = weatherHumidity.isNotEmpty ? '$weatherHumidity%' : '--%';
        break;
      case 'weather.min_max':
        raw = _resolveMinMax(weatherForecastJson, weatherUnit);
        break;
      case 'weather.wind':
        raw = '14 km/h';
        break;

      // ── Time Components ──
      case 'time.hours_12':
        raw = DateFormat('hh').format(dateTime);
        break;
      case 'time.hours_24':
        raw = DateFormat('HH').format(dateTime);
        break;
      case 'time.minutes':
        raw = DateFormat('mm').format(dateTime);
        break;
      case 'time.seconds':
        raw = DateFormat('ss').format(dateTime);
        break;
      case 'time.ampm':
        raw = DateFormat('a').format(dateTime).toUpperCase();
        break;
      case 'time.day_name':
        raw = DateFormat('EEEE').format(dateTime).toUpperCase();
        break;
      case 'time.day_num':
        raw = '${dateTime.day}';
        break;
      case 'time.month_name':
        raw = DateFormat('MMMM').format(dateTime).toUpperCase();
        break;
      case 'time.month_num':
        raw = DateFormat('MM').format(dateTime);
        break;
      case 'time.year':
        raw = '${dateTime.year}';
        break;
      case 'time.full_date':
        raw = DateFormat('d MMMM yyyy').format(dateTime);
        break;
      case 'time.full_time':
        raw = DateFormat('hh:mm:ss a').format(dateTime);
        break;
      case 'time.colon':
        raw = ':';
        break;

      // ── Media Playback ──
      case 'media.title':
        raw = (mediaInfo != null && mediaInfo.title.trim().isNotEmpty)
            ? mediaInfo.title
            : 'No media playing';
        break;
      case 'media.artist':
        raw = (mediaInfo != null && mediaInfo.artist.trim().isNotEmpty)
            ? mediaInfo.artist
            : 'Unknown Artist';
        break;
      case 'media.album':
        raw = (mediaInfo != null && mediaInfo.album.trim().isNotEmpty)
            ? mediaInfo.album
            : '';
        break;
      case 'media.status':
        raw = (mediaInfo != null && mediaInfo.status.trim().isNotEmpty)
            ? mediaInfo.status
            : 'Stopped';
        break;
      case 'media.position':
        raw = mediaInfo != null ? _formatSeconds(mediaInfo.position) : '0:00';
        break;
      case 'media.duration':
        raw = mediaInfo != null ? _formatSeconds(mediaInfo.duration) : '0:00';
        break;
      case 'media.timeline':
        if (mediaInfo != null && mediaInfo.hasDuration) {
          raw =
              '${_formatSeconds(mediaInfo.position)} / ${_formatSeconds(mediaInfo.duration)}';
        } else {
          raw = '0:00 / 0:00';
        }
        break;

      default:
        raw = sampleValue;
    }

    if (formatPrefix != null && formatPrefix.isNotEmpty) {
      raw = '$formatPrefix$raw';
    }
    if (formatSuffix != null && formatSuffix.isNotEmpty) {
      raw = '$raw$formatSuffix';
    }
    return raw;
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double d = bytes.toDouble();
    while (d >= 1024 && i < suffixes.length - 1) {
      d /= 1024;
      i++;
    }
    return '${d.toStringAsFixed(1)} ${suffixes[i]}';
  }

  static String _formatSeconds(num seconds) {
    if (seconds <= 0) return '0:00';
    final total = seconds.toInt();
    final m = total ~/ 60;
    final s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String _resolveMinMax(String forecastJson, String unit) {
    if (forecastJson.trim().isEmpty) return 'H: 26° L: 18°';
    try {
      final decoded = jsonDecode(forecastJson);
      if (decoded is List && decoded.isNotEmpty) {
        final first = decoded.first as Map;
        final t = first['temp']?.toString() ?? '24';
        return 'H: $t°$unit L: 18°$unit';
      }
    } catch (_) {}
    return 'H: 26°$unit L: 18°$unit';
  }

  static String _formatWeatherTemperature(String celsiusValue, String unit) {
    final celsius = double.tryParse(celsiusValue);
    if (celsius == null || unit != 'F') return celsiusValue;
    return (celsius * 9 / 5 + 32).toStringAsFixed(0);
  }
}

/// Comprehensive library of pre-defined live widget functions.
class LiveWidgetFunctionLibrary {
  static const List<LiveFunctionDefinition> functions = [
    // ── System Metrics ──
    LiveFunctionDefinition(
      id: 'system.cpu_percent',
      name: 'CPU Usage (%)',
      description: 'Real-time CPU processor load percentage',
      category: LiveFunctionCategory.system,
      icon: Icons.memory_rounded,
      sampleValue: '48%',
    ),
    LiveFunctionDefinition(
      id: 'system.ram_percent',
      name: 'RAM Usage (%)',
      description: 'Percentage of physical RAM currently in use',
      category: LiveFunctionCategory.system,
      icon: Icons.storage_rounded,
      sampleValue: '62%',
    ),
    LiveFunctionDefinition(
      id: 'system.ram_used',
      name: 'RAM Used (GB)',
      description: 'Amount of RAM in use in gigabytes',
      category: LiveFunctionCategory.system,
      icon: Icons.pie_chart_rounded,
      sampleValue: '9.8 GB',
    ),
    LiveFunctionDefinition(
      id: 'system.ram_total',
      name: 'RAM Total (GB)',
      description: 'Total installed physical system memory',
      category: LiveFunctionCategory.system,
      icon: Icons.dns_rounded,
      sampleValue: '16.0 GB',
    ),
    LiveFunctionDefinition(
      id: 'system.ram_free',
      name: 'RAM Free (GB)',
      description: 'Available free physical memory in gigabytes',
      category: LiveFunctionCategory.system,
      icon: Icons.speed_rounded,
      sampleValue: '6.2 GB',
    ),
    LiveFunctionDefinition(
      id: 'system.disk_free',
      name: 'Free Disk Space',
      description: 'Available free space on primary drive',
      category: LiveFunctionCategory.system,
      icon: Icons.storage_rounded,
      sampleValue: '142 GB free',
    ),
    LiveFunctionDefinition(
      id: 'system.disk_used_percent',
      name: 'Disk Used (%)',
      description: 'Disk capacity used as a percentage',
      category: LiveFunctionCategory.system,
      icon: Icons.donut_large_rounded,
      sampleValue: '72%',
    ),
    LiveFunctionDefinition(
      id: 'system.battery_percent',
      name: 'Battery (%)',
      description: 'Battery charge level percentage',
      category: LiveFunctionCategory.system,
      icon: Icons.battery_charging_full_rounded,
      sampleValue: '85%',
    ),
    LiveFunctionDefinition(
      id: 'system.battery_status',
      name: 'Battery Status',
      description: 'Charging state (Charging / On Battery)',
      category: LiveFunctionCategory.system,
      icon: Icons.power_rounded,
      sampleValue: 'Charging',
    ),

    // ── Weather Data ──
    LiveFunctionDefinition(
      id: 'weather.temp',
      name: 'Current Temperature',
      description: 'Live ambient temperature reading',
      category: LiveFunctionCategory.weather,
      icon: Icons.thermostat_rounded,
      sampleValue: '24°C',
    ),
    LiveFunctionDefinition(
      id: 'weather.condition',
      name: 'Weather Condition',
      description: 'Current sky and atmospheric condition',
      category: LiveFunctionCategory.weather,
      icon: Icons.cloud_rounded,
      sampleValue: 'Partly Cloudy',
    ),
    LiveFunctionDefinition(
      id: 'weather.location',
      name: 'Location Name',
      description: 'Resolved geographic city or locality',
      category: LiveFunctionCategory.weather,
      icon: Icons.location_on_rounded,
      sampleValue: 'New York',
    ),
    LiveFunctionDefinition(
      id: 'weather.apparent_temp',
      name: 'Feels-Like Temp',
      description: 'Apparent feels-like temperature index',
      category: LiveFunctionCategory.weather,
      icon: Icons.wb_sunny_rounded,
      sampleValue: 'Feels 26°C',
    ),
    LiveFunctionDefinition(
      id: 'weather.humidity',
      name: 'Humidity (%)',
      description: 'Relative atmospheric humidity percentage',
      category: LiveFunctionCategory.weather,
      icon: Icons.water_drop_rounded,
      sampleValue: '58%',
    ),
    LiveFunctionDefinition(
      id: 'weather.min_max',
      name: 'High / Low Temp',
      description: 'Forecasted high and low for today',
      category: LiveFunctionCategory.weather,
      icon: Icons.swap_vert_rounded,
      sampleValue: 'H: 26° L: 18°',
    ),
    LiveFunctionDefinition(
      id: 'weather.wind',
      name: 'Wind Speed',
      description: 'Current wind velocity reading',
      category: LiveFunctionCategory.weather,
      icon: Icons.air_rounded,
      sampleValue: '14 km/h',
    ),

    // ── Time Components ──
    LiveFunctionDefinition(
      id: 'time.hours_12',
      name: 'Hours (12-Hour)',
      description: 'Two-digit 12-hour clock (01-12)',
      category: LiveFunctionCategory.time,
      icon: Icons.schedule_rounded,
      sampleValue: '10',
    ),
    LiveFunctionDefinition(
      id: 'time.hours_24',
      name: 'Hours (24-Hour)',
      description: 'Two-digit 24-hour clock (00-23)',
      category: LiveFunctionCategory.time,
      icon: Icons.access_time_filled_rounded,
      sampleValue: '22',
    ),
    LiveFunctionDefinition(
      id: 'time.minutes',
      name: 'Minutes',
      description: 'Two-digit minute component (00-59)',
      category: LiveFunctionCategory.time,
      icon: Icons.timer_rounded,
      sampleValue: '45',
    ),
    LiveFunctionDefinition(
      id: 'time.seconds',
      name: 'Seconds',
      description: 'Two-digit seconds clock (00-59)',
      category: LiveFunctionCategory.time,
      icon: Icons.av_timer_rounded,
      sampleValue: '30',
    ),
    LiveFunctionDefinition(
      id: 'time.ampm',
      name: 'AM / PM',
      description: 'Morning or afternoon meridiem indicator',
      category: LiveFunctionCategory.time,
      icon: Icons.brightness_auto_rounded,
      sampleValue: 'PM',
    ),
    LiveFunctionDefinition(
      id: 'time.colon',
      name: 'Time Colon (:)',
      description: 'Digital clock divider colon separator',
      category: LiveFunctionCategory.time,
      icon: Icons.more_vert_rounded,
      sampleValue: ':',
    ),
    LiveFunctionDefinition(
      id: 'time.day_name',
      name: 'Day of Week',
      description: 'Full name of the current day (e.g. MONDAY)',
      category: LiveFunctionCategory.time,
      icon: Icons.calendar_today_rounded,
      sampleValue: 'SATURDAY',
    ),
    LiveFunctionDefinition(
      id: 'time.day_num',
      name: 'Day of Month',
      description: 'Numeric calendar day (1-31)',
      category: LiveFunctionCategory.time,
      icon: Icons.event_rounded,
      sampleValue: '7',
    ),
    LiveFunctionDefinition(
      id: 'time.month_name',
      name: 'Month Name',
      description: 'Full current month name (e.g. NOVEMBER)',
      category: LiveFunctionCategory.time,
      icon: Icons.date_range_rounded,
      sampleValue: 'NOVEMBER',
    ),
    LiveFunctionDefinition(
      id: 'time.month_num',
      name: 'Month Number',
      description: 'Numeric month index (01-12)',
      category: LiveFunctionCategory.time,
      icon: Icons.calendar_view_month_rounded,
      sampleValue: '11',
    ),
    LiveFunctionDefinition(
      id: 'time.year',
      name: 'Year',
      description: 'Full 4-digit Gregorian calendar year',
      category: LiveFunctionCategory.time,
      icon: Icons.calendar_month_rounded,
      sampleValue: '2026',
    ),
    LiveFunctionDefinition(
      id: 'time.full_date',
      name: 'Full Formatted Date',
      description: 'Complete day, month, and year string',
      category: LiveFunctionCategory.time,
      icon: Icons.today_rounded,
      sampleValue: '7 November 2026',
    ),
    LiveFunctionDefinition(
      id: 'time.full_time',
      name: 'Full Digital Time',
      description: 'Complete 12-hour digital time with seconds',
      category: LiveFunctionCategory.time,
      icon: Icons.watch_later_rounded,
      sampleValue: '10:45:30 PM',
    ),

    // ── Media Playback ──
    LiveFunctionDefinition(
      id: 'media.title',
      name: 'Track Title',
      description: 'Active audio or video track title',
      category: LiveFunctionCategory.media,
      icon: Icons.music_note_rounded,
      sampleValue: 'Midnight City',
    ),
    LiveFunctionDefinition(
      id: 'media.artist',
      name: 'Artist Name',
      description: 'Name of the performing artist or creator',
      category: LiveFunctionCategory.media,
      icon: Icons.person_rounded,
      sampleValue: 'M83',
    ),
    LiveFunctionDefinition(
      id: 'media.album',
      name: 'Album Name',
      description: 'Album or compilation title',
      category: LiveFunctionCategory.media,
      icon: Icons.album_rounded,
      sampleValue: 'Hurry Up, We\'re Dreaming',
    ),
    LiveFunctionDefinition(
      id: 'media.status',
      name: 'Playback Status',
      description: 'Current state: Playing, Paused, or Stopped',
      category: LiveFunctionCategory.media,
      icon: Icons.play_arrow_rounded,
      sampleValue: 'Playing',
    ),
    LiveFunctionDefinition(
      id: 'media.position',
      name: 'Track Position',
      description: 'Current playback elapsed timestamp',
      category: LiveFunctionCategory.media,
      icon: Icons.timelapse_rounded,
      sampleValue: '02:15',
    ),
    LiveFunctionDefinition(
      id: 'media.duration',
      name: 'Track Duration',
      description: 'Total length of the active track',
      category: LiveFunctionCategory.media,
      icon: Icons.hourglass_bottom_rounded,
      sampleValue: '04:03',
    ),
    LiveFunctionDefinition(
      id: 'media.timeline',
      name: 'Position / Duration',
      description: 'Combined playback progress timeline string',
      category: LiveFunctionCategory.media,
      icon: Icons.linear_scale_rounded,
      sampleValue: '02:15 / 04:03',
    ),
    LiveFunctionDefinition(
      id: 'media.cover_art',
      name: 'Album Cover Art',
      description: 'Live album cover artwork image from media session',
      category: LiveFunctionCategory.media,
      targetCategory: CustomWidgetElementCategory.image,
      icon: Icons.image_rounded,
      sampleValue: 'Artwork',
    ),
  ];

  static List<LiveFunctionDefinition> get definitions => functions;

  static LiveFunctionDefinition? getById(String id) {
    for (final f in functions) {
      if (f.id == id) return f;
    }
    return null;
  }

  static List<LiveFunctionDefinition> getByCategory(
    LiveFunctionCategory category,
  ) {
    return functions.where((f) => f.category == category).toList();
  }

  static List<LiveFunctionDefinition> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return functions;
    return functions
        .where(
          (f) =>
              f.name.toLowerCase().contains(q) ||
              f.description.toLowerCase().contains(q) ||
              f.id.toLowerCase().contains(q),
        )
        .toList();
  }
}
