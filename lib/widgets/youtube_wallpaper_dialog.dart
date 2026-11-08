import 'dart:io';

import 'package:flutter/material.dart';

import '../services/youtube_wallpaper_service.dart';

class YoutubeWallpaperDialog extends StatefulWidget {
  const YoutubeWallpaperDialog({super.key});

  @override
  State<YoutubeWallpaperDialog> createState() => _YoutubeWallpaperDialogState();
}

class _YoutubeWallpaperDialogState extends State<YoutubeWallpaperDialog> {
  final _urlController = TextEditingController();
  final _service = YoutubeWallpaperService();
  YoutubeVideoDetails? _video;
  RangeValues _selection = const RangeValues(0, 60);
  String? _error;
  String _status = '';
  double? _progress;
  bool _isBusy = false;
  YoutubeWallpaperCancellationToken? _cancellationToken;

  @override
  void dispose() {
    _cancellationToken?.cancel();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _loadVideo() async {
    setState(() {
      _isBusy = true;
      _error = null;
      _video = null;
      _status = 'Fetching video details...';
      _progress = null;
    });
    final cancellationToken = YoutubeWallpaperCancellationToken();
    _cancellationToken = cancellationToken;
    try {
      final video = await _service.getVideoDetails(
        _urlController.text,
        cancellationToken: cancellationToken,
      );
      if (!mounted) return;
      final maxSeconds = video.duration.inMilliseconds / 1000;
      setState(() {
        _video = video;
        _selection = RangeValues(0, maxSeconds < 60 ? maxSeconds : 60);
        _status = '';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = YoutubeWallpaperService.describeError(
          error,
          operation: 'load this YouTube video',
        );
        _status = '';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _progress = null;
          _cancellationToken = null;
        });
      }
    }
  }

  Future<void> _createClip() async {
    final video = _video;
    if (video == null) return;
    final start = Duration(milliseconds: (_selection.start * 1000).round());
    final end = Duration(milliseconds: (_selection.end * 1000).round());
    setState(() {
      _isBusy = true;
      _error = null;
      _status = 'Preparing your wallpaper clip...';
      _progress = null;
    });
    final cancellationToken = YoutubeWallpaperCancellationToken();
    _cancellationToken = cancellationToken;
    try {
      final clip = await _service.createClip(
        video: video,
        start: start,
        end: end,
        cancellationToken: cancellationToken,
        onStatus: (status) {
          if (mounted) {
            setState(() {
              _status = status;
              _progress = null;
            });
          }
        },
        onProgress: (progress) {
          if (mounted) {
            setState(() {
              _status = progress.message;
              _progress = progress.fraction;
            });
          }
        },
      );
      if (mounted) Navigator.of(context).pop<File>(clip);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = YoutubeWallpaperService.describeError(
          error,
          operation: 'create the wallpaper clip',
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _isBusy = false;
          _progress = null;
          _cancellationToken = null;
        });
      }
    }
  }

  void _cancelCurrentOperation() {
    final token = _cancellationToken;
    if (token == null || token.isCancelled) return;
    setState(() {
      _status = 'Canceling and removing incomplete files...';
      _progress = null;
    });
    token.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    final maxSeconds = video == null
        ? 60.0
        : (video.duration.inMilliseconds / 1000)
              .clamp(1.0, double.infinity)
              .toDouble();
    return AlertDialog(
      backgroundColor: const Color(0xFF171B2A),
      title: const Text(
        'Create YouTube wallpaper',
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Import a YouTube video and save a clip of up to 60 seconds '
                'for offline playback.',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 8),
              const Text(
                'The highest available resolution is preserved without '
                're-encoding (up to 8K when available). Source streams are '
                'downloaded before trimming because YouTube does not provide '
                'reliable time-indexed byte ranges for these streams. '
                'The combined source downloads and saved clip are each '
                'limited to 95 MB. A short selected segment can still be '
                'unavailable if its complete source streams exceed that cap.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _urlController,
                enabled: !_isBusy,
                keyboardType: TextInputType.url,
                onChanged: (value) {
                  if (_video != null && value.trim() != _video!.url) {
                    setState(() {
                      _video = null;
                      _error = null;
                    });
                  }
                },
                decoration: InputDecoration(
                  labelText: 'YouTube video URL',
                  hintText: 'https://www.youtube.com/watch?v=...',
                  labelStyle: const TextStyle(color: Colors.white70),
                  hintStyle: const TextStyle(color: Colors.white38),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF38BDF8)),
                  ),
                ),
                style: const TextStyle(color: Colors.white),
                onSubmitted: (_) {
                  if (!_isBusy) _loadVideo();
                },
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _isBusy ? null : _loadVideo,
                icon: const Icon(Icons.search_rounded),
                label: const Text('Fetch video details'),
              ),
              if (video != null) ...[
                const SizedBox(height: 16),
                Text(
                  video.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${video.author} · ${_formatDuration(video.duration)}',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Text(
                  'Clip: ${_formatSeconds(_selection.start)} – '
                  '${_formatSeconds(_selection.end)} '
                  '(${_formatSeconds(_selection.end - _selection.start)})',
                  style: const TextStyle(color: Colors.white),
                ),
                RangeSlider(
                  values: _selection,
                  min: 0,
                  max: maxSeconds,
                  divisions: video.duration.inSeconds,
                  onChanged: _isBusy
                      ? null
                      : (values) {
                          var start = values.start;
                          var end = values.end;
                          final movingStart =
                              (start - _selection.start).abs() >
                              (end - _selection.end).abs();
                          if (end - start > 60) {
                            if (movingStart) {
                              end = start + 60;
                            } else {
                              start = end - 60;
                            }
                          }
                          if (end - start < 1) {
                            if (movingStart) {
                              start = end - 1;
                            } else {
                              end = start + 1;
                            }
                          }
                          start = start.clamp(0, maxSeconds - 1).toDouble();
                          end = end.clamp(start + 1, maxSeconds).toDouble();
                          setState(() {
                            _selection = RangeValues(start, end);
                          });
                        },
                ),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Start',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    Text(
                      'End',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ],
                ),
              ],
              if (_status.isNotEmpty) ...[
                const SizedBox(height: 12),
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _status,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 12),
              const Text(
                'Playback at very high resolutions depends on your Windows '
                'video decoder. Only save videos you have permission to use.',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isBusy
              ? _cancelCurrentOperation
              : () => Navigator.of(context).pop(),
          child: Text(_isBusy ? 'Cancel operation' : 'Cancel'),
        ),
        FilledButton.icon(
          onPressed: _isBusy || video == null ? null : _createClip,
          icon: const Icon(Icons.movie_creation_outlined),
          label: const Text('Create clip'),
        ),
      ],
    );
  }

  static String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  static String _formatSeconds(double seconds) {
    final duration = Duration(milliseconds: (seconds * 1000).round());
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final remainingSeconds = duration.inSeconds
        .remainder(60)
        .toString()
        .padLeft(2, '0');
    final milliseconds = duration.inMilliseconds
        .remainder(1000)
        .toString()
        .padLeft(3, '0');
    return '$minutes:$remainingSeconds.$milliseconds';
  }
}
