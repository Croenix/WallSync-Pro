import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:ffmpeg_kit_extended_flutter/ffmpeg_kit_extended_flutter.dart'
    show
        FFmpegKit,
        FFmpegKitExtended,
        FFprobeKit,
        ReturnCode,
        SessionCancelledException;
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

class YoutubeWallpaperProgress {
  const YoutubeWallpaperProgress({required this.message, this.fraction});

  final String message;
  final double? fraction;
}

class YoutubeWallpaperCancellationToken {
  bool _isCancelled = false;
  final Set<void Function()> _listeners = {};

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  void throwIfCancelled() {
    if (_isCancelled) throw const YoutubeWallpaperCancelledException();
  }

  void Function() addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

class YoutubeWallpaperCancelledException implements Exception {
  const YoutubeWallpaperCancelledException();
}

class YoutubeWallpaperService {
  static const maxClipDuration = Duration(minutes: 1);
  static const maxVideoSizeBytes = 95 * 1024 * 1024;
  static Future<void>? _ffmpegInitialization;
  static const _durationTolerance = Duration(seconds: 2);

  static bool isWithinVideoSizeLimit(int bytes) =>
      bytes > 0 && bytes <= maxVideoSizeBytes;

  static void _log(String message, {Object? error, StackTrace? stackTrace}) {
    developer.log(
      message,
      error: error,
      stackTrace: stackTrace,
      name: 'YoutubeWallpaperService',
    );
  }

  static String describeError(Object error, {required String operation}) {
    if (error is YoutubeWallpaperCancelledException ||
        error is SessionCancelledException) {
      return 'The YouTube wallpaper operation was canceled.';
    }
    if (error is RequestLimitExceededException) {
      return 'YouTube is temporarily limiting requests from this network. '
          'Wait a while before trying again; rapid retries can prolong the '
          'temporary limit.';
    }
    if (error is FatalFailureException) {
      return switch (error.statusCode) {
        403 =>
          'YouTube rejected the selected stream. It may have expired; '
              'fetch the video details again and retry.',
        404 =>
          'The selected YouTube stream is no longer available. '
              'Fetch the video details again and retry.',
        429 =>
          'YouTube is temporarily limiting requests from this network. '
              'Wait a while before trying again.',
        _ =>
          'YouTube returned HTTP ${error.statusCode} while trying to '
              '$operation.',
      };
    }
    if (error is TransientFailureException ||
        error is SocketException ||
        error is TimeoutException) {
      return 'The network connection interrupted while trying to $operation. '
          'Check your connection and retry.';
    }
    if (error is FormatException) return error.message;
    return 'Could not $operation: $error';
  }

  Future<YoutubeVideoDetails> getVideoDetails(
    String url, {
    YoutubeWallpaperCancellationToken? cancellationToken,
  }) async {
    final normalizedUrl = _validateYoutubeUrl(url);
    final youtube = YoutubeExplode();
    final removeCancelListener =
        cancellationToken?.addListener(youtube.close) ?? (() {});
    try {
      cancellationToken?.throwIfCancelled();
      final video = await youtube.videos.get(normalizedUrl);
      cancellationToken?.throwIfCancelled();
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
      removeCancelListener();
      youtube.close();
    }
  }

