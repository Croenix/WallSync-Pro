import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart'
    show RequestLimitExceededException;
import 'package:wall_sync/services/youtube_wallpaper_service.dart';

void main() {
  group('YoutubeWallpaperService size limit', () {
    test('accepts sizes up to 95 MB and rejects larger streams', () {
      expect(YoutubeWallpaperService.maxVideoSizeBytes, 95 * 1024 * 1024);
      expect(
        YoutubeWallpaperService.isWithinVideoSizeLimit(
          YoutubeWallpaperService.maxVideoSizeBytes,
        ),
        isTrue,
      );
      expect(
        YoutubeWallpaperService.isWithinVideoSizeLimit(
          YoutubeWallpaperService.maxVideoSizeBytes + 1,
        ),
        isFalse,
      );
    });
  });

  group('YoutubeWallpaperCancellationToken', () {
    test('notifies listeners and throws after cancellation', () {
      final token = YoutubeWallpaperCancellationToken();
      var notified = false;
      token.addListener(() => notified = true);

      token.cancel();

      expect(token.isCancelled, isTrue);
      expect(notified, isTrue);
      expect(
        token.throwIfCancelled,
        throwsA(isA<YoutubeWallpaperCancelledException>()),
      );
    });
  });

  group('YoutubeWallpaperService.describeError', () {
    test('explains rate limits without exposing request details', () {
      final error = RequestLimitExceededException(
        'Rate limited. Request: GET https://www.youtube.com/watch?v=private-id',
      );

      final message = YoutubeWallpaperService.describeError(
        error,
        operation: 'load this YouTube video',
      );

      expect(message, contains('temporarily limiting requests'));
      expect(message, contains('Wait a while'));
      expect(message, isNot(contains('private-id')));
      expect(message, isNot(contains('https://')));
    });

    test('keeps actionable format validation messages', () {
      final message = YoutubeWallpaperService.describeError(
        const FormatException('Enter a valid YouTube video URL.'),
        operation: 'load this YouTube video',
      );

      expect(message, 'Enter a valid YouTube video URL.');
    });
  });
}
