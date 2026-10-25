import 'package:flutter_test/flutter_test.dart';
import 'package:wall_sync/services/media_session_service.dart';

void main() {
  test('media metadata keeps supported transport capabilities', () {
    final media = MediaInfo.fromJson({
      'Title': 'Track',
      'Artist': 'Artist',
      'Album': 'Album',
      'Status': 'Playing',
      'Source': 'Music Player',
      'SessionId': 'com.example.player',
      'CanPlay': true,
      'CanPause': true,
      'CanGoNext': false,
      'CanGoPrevious': true,
    });

    expect(media.isPlaying, isTrue);
    expect(media.album, 'Album');
    expect(media.sessionId, 'com.example.player');
    expect(media.canPlay, isTrue);
    expect(media.canPause, isTrue);
    expect(media.canGoNext, isFalse);
    expect(media.canGoPrevious, isTrue);
  });

  test('media timeline reports only explicitly supplied supported values', () {
    final available = MediaInfo.fromJson({
      'Duration': 180.5,
      'Position': 42.25,
      'HasDuration': true,
      'HasPosition': true,
      'TimelineDurationStatus': 'available',
      'TimelinePositionStatus': 'available',
    });
    expect(available.duration, 180);
    expect(available.position, 42);
    expect(available.durationStatus, 'available');
    expect(available.positionStatus, 'available');

    final unsupported = MediaInfo.fromJson({
      'Duration': 0,
      'Position': 0,
      'HasDuration': false,
      'HasPosition': false,
      'TimelineDurationStatus': 'unsupported',
      'TimelinePositionStatus': 'unsupported',
    });
    expect(unsupported.hasDuration, isFalse);
    expect(unsupported.hasPosition, isFalse);
    expect(unsupported.formattedTimeline, 'CLOSED');
    expect(unsupported.durationStatus, 'unsupported');
    expect(unsupported.positionStatus, 'unsupported');
    expect(unsupported.timelineUpdatedAtStatus, 'unavailable');
  });

  test(
    'timeline supports position without duration and parses update time',
    () {
      final updatedAt = DateTime.utc(2026, 2, 3, 4, 5, 6);
      final media = MediaInfo.fromJson({
        'Status': 'Playing',
        'Position': 42.5,
        'HasDuration': false,
        'HasPosition': true,
        'TimelineDurationStatus': 'unavailable',
        'TimelinePositionStatus': 'available',
        'TimelineUpdatedAt': updatedAt.toIso8601String(),
        'TimelineUpdatedAtStatus': 'available',
      });

      expect(media.hasDuration, isFalse);
      expect(media.hasPosition, isTrue);
      expect(media.position, 42);
      expect(media.formattedTimeline, 'PLAYING');
      expect(media.timelineUpdatedAt, updatedAt);
      expect(media.timelineUpdatedAtStatus, 'available');
    },
  );

  test('timeline parser preserves unsupported timestamp status safely', () {
    final media = MediaInfo.fromJson({
      'Status': 'Paused',
      'TimelineUpdatedAt': '',
      'TimelineUpdatedAtStatus': 'unsupported',
      'TimelinePositionStatus': 'unsupported',
    });

    expect(media.timelineUpdatedAt, isNull);
    expect(media.timelineUpdatedAtStatus, 'unsupported');
    expect(media.positionStatus, 'unsupported');
  });

  test(
    'media timeline formatting handles unknown duration and long tracks',
    () {
      final unknown = MediaInfo(title: '', artist: '', status: 'Paused');
      final longTrack = MediaInfo(
        title: 'Track',
        artist: 'Artist',
        status: 'Playing',
        position: 3661,
        duration: 7322,
        hasPosition: true,
        hasDuration: true,
      );

      expect(unknown.formattedTimeline, 'PAUSED');
      expect(longTrack.formattedTimeline, '1:01:01 / 2:02:02');
    },
  );
}
