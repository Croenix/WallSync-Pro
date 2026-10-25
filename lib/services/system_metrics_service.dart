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
  });

  final int usedBytes;
  final int totalBytes;
  final int freeBytes;
  final String drive;

  double get usedPercentage =>
      totalBytes == 0 ? 0 : usedBytes * 100 / totalBytes;

  @override
  bool operator ==(Object other) =>
      other is DiskSnapshot &&
      usedBytes == other.usedBytes &&
      totalBytes == other.totalBytes &&
      freeBytes == other.freeBytes &&
      drive == other.drive;

  @override
  int get hashCode => Object.hash(usedBytes, totalBytes, freeBytes, drive);
}

class SystemMetricsSnapshot {
  const SystemMetricsSnapshot({this.battery, this.disk});

  final BatterySnapshot? battery;
  final DiskSnapshot? disk;

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

  static Future<SystemMetricsSnapshot> readSnapshotAsync() =>
      Isolate.run(readSnapshot);

  static SystemMetricsSnapshot readSnapshot() {
    if (!Platform.isWindows) return const SystemMetricsSnapshot();
    return SystemMetricsSnapshot(
      battery: _readBattery(),
      disk: _readSystemDisk(),
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

  static DiskSnapshot? _readSystemDisk() {
    final systemDrive = Platform.environment['SystemDrive'];
    final drive = (systemDrive == null || systemDrive.isEmpty)
        ? 'C:'
        : systemDrive;
    final root = drive.endsWith(r'\') ? drive : '$drive\\';

    return using((arena) {
      final availableToCaller = arena<Uint64>();
      final totalBytes = arena<Uint64>();
      final totalFreeBytes = arena<Uint64>();
      final result = GetDiskFreeSpaceEx(
        PCWSTR(root.toNativeUtf16(allocator: arena)),
        availableToCaller,
        totalBytes,
        totalFreeBytes,
      );
      if (!result.value) {
        logWarning(
          'SystemMetricsService',
          'GetDiskFreeSpaceEx failed for $root with Win32 error ${result.error}.',
        );
        return null;
      }

      if (totalBytes.value == 0 || totalFreeBytes.value > totalBytes.value) {
        logWarning(
          'SystemMetricsService',
          'GetDiskFreeSpaceEx returned invalid capacity data for $root.',
        );
        return null;
      }
      return DiskSnapshot(
        usedBytes: totalBytes.value - totalFreeBytes.value,
        totalBytes: totalBytes.value,
        freeBytes: totalFreeBytes.value,
        drive: drive,
      );
    });
  }
}
