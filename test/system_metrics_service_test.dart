import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/system_metrics_service.dart';

void main() {
  group('BatterySnapshot.fromWindows', () {
    test('preserves a reported percentage and charging state', () {
      final battery = BatterySnapshot.fromWindows(
        acLineStatus: 1,
        batteryFlag: 8,
        batteryLifePercent: 85,
        batteryLifeTime: 3600,
      );

      expect(battery.isAvailable, isTrue);
      expect(battery.percentage, 85);
      expect(battery.isCharging, isTrue);
      expect(battery.isAcConnected, isTrue);
      expect(battery.remainingSeconds, 3600);
      expect(battery.status, 'Charging');
    });

    test('does not convert Windows unknown percentage to zero', () {
      final battery = BatterySnapshot.fromWindows(
        acLineStatus: 1,
        batteryFlag: 255,
        batteryLifePercent: 255,
        batteryLifeTime: 0xFFFFFFFF,
      );

      expect(battery.isAvailable, isFalse);
      expect(battery.percentage, isNull);
      expect(battery.remainingSeconds, isNull);
      expect(battery.status, 'Unavailable');
    });

    test('treats the no-system-battery flag as unavailable', () {
      final battery = BatterySnapshot.fromWindows(
        acLineStatus: 1,
        batteryFlag: 128,
        batteryLifePercent: 100,
        batteryLifeTime: 0xFFFFFFFF,
      );

      expect(battery.isAvailable, isFalse);
      expect(battery.percentage, isNull);
    });
  });

  test('disk usage percentage derives from actual byte totals', () {
    const disk = DiskSnapshot(
      usedBytes: 75,
      totalBytes: 100,
      freeBytes: 25,
      drive: 'C:',
    );

    expect(disk.usedPercentage, 75);
    expect(disk.freeBytes, 25);
  });
}
