import 'dart:developer' as developer;
import 'dart:io';

import 'package:ffmpeg_kit_extended_flutter/ffmpeg_kit_extended_flutter.dart'
    show FFmpegKit, FFmpegKitExtended, ReturnCode;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'settings_service.dart';

class YoutubeVideoDetails {
  const YoutubeVideoDetails({
    required this.id,
    required this.url,
    required this.title,
    required this.author,
    required this.duration,
  });

  final String id;
  final String url;
  final String title;
  final String author;
  final Duration duration;
}

class YoutubeWallpaperService {
  static const maxClipDuration = Duration(minutes: 1);
  static Future<void>? _ffmpegInitialization;

  Future<YoutubeVideoDetails> getVideoDetails(String url) async {
    final normalizedUrl = _validateYoutubeUrl(url);
    final youtube = YoutubeExplode();
    try {
      final video = await youtube.videos.get(normalizedUrl);
      if (video.isLive) {
        throw const FormatException(
          'Live broadcasts cannot be saved as wallpaper clips.',
        );
      }

      final duration = video.duration;
      if (duration == null || duration < const Duration(seconds: 1)) {
        throw const FormatException(
          'This YouTube video does not have a supported duration.',
        );
      }

      return YoutubeVideoDetails(
        id: video.id.value,
        url: video.url,
        title: video.title,
        author: video.author,
        duration: duration,
      );
    } finally {
      youtube.close();
    }
  }

  Future<File> createClip({
    required YoutubeVideoDetails video,
    required Duration start,
    required Duration end,
    void Function(String status)? onStatus,
  }) async {
    final clipDuration = end - start;
    if (start.isNegative ||
        clipDuration <= Duration.zero ||
        clipDuration > maxClipDuration ||
        end > video.duration) {
      throw const FormatException(
        'Select a video segment that is over 0 seconds and no longer than 1 minute.',
      );
    }

    final appDirectory = await SettingsService().getAppDirectory();
    final outputDirectory = Directory(
      '${appDirectory.path}${Platform.pathSeparator}video_wallpapers',
    );
    await outputDirectory.create(recursive: true);

    final output = File(
      '${outputDirectory.path}${Platform.pathSeparator}'
      'youtube_${video.id}_${start.inMilliseconds}_${end.inMilliseconds}.mp4',
    );
    if (await output.exists() && await output.length() > 0) return output;

    await (_ffmpegInitialization ??= FFmpegKitExtended.initialize().catchError((
      Object error,
    ) {
      _ffmpegInitialization = null;
      throw error;
    }));

    final youtube = YoutubeExplode();
    final source = File(
      '${outputDirectory.path}${Platform.pathSeparator}'
      'youtube_${video.id}_${DateTime.now().microsecondsSinceEpoch}.source.mp4',
    );

    try {
      onStatus?.call('Getting the video stream...');
      final metadata = await youtube.videos.get(video.url);
      if (metadata.isLive ||
          metadata.duration == null ||
          metadata.duration! < end) {
        throw const FormatException(
          'This YouTube video is no longer available as a downloadable clip.',
        );
      }

      final manifest = await youtube.videos.streams.getManifest(metadata.id);
      if (manifest.muxed.isEmpty) {
        throw const FormatException(
          'No compatible audio-and-video stream was found for this video.',
        );
      }
      final streamInfo = manifest.muxed.withHighestBitrate();

      onStatus?.call('Downloading the video...');
      final sink = source.openWrite();
      try {
        await for (final chunk in youtube.videos.streams.get(streamInfo)) {
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (!await source.exists() || await source.length() == 0) {
        throw const FileSystemException(
          'The YouTube video download was empty.',
        );
      }

      onStatus?.call('Preparing your wallpaper clip...');
      final command = [
        '-hide_banner',
        '-loglevel error',
        '-y',
        '-ss ${_seconds(start)}',
        '-i ${_quotePath(source.path)}',
        '-t ${_seconds(clipDuration)}',
        '-map 0:v:0',
        '-map 0:a?',
        '-c:v mpeg4',
        '-q:v 3',
        '-c:a aac',
        '-b:a 128k',
        '-movflags +faststart',
        _quotePath(output.path),
      ].join(' ');
      final session = await FFmpegKit.executeAsync(command);
      if (!ReturnCode.isSuccess(session.getReturnCode())) {
        throw FileSystemException(
          'FFmpeg could not create the wallpaper clip: '
          '${session.getOutput()?.trim() ?? 'unknown processing error'}',
          output.path,
        );
      }
      if (!await output.exists() || await output.length() == 0) {
        throw FileSystemException(
          'FFmpeg finished without creating a wallpaper clip.',
          output.path,
        );
      }
      return output;
    } catch (_) {
      if (await output.exists()) await output.delete();
      rethrow;
    } finally {
      youtube.close();
      if (await source.exists()) {
        try {
          await source.delete();
        } on FileSystemException catch (error, stackTrace) {
          developer.log(
            'Unable to remove temporary YouTube download: ${source.path}',
            error: error,
            stackTrace: stackTrace,
            name: 'YoutubeWallpaperService',
          );
        }
      }
    }
  }

  static String _validateYoutubeUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    const hosts = {
      'youtube.com',
      'www.youtube.com',
      'm.youtube.com',
      'music.youtube.com',
      'youtu.be',
    };
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        !hosts.contains(uri.host.toLowerCase())) {
      throw const FormatException('Enter a valid YouTube video URL.');
    }
    return uri.toString();
  }

  static String _seconds(Duration duration) =>
      (duration.inMilliseconds / Duration.millisecondsPerSecond)
          .toStringAsFixed(3);

  static String _quotePath(String path) =>
      '"${path.replaceAll(r'\', '/').replaceAll('"', r'\"')}"';
}
