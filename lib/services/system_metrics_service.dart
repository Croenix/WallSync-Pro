import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'settings_service.dart';

class BatterySnapshot {
  const BatterySnapshot({
    required this.percentage,
    required this.isCharging,
    required this.isAcConnected,
    required this.isAvailable,
    required this.remainingSeconds,
  });

  final int? percentage;
  final bool isCharging;
  final bool? isAcConnected;
  final bool isAvailable;
  final int? remainingSeconds;

  factory BatterySnapshot.fromWindows({
    required int acLineStatus,
    required int batteryFlag,
    required int batteryLifePercent,
    required int batteryLifeTime,
  }) {
    final percentage = batteryLifePercent <= 100 ? batteryLifePercent : null;
    final available =
        batteryFlag != 128 && (percentage != null || batteryFlag != 255);
    return BatterySnapshot(
      percentage: available ? percentage : null,
      isCharging: available && (batteryFlag & 8) != 0,
      isAcConnected: switch (acLineStatus) {
        0 => false,
        1 => true,
        _ => null,
      },
      isAvailable: available,
      remainingSeconds: available && batteryLifeTime != 0xFFFFFFFF
          ? batteryLifeTime
          : null,
    );
  }

  String get status {
    if (!isAvailable) return 'Unavailable';
    if (isCharging) return 'Charging';
    if (isAcConnected == true) return 'Plugged in';
    return 'On battery';
  }

  String? get remainingLabel {
    final seconds = remainingSeconds;
    if (seconds == null || seconds < 0) return null;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    if (hours > 0) return '${hours}h ${minutes}m remaining';
    return '${minutes}m remaining';
  }

  @override
  bool operator ==(Object other) =>
      other is BatterySnapshot &&
      percentage == other.percentage &&
      isCharging == other.isCharging &&
      isAcConnected == other.isAcConnected &&
      isAvailable == other.isAvailable &&
      remainingSeconds == other.remainingSeconds;

  @override
  int get hashCode => Object.hash(
    percentage,
    isCharging,
    isAcConnected,
    isAvailable,
    remainingSeconds,
  );
}

class DiskSnapshot {
  const DiskSnapshot({
    required this.usedBytes,
    required this.totalBytes,
    required this.freeBytes,
    required this.drive,
    this.label = '',
    this.type = 'Fixed',
  });

  final int usedBytes;
  final int totalBytes;
  final int freeBytes;
  final String drive;
  final String label;
  final String type;

  double get usedPercentage =>
      totalBytes == 0 ? 0 : usedBytes * 100 / totalBytes;

  String get formattedTotal {
    final gb = totalBytes / (1024 * 1024 * 1024);
    if (gb >= 1000) return '${(gb / 1024).toStringAsFixed(1)} TB';
    return '${gb.toStringAsFixed(0)} GB';
  }

  String get formattedFree {
    final gb = freeBytes / (1024 * 1024 * 1024);
    if (gb >= 1000) return '${(gb / 1024).toStringAsFixed(1)} TB';
    return '${gb.toStringAsFixed(0)} GB';
  }

  String get formattedUsed {
    final gb = usedBytes / (1024 * 1024 * 1024);
    if (gb >= 1000) return '${(gb / 1024).toStringAsFixed(1)} TB';
    return '${gb.toStringAsFixed(0)} GB';
  }

  String get totalFormatted => formattedTotal;
  String get freeFormatted => formattedFree;
  String get usedFormatted => formattedUsed;

  String get displayName => label.isNotEmpty ? '$drive ($label)' : drive;

  @override
  bool operator ==(Object other) =>
      other is DiskSnapshot &&
      usedBytes == other.usedBytes &&
      totalBytes == other.totalBytes &&
      freeBytes == other.freeBytes &&
      drive == other.drive &&
      label == other.label &&
      type == other.type;

  @override
  int get hashCode => Object.hash(usedBytes, totalBytes, freeBytes, drive, label, type);
}

class SystemMetricsSnapshot {
  const SystemMetricsSnapshot({
    this.battery,
    this.disk,
    this.allDisks = const [],
  });

  final BatterySnapshot? battery;
  final DiskSnapshot? disk;
  final List<DiskSnapshot> allDisks;

  @override
  bool operator ==(Object other) =>
      other is SystemMetricsSnapshot &&
      battery == other.battery &&
      disk == other.disk;

  @override
  int get hashCode => Object.hash(battery, disk);
}

class SystemMetricsService {
  const SystemMetricsService._();

  static Future<SystemMetricsSnapshot> readSnapshotAsync([String? selectedDrive]) =>
      Isolate.run(() => readSnapshot(selectedDrive));

