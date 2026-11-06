import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/media_session_service.dart';
import 'package:wall_sync/services/settings_service.dart';
import 'package:wall_sync/services/system_metrics_service.dart';
import 'package:wall_sync/widgets/custom_widget_renderer.dart';

void main() {
  test('rejects unavailable and negative GSMTC timeline values', () {
    final unavailable = MediaInfo.fromJson({
      'Duration': -0.000001,
      'Position': -0.000001,
      'HasDuration': false,
      'HasPosition': false,
      'Status': 'Playing',
    });

    expect(unavailable.duration, 0);
    expect(unavailable.position, 0);
    expect(unavailable.hasDuration, isFalse);
    expect(unavailable.hasPosition, isFalse);
    expect(unavailable.formattedTimeline, 'PLAYING');

    final invalidPosition = MediaInfo.fromJson({
      'Duration': 200,
      'Position': 201,
      'HasDuration': true,
      'HasPosition': true,
      'Status': 'Playing',
    });
    expect(invalidPosition.hasDuration, isTrue);
    expect(invalidPosition.hasPosition, isFalse);
    expect(invalidPosition.position, 0);
  });

  testWidgets('live system and media elements handle unavailable values', (
    tester,
  ) async {
    final elements =
        [
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
              'battery_bar',
              'space_bar',
            ]
            .map(
              (type) => CustomWidgetElement(
                id: type,
                type: type,
                width: 220,
                height: type == 'media_artwork' ? 56 : 4,
                color: 0xFF00FF55,
              ),
            )
            .toList();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 300,
            child: CustomWidgetRenderer(
              elements: elements,
              dateTime: DateTime(2026, 10, 22),
              mediaInfo: MediaInfo(title: '', artist: '', status: 'Closed'),
              batteryInfo: BatterySnapshot.fromWindows(
                acLineStatus: 1,
                batteryFlag: 255,
                batteryLifePercent: 255,
                batteryLifeTime: 0xFFFFFFFF,
              ),
              diskInfo: const DiskSnapshot(
                usedBytes: 1,
                totalBytes: 4,
                freeBytes: 3,
                drive: 'C:',
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('No media playing'), findsNWidgets(2));
    expect(find.text('Idle'), findsOneWidget);
    expect(find.text('N/A'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('00:00'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders the supplied battery percentage and disk free space', (
    tester,
  ) async {
    const gib = 1024 * 1024 * 1024;
    final elements = ['battery_bar', 'space_bar']
        .map(
          (type) => CustomWidgetElement(
            id: type,
            type: type,
            width: 220,
            color: 0xFF00FF55,
          ),
        )
        .toList();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomWidgetRenderer(
            elements: elements,
            dateTime: DateTime(2026, 10, 22),
            batteryInfo: BatterySnapshot.fromWindows(
              acLineStatus: 1,
              batteryFlag: 8,
              batteryLifePercent: 85,
              batteryLifeTime: 3600,
            ),
            diskInfo: const DiskSnapshot(
              usedBytes: gib,
              totalBytes: 4 * gib,
              freeBytes: 3 * gib,
              drive: 'C:',
            ),
          ),
        ),
      ),
    );

    expect(find.text('85%'), findsOneWidget);
    expect(
      find.textContaining('1.0 GB used / 4.0 GB · 3.0 GB free'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Fluent calendar animates and navigates real month dates', (
    tester,
  ) async {
    final calendar = CustomWidgetElement(
      id: 'calendar',
      type: 'fluent_calendar',
      width: 300,
      height: 260,
      color: 0xFF60CDFF,
      activeColor: 0xFF0078D4,
    );
    final restored = CustomWidgetElement.fromJson(
      jsonDecode(jsonEncode(calendar.toJson())) as Map<String, dynamic>,
    );
    expect(restored.type, 'fluent_calendar');
    expect(restored.width, 300);
    expect(restored.height, 260);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomWidgetRenderer(
            elements: [restored],
            dateTime: DateTime(2026, 10, 22),
          ),
        ),
      ),
    );

    expect(find.text('October 2026'), findsOneWidget);
    expect(find.byTooltip('Previous month'), findsOneWidget);
    expect(find.byTooltip('Next month'), findsOneWidget);
    expect(find.text('22'), findsOneWidget);

    await tester.tap(find.byTooltip('Next month'));
    await tester.pump(const Duration(milliseconds: 240));

    expect(find.text('November 2026'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('media capsule fits compact, standard, and wide canvases', (
    tester,
  ) async {
    final element = CustomWidgetElement(
      id: 'media',
      type: 'media_pill',
      width: 420,
      color: 0xFF00FF55,
    );
    final media = MediaInfo(
      title:
          'A very long title that should not push controls outside the capsule',
      artist:
          'An artist name that is also much longer than the available space',
      album: 'Album',
      source: 'Spotify',
      status: 'Playing',
      duration: 240,
      position: 85,
      hasDuration: true,
      hasPosition: true,
      canPlay: true,
      canPause: true,
      canGoNext: true,
      canGoPrevious: true,
    );

    for (final width in [120.0, 280.0, 640.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              height: 100,
              child: CustomWidgetRenderer(
                elements: [element],
                dateTime: DateTime(2026, 10, 22),
                mediaInfo: media,
                enableMediaControls: true,
                canvasWidth: width,
                canvasHeight: 100,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'canvas width $width');
    }
  });

  testWidgets('media elements bind to one supplied session snapshot', (
    tester,
  ) async {
    final position = ValueNotifier<int>(84);
    addTearDown(position.dispose);
    final types = [
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
    ];
    final elements = types
        .map(
          (type) => CustomWidgetElement(
            id: type,
            type: type,
            width: 240,
            height: type == 'media_artwork' ? 56 : 4,
            color: 0xFF00FF55,
          ),
        )
        .toList();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 720,
            height: 500,
            child: CustomWidgetRenderer(
              elements: elements,
              dateTime: DateTime(2026, 10, 22),
              mediaInfo: MediaInfo(
                title: 'Session title',
                artist: 'Session artist',
                album: 'Session album',
                source: 'Chrome',
                status: 'Playing',
                position: 84,
                duration: 245,
                hasDuration: true,
                hasPosition: true,
                canPlay: true,
                canPause: true,
                canGoPrevious: true,
                canGoNext: true,
              ),
              mediaPosition: position,
              enableMediaControls: true,
              canvasWidth: 720,
              canvasHeight: 500,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Session title'), findsOneWidget);
    expect(find.text('Session artist'), findsOneWidget);
    expect(find.text('Session album'), findsOneWidget);
    expect(find.text('Chrome'), findsOneWidget);
    expect(find.text('Playing'), findsOneWidget);
    expect(find.text('01:24'), findsOneWidget);
    expect(find.text('04:05'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byTooltip('Previous track'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Next track'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_MediaActivityIndicator',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('media artwork element displays supplied image bytes', (
    tester,
  ) async {
    final artwork = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomWidgetRenderer(
            elements: [
              CustomWidgetElement(
                id: 'artwork',
                type: 'media_artwork',
                width: 64,
                height: 64,
                color: 0xFF38BDF8,
              ),
            ],
            dateTime: DateTime(2026, 10, 22),
            mediaThumbnailBytes: artwork,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
