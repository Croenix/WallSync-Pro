import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/settings_service.dart';
import 'package:wall_sync/widgets/desktop_widget.dart';

void main() {
  test('every configured widget template resolves to its layout', () {
    const expectedLayouts = <String, DesktopWidgetLayout>{
      'classic': DesktopWidgetLayout.classic,
      'custom': DesktopWidgetLayout.custom,
      'minimal': DesktopWidgetLayout.minimal,
      'cyber': DesktopWidgetLayout.cyber,
      'split': DesktopWidgetLayout.split,
      'neon': DesktopWidgetLayout.neon,
      'animated_neon': DesktopWidgetLayout.animatedNeon,
      'sleep_weather': DesktopWidgetLayout.sleepWeather,
      'robik': DesktopWidgetLayout.robik,
      'atomic_clock': DesktopWidgetLayout.atomicClock,
      'cyber_hud': DesktopWidgetLayout.cyberHud,
      'atomic_clean': DesktopWidgetLayout.atomicClean,
      'arc_clock': DesktopWidgetLayout.arcClock,
      'flip_clock': DesktopWidgetLayout.flipClock,
      'station_weather': DesktopWidgetLayout.stationWeather,
      'taskbar_dock': DesktopWidgetLayout.taskbarDock,
      'taskbar_media': DesktopWidgetLayout.taskbarMedia,
      'taskbar_system': DesktopWidgetLayout.taskbarSystem,
      'taskbar_steam': DesktopWidgetLayout.taskbarSteam,
      'taskbar_discord': DesktopWidgetLayout.taskbarDiscord,
      'taskbar_weather': DesktopWidgetLayout.taskbarWeather,
      'taskbar_parking_lot': DesktopWidgetLayout.taskbarParkingLot,
    };

    expect(DesktopWidget.templateLayouts, expectedLayouts);
    expect(
      DesktopWidget.templateLayouts.keys.toSet(),
      WidgetSettings.templateDefaults.keys.toSet(),
    );
    for (final entry in expectedLayouts.entries) {
      expect(
        DesktopWidget.layoutForTemplate(entry.key),
        entry.value,
        reason: 'Template ${entry.key} must render ${entry.value.name}.',
      );
    }
    expect(
      DesktopWidget.layoutForTemplate('unknown'),
      DesktopWidgetLayout.classic,
    );
  });

  test('connectivity monitoring is enabled only for widgets that use it', () {
    expect(
      DesktopWidget.requiresConnectivity(
        WidgetSettings(widgetTemplate: 'atomic_clean'),
      ),
      isFalse,
    );
    expect(
      DesktopWidget.requiresConnectivity(
        WidgetSettings(widgetTemplate: 'sleep_weather'),
      ),
      isTrue,
    );
    expect(
      DesktopWidget.requiresConnectivity(
        WidgetSettings(
          widgetTemplate: 'custom',
          customElements: [CustomWidgetElement(id: 'wifi', type: 'wifi_icon')],
        ),
      ),
      isTrue,
    );
    expect(
      DesktopWidget.requiresConnectivity(
        WidgetSettings(
          widgetTemplate: 'custom',
          customElements: [CustomWidgetElement(id: 'time', type: 'hours')],
        ),
      ),
      isFalse,
    );
  });
}