  static SystemMetricsSnapshot readSnapshot([String? selectedDrive]) {
    if (!Platform.isWindows) return const SystemMetricsSnapshot();
    final disks = readAllDisks();
    DiskSnapshot? primary;
    if (selectedDrive != null && selectedDrive.isNotEmpty && selectedDrive != 'Auto') {
      primary = disks.firstWhere(
        (d) => d.drive.toUpperCase().startsWith(selectedDrive.toUpperCase()),
        orElse: () => disks.isNotEmpty ? disks.first : _readSystemDisk()!,
      );
    } else {
      primary = disks.firstWhere(
        (d) => d.drive.toUpperCase().startsWith('C:'),
        orElse: () => disks.isNotEmpty ? disks.first : _readSystemDisk()!,
      );
    }
    return SystemMetricsSnapshot(
      battery: _readBattery(),
      disk: primary,
      allDisks: disks,
    );
  }

  static BatterySnapshot? _readBattery() {
    return using((arena) {
      final status = arena<SYSTEM_POWER_STATUS>();
      final result = GetSystemPowerStatus(status);
      if (!result.value) {
        logWarning(
          'SystemMetricsService',
          'GetSystemPowerStatus failed with Win32 error ${result.error}.',
        );
        return null;
      }

      final value = status.ref;
      return BatterySnapshot.fromWindows(
        acLineStatus: value.ACLineStatus,
        batteryFlag: value.BatteryFlag,
        batteryLifePercent: value.BatteryLifePercent,
        batteryLifeTime: value.BatteryLifeTime,
      );
    });
  }

  static List<DiskSnapshot> readAllDisks() {
    if (!Platform.isWindows) return const [];
    try {
      final bitmaskRes = GetLogicalDrives();
      final bitmask = bitmaskRes.value;
      if (bitmask == 0) {
        final fallback = _readSystemDisk();
        return fallback != null ? [fallback] : const [];
      }
      final results = <DiskSnapshot>[];
      for (int i = 0; i < 26; i++) {
        if ((bitmask & (1 << i)) != 0) {
          final letter = String.fromCharCode(65 + i);
          final drive = '$letter:';
          final disk = _readDiskForDrive(drive);
          if (disk != null) {
            results.add(disk);
          }
        }
      }
      if (results.isEmpty) {
        final fallback = _readSystemDisk();
        if (fallback != null) results.add(fallback);
      }
      return results;
    } catch (e) {
      logWarning('SystemMetricsService', 'Error reading all logical drives: $e');
      final fallback = _readSystemDisk();
      return fallback != null ? [fallback] : const [];
    }
  }

  static DiskSnapshot? _readDiskForDrive(String drive) {
    final root = drive.endsWith(r'\') ? drive : '$drive\\';
    return using((arena) {
      final availableToCaller = arena<Uint64>();
      final totalBytes = arena<Uint64>();
      final totalFreeBytes = arena<Uint64>();
      final rootUtf16 = root.toNativeUtf16(allocator: arena);
      final result = GetDiskFreeSpaceEx(
        PCWSTR(rootUtf16),
        availableToCaller,
        totalBytes,
        totalFreeBytes,
      );
      if (!result.value) {
        return null;
      }

      if (totalBytes.value == 0 || totalFreeBytes.value > totalBytes.value) {
        return null;
      }

      String label = '';
      try {
        final volBuf = arena<Uint16>(261);
        final fsBuf = arena<Uint16>(261);
        final volRes = GetVolumeInformation(
          PCWSTR(rootUtf16),
          PWSTR(volBuf.cast<Utf16>()),
          260,
          nullptr,
          nullptr,
          nullptr,
          PWSTR(fsBuf.cast<Utf16>()),
          260,
        );
        if (volRes.value) {
          label = volBuf.cast<Utf16>().toDartString();
        }
      } catch (_) {}
      if (label.isEmpty) {
        label = drive.toUpperCase() == 'C:' ? 'Windows / OS' : 'Local Disk';
      }

      int driveType = 0;
      try {
        driveType = GetDriveType(PCWSTR(rootUtf16));
      } catch (_) {}

      String type = 'Fixed';
      if (driveType == DRIVE_REMOVABLE) {
        type = 'Removable / USB';
      } else if (driveType == DRIVE_REMOTE) {
        type = 'Network Drive';
      } else if (driveType == DRIVE_CDROM) {
        type = 'Optical Drive';
      } else if (drive.toUpperCase() == 'C:') {
        type = 'NVMe / SSD (OS)';
      } else {
        type = 'SSD / Storage';
      }

      return DiskSnapshot(
        usedBytes: totalBytes.value - totalFreeBytes.value,
        totalBytes: totalBytes.value,
        freeBytes: totalFreeBytes.value,
        drive: drive,
        label: label,
        type: type,
      );
    });
  }

  static DiskSnapshot? _readSystemDisk() {
    final systemDrive = Platform.environment['SystemDrive'];
    final drive = (systemDrive == null || systemDrive.isEmpty)
        ? 'C:'
        : systemDrive;
    return _readDiskForDrive(drive);
  }
}