  Future<File> createClip({
    required YoutubeVideoDetails video,
    required Duration start,
    required Duration end,
    YoutubeWallpaperCancellationToken? cancellationToken,
    void Function(String status)? onStatus,
    void Function(YoutubeWallpaperProgress progress)? onProgress,
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

    final youtube = YoutubeExplode();
    final removeCancelListener =
        cancellationToken?.addListener(youtube.close) ?? (() {});
    File? source;
    File? audioSource;
    File? partialOutput;

    try {
      cancellationToken?.throwIfCancelled();
      onStatus?.call('Getting the video stream...');
      onProgress?.call(
        const YoutubeWallpaperProgress(message: 'Getting the video stream...'),
      );
      final metadata = await youtube.videos.get(video.url);
      cancellationToken?.throwIfCancelled();
      if (metadata.isLive ||
          metadata.duration == null ||
          metadata.duration! < end) {
        throw const FormatException(
          'This YouTube video is no longer available as a downloadable clip.',
        );
      }

      final manifest = await youtube.videos.streams.getManifest(metadata.id);
      final selectedStreams = _selectBestStreams(manifest);
      if (selectedStreams == null) {
        throw const FormatException(
          'No compatible YouTube streams were found under the 95 MB limit. '
          'The limit applies to the complete source streams, not just the '
          'selected clip.',
        );
      }

      final downloadId = DateTime.now().microsecondsSinceEpoch;
      final videoSource = File(
        '${outputDirectory.path}${Platform.pathSeparator}'
        'youtube_${video.id}_$downloadId.video.part.'
        '${selectedStreams.extension}',
      );
      source = videoSource;
      final separateAudioSource = selectedStreams.audio == null
          ? null
          : File(
              '${outputDirectory.path}${Platform.pathSeparator}'
              'youtube_${video.id}_$downloadId.audio.part.'
              '${selectedStreams.extension}',
            );
      audioSource = separateAudioSource;
      final clip = File(
        '${outputDirectory.path}${Platform.pathSeparator}'
        'youtube_${video.id}_${start.inMilliseconds}_${end.inMilliseconds}_'
        '${selectedStreams.resolution.width}x'
        '${selectedStreams.resolution.height}_'
        '${selectedStreams.cacheKey}.'
        '${selectedStreams.extension}',
      );
      await (_ffmpegInitialization ??= FFmpegKitExtended.initialize()
          .catchError((Object error) {
            _ffmpegInitialization = null;
            throw error;
          }));
      if (await clip.exists()) {
        if (await _isValidOutput(
          clip,
          clipDuration,
          cancellationToken: cancellationToken,
        )) {
          return clip;
        }
        await clip.delete();
      }
      final tempClip = File(
        '${clip.path.substring(0, clip.path.length - selectedStreams.extension.length - 1)}'
        '.partial.$downloadId.${selectedStreams.extension}',
      );
      partialOutput = tempClip;
      if (await tempClip.exists()) await tempClip.delete();

      final videoBytes = selectedStreams.video.size.totalBytes;
      final audioBytes = selectedStreams.audio?.size.totalBytes ?? 0;
      final totalBytes = videoBytes + audioBytes;
      if (!isWithinVideoSizeLimit(videoBytes) ||
          !isWithinVideoSizeLimit(totalBytes)) {
        throw const FormatException(
          'The selected YouTube video and audio streams exceed the 95 MB '
          'download limit.',
        );
      }

      onStatus?.call(
        'Downloading the complete ${selectedStreams.qualityLabel} source '
        'streams. YouTube does not provide reliable time-based byte ranges '
        'for this format.',
      );
      var downloadedBytes = 0;
      await _downloadStream(
        youtube,
        selectedStreams.video,
        videoSource,
        cancellationToken: cancellationToken,
        maxBytes: maxVideoSizeBytes - downloadedBytes,
        onBytes: (received, expected) {
          final combined = downloadedBytes + received;
          onProgress?.call(
            YoutubeWallpaperProgress(
              message:
                  'Downloading ${selectedStreams.qualityLabel} video '
                  '(${_formatBytes(received)} / ${_formatBytes(expected)})...',
              fraction: (combined / totalBytes).clamp(0, 0.99).toDouble(),
            ),
          );
        },
      );
      downloadedBytes += videoBytes;
      if (selectedStreams.audio case final audio?) {
        cancellationToken?.throwIfCancelled();
        await _downloadStream(
          youtube,
          audio,
          separateAudioSource!,
          cancellationToken: cancellationToken,
          maxBytes: maxVideoSizeBytes - downloadedBytes,
          onBytes: (received, expected) {
            final combined = downloadedBytes + received;
            onProgress?.call(
              YoutubeWallpaperProgress(
                message:
                    'Downloading ${selectedStreams.qualityLabel} audio '
                    '(${_formatBytes(received)} / ${_formatBytes(expected)})...',
                fraction: (combined / totalBytes).clamp(0, 0.99).toDouble(),
              ),
            );
          },
        );
        downloadedBytes += audioBytes;
      }

      cancellationToken?.throwIfCancelled();
      onStatus?.call('Trimming and combining the selected video and audio...');
      onProgress?.call(
        const YoutubeWallpaperProgress(
          message: 'Trimming and combining video and audio...',
        ),
      );
      final commandParts = <String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-ss',
        _seconds(start),
        '-i',
        videoSource.path,
      ];
      if (separateAudioSource != null) {
        commandParts.addAll([
          '-ss',
          _seconds(start),
          '-i',
          separateAudioSource.path,
        ]);
      }
      commandParts.addAll([
        '-t',
        _seconds(clipDuration),
        '-map',
        '0:v:0',
        '-map',
        if (separateAudioSource == null) '0:a:0?' else '1:a:0',
        '-c',
        'copy',
        if (selectedStreams.extension == 'mp4') ...['-movflags', '+faststart'],
        '-avoid_negative_ts',
        'make_zero',
        tempClip.path,
      ]);
      final ffmpegSession = FFmpegKit.createSessionFromArguments(commandParts);
      final removeFfmpegCancelListener =
          cancellationToken?.addListener(
            () => FFmpegKit.cancel(ffmpegSession),
          ) ??
          (() {});
      final session = await (() async {
        try {
          return await ffmpegSession.executeAsync(
            statisticsCallback: (statistics) {
              final progress = (statistics.time / clipDuration.inMilliseconds)
                  .clamp(0, 0.99)
                  .toDouble();
              onProgress?.call(
                YoutubeWallpaperProgress(
                  message:
                      'Processing clip (${(progress * 100).round()}% of '
                      'selected duration)...',
                  fraction: progress,
                ),
              );
            },
            logCallback: (log) {
              _log('FFmpeg: ${log.message}');
            },
          );
        } finally {
          removeFfmpegCancelListener();
        }
      })();
      cancellationToken?.throwIfCancelled();
      final returnCode = session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        if (ReturnCode.isCancel(returnCode)) {
          throw const YoutubeWallpaperCancelledException();
        }
        final ffmpegOutput =
            session.getOutput()?.trim() ??
            session.getLogsAsString()?.trim() ??
            'No FFmpeg diagnostic output was reported.';
        _log(
          'FFmpeg failed with return code $returnCode for video ${video.id}: '
          '$ffmpegOutput',
        );
        throw FileSystemException(
          'FFmpeg could not create the wallpaper clip (return code '
          '$returnCode): $ffmpegOutput',
          tempClip.path,
        );
      }
      if (!await tempClip.exists() || await tempClip.length() == 0) {
        throw FileSystemException(
          'FFmpeg finished without creating a wallpaper clip.',
          tempClip.path,
        );
      }
      if (await tempClip.length() > maxVideoSizeBytes) {
        throw const FormatException(
          'The processed wallpaper clip exceeds the 95 MB file-size limit.',
        );
      }

      cancellationToken?.throwIfCancelled();
      onProgress?.call(
        const YoutubeWallpaperProgress(
          message: 'Verifying the finished clip...',
        ),
      );
      if (!await _isValidOutput(
        tempClip,
        clipDuration,
        cancellationToken: cancellationToken,
      )) {
        throw const FormatException(
          'The processed clip failed media validation. The video may be '
          'incomplete, or the selected range may fall between keyframes.',
        );
      }

      cancellationToken?.throwIfCancelled();
      try {
        await tempClip.rename(clip.path);
      } on FileSystemException {
        if (!await clip.exists() ||
            !await _isValidOutput(
              clip,
              clipDuration,
              cancellationToken: cancellationToken,
            )) {
          rethrow;
        }
        await tempClip.delete();
      }
      onProgress?.call(
        const YoutubeWallpaperProgress(
          message: 'Clip saved and verified.',
          fraction: 1,
        ),
      );
      _log(
        'Saved YouTube clip for ${video.id} at '
        '${selectedStreams.resolution.width}x'
        '${selectedStreams.resolution.height}; '
        'video=${_formatBytes(videoBytes)}, '
        'audio=${_formatBytes(audioBytes)}, '
        'range=${_seconds(start)}-${_seconds(end)}s, '
        'output=${await clip.length()} bytes.',
      );
      return clip;
    } catch (error, stackTrace) {
      _log(
        'YouTube clip creation failed for ${video.id}.',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    } finally {
      removeCancelListener();
      youtube.close();
      final tempClip = partialOutput;
      if (tempClip != null && await tempClip.exists()) {
        try {
          await tempClip.delete();
        } on FileSystemException catch (error, stackTrace) {
          _log(
            'Could not remove partial output ${tempClip.path}.',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      final videoSource = source;
      if (videoSource != null && await videoSource.exists()) {
        try {
          await videoSource.delete();
        } on FileSystemException catch (error, stackTrace) {
          developer.log(
            'Unable to remove temporary YouTube download: '
            '${videoSource.path}',
            error: error,
            stackTrace: stackTrace,
            name: 'YoutubeWallpaperService',
          );
        }
      }
      final downloadedAudio = audioSource;
      if (downloadedAudio != null && await downloadedAudio.exists()) {
        try {
          await downloadedAudio.delete();
        } on FileSystemException catch (error, stackTrace) {
          developer.log(
            'Unable to remove temporary YouTube audio download: '
            '${downloadedAudio.path}',
            error: error,
            stackTrace: stackTrace,
            name: 'YoutubeWallpaperService',
          );
        }
      }
    }
  }

  static _SelectedYoutubeStreams? _selectBestStreams(StreamManifest manifest) {
    for (final video in manifest.videoOnly.sortByVideoQuality()) {
      final extension = _supportedExtension(video.container.name);
      if (extension == null) continue;

      final matchingAudio = manifest.audioOnly
          .where((audio) => audio.container == video.container)
          .toList();
      if (matchingAudio.isEmpty) continue;
      final defaultAudio = matchingAudio
          .where((audio) => audio.audioTrack?.audioIsDefault ?? true)
          .toList();
      final audioCandidates =
          (defaultAudio.isEmpty ? matchingAudio : defaultAudio)
              .where(
                (audio) =>
                    isWithinVideoSizeLimit(video.size.totalBytes) &&
                    isWithinVideoSizeLimit(audio.size.totalBytes) &&
                    isWithinVideoSizeLimit(
                      video.size.totalBytes + audio.size.totalBytes,
                    ),
              )
              .toList();
      if (audioCandidates.isEmpty) continue;
      final audio = audioCandidates.withHighestBitrate();

      return _SelectedYoutubeStreams(
        video: video,
        audio: audio,
        resolution: video.videoResolution,
        qualityLabel: video.qualityLabel,
        extension: extension,
        cacheKey: '${video.tag}_${audio.tag}',
      );
    }

    final muxedStreams = manifest.muxed
        .where(
          (stream) =>
              _supportedExtension(stream.container.name) != null &&
              isWithinVideoSizeLimit(stream.size.totalBytes),
        )
        .toList();
    if (muxedStreams.isEmpty) return null;

    final muxed = muxedStreams.withHighestBitrate();
    return _SelectedYoutubeStreams(
      video: muxed,
      audio: null,
      resolution: muxed.videoResolution,
      qualityLabel: muxed.qualityLabel,
      extension: _supportedExtension(muxed.container.name)!,
      cacheKey: '${muxed.tag}_muxed',
    );
  }

  static String? _supportedExtension(String container) =>
      switch (container.toLowerCase()) {
        'mp4' => 'mp4',
        'webm' => 'webm',
        _ => null,
      };

  static Future<void> _downloadStream(
    YoutubeExplode youtube,
    StreamInfo streamInfo,
    File destination, {
    required YoutubeWallpaperCancellationToken? cancellationToken,
    required int maxBytes,
    required void Function(int received, int expected) onBytes,
  }) async {
    final expectedBytes = streamInfo.size.totalBytes;
    if (expectedBytes <= 0 || expectedBytes > maxBytes) {
      throw const FormatException(
        'The selected YouTube stream exceeds the 95 MB download limit.',
      );
    }
    final sink = destination.openWrite();
    final stream = StreamIterator(
      youtube.videos.streams
          .get(streamInfo)
          .timeout(
            const Duration(seconds: 90),
            onTimeout: (controller) {
              controller.addError(
                TimeoutException('No data received from the YouTube stream.'),
              );
              controller.close();
            },
          ),
    );
    final removeCancelListener =
        cancellationToken?.addListener(youtube.close) ?? (() {});
    var receivedBytes = 0;
    try {
      while (await stream.moveNext()) {
        cancellationToken?.throwIfCancelled();
        final chunk = stream.current;
        receivedBytes += chunk.length;
        if (receivedBytes > maxBytes) {
          throw const FormatException(
            'The YouTube download exceeded the 95 MB size limit.',
          );
        }
        if (receivedBytes > expectedBytes) {
          throw FormatException(
            'YouTube returned more bytes than its reported stream size '
            '(${_formatBytes(receivedBytes)} > '
            '${_formatBytes(expectedBytes)}).',
          );
        }
        sink.add(chunk);
        onBytes(receivedBytes, expectedBytes);
      }
      cancellationToken?.throwIfCancelled();
      await sink.flush();
    } finally {
      removeCancelListener();
      await stream.cancel();
      await sink.close();
    }
    if (!await destination.exists() ||
        await destination.length() != expectedBytes ||
        receivedBytes != expectedBytes) {
      final actualBytes = await destination.exists()
          ? await destination.length()
          : 0;
      throw FileSystemException(
        'The YouTube ${streamInfo is AudioOnlyStreamInfo ? 'audio' : 'video'} '
        'stream was incomplete: received ${_formatBytes(actualBytes)} of '
        '${_formatBytes(expectedBytes)}.',
        destination.path,
      );
    }
    onBytes(expectedBytes, expectedBytes);
    _log(
      'Downloaded ${streamInfo is AudioOnlyStreamInfo ? 'audio' : 'video'} '
      'stream tag ${streamInfo.tag}: ${_formatBytes(receivedBytes)}.',
    );
  }

  static Future<bool> _isValidOutput(
    File file,
    Duration requestedDuration, {
    YoutubeWallpaperCancellationToken? cancellationToken,
  }) async {
    if (!await file.exists()) return false;
    final fileSize = await file.length();
    if (fileSize == 0 || fileSize > maxVideoSizeBytes) {
      _log(
        'Media file size is outside the allowed limit for ${file.path}: '
        '${_formatBytes(fileSize)}.',
      );
      return false;
    }
    cancellationToken?.throwIfCancelled();
    final probeSession = FFprobeKit.createSession(
      '-v error -show_entries format=duration:stream=codec_type,width,height '
      '-of json ${_quotePath(file.path)}',
    );
    final removeProbeCancelListener =
        cancellationToken?.addListener(() => FFprobeKit.cancel(probeSession)) ??
        (() {});
    try {
      final probe = await probeSession.executeAsync();
      cancellationToken?.throwIfCancelled();
      final returnCode = probe.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        _log(
          'FFprobe could not validate ${file.path}: '
          '${probe.getOutput() ?? probe.getLogsAsString() ?? 'no output'}',
        );
        return false;
      }

      final output = probe.getOutput();
      if (output == null) {
        _log('FFprobe returned no media information for ${file.path}.');
        return false;
      }
      final information = jsonDecode(output) as Map<String, dynamic>;
      final format = information['format'] as Map<String, dynamic>?;
      final streams = information['streams'] as List<dynamic>?;
      final actualDuration = double.tryParse('${format?['duration'] ?? ''}');
      final hasVideo =
          streams?.whereType<Map<String, dynamic>>().any(
            (stream) =>
                stream['codec_type'] == 'video' &&
                (stream['width'] as num? ?? 0) > 0 &&
                (stream['height'] as num? ?? 0) > 0,
          ) ??
          false;
      final hasAudio =
          streams?.whereType<Map<String, dynamic>>().any(
            (stream) => stream['codec_type'] == 'audio',
          ) ??
          false;
      final durationMatches =
          actualDuration != null &&
          (actualDuration - requestedDuration.inMilliseconds / 1000).abs() <=
              _durationTolerance.inMilliseconds / 1000;
      if (!hasVideo || !hasAudio || !durationMatches) {
        _log(
          'Media validation failed for ${file.path}: '
          'video=$hasVideo audio=$hasAudio duration=$actualDuration '
          'requested=${requestedDuration.inMilliseconds / 1000}s.',
        );
        return false;
      }
      return true;
    } on FormatException catch (error, stackTrace) {
      _log(
        'FFprobe returned invalid media data for ${file.path}.',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    } finally {
      removeProbeCancelListener();
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

  static String _formatBytes(int bytes) {
    const mb = 1024 * 1024;
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
}

class _SelectedYoutubeStreams {
  const _SelectedYoutubeStreams({
    required this.video,
    required this.audio,
    required this.resolution,
    required this.qualityLabel,
    required this.extension,
    required this.cacheKey,
  });

  final StreamInfo video;
  final StreamInfo? audio;
  final VideoResolution resolution;
  final String qualityLabel;
  final String extension;
  final String cacheKey;
}
