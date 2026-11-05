import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/system_optimizer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'automatic memory optimization does not evict active resources',
    () async {
      var nativeCalls = 0;
      const channel = MethodChannel('wallsync/live_wallpaper');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            nativeCalls++;
            return true;
          });

      final service = SystemOptimizerService.instance;
      try {
        expect(await service.optimizeMemory(), isFalse);
        service.startBackgroundMemoryOptimizer(
          interval: const Duration(milliseconds: 1),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(nativeCalls, 0);
      } finally {
        service.stopBackgroundMemoryOptimizer();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      }
    },
  );
}
