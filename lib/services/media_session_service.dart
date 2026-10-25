import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:wall_sync/services/settings_service.dart';

class MediaInfo {
  final String title;
  final String artist;
  final String status; // 'Playing' | 'Paused' | 'Closed' | etc.
  final String source; // Application name e.g. Spotify, Chrome
  final String sessionId;
  final String album;
  final bool canPlay;
  final bool canPause;
  final bool canGoNext;
  final bool canGoPrevious;
  final int duration; // In seconds
  final int position; // In seconds
  final bool hasDuration;
  final bool hasPosition;
  final String durationStatus;
  final String positionStatus;
  final DateTime? timelineUpdatedAt;
  final String timelineUpdatedAtStatus;
  final String thumbnail; // Base64 image data

  MediaInfo({
    required this.title,
    required this.artist,
    required this.status,
    this.source = '',
    this.sessionId = '',
    this.album = '',
    this.duration = 0,
    this.position = 0,
    this.hasDuration = false,
    this.hasPosition = false,
    this.durationStatus = 'unavailable',
    this.positionStatus = 'unavailable',
    this.timelineUpdatedAt,
    this.timelineUpdatedAtStatus = 'unavailable',
    this.thumbnail = '',
    this.canPlay = false,
    this.canPause = false,
    this.canGoNext = false,
    this.canGoPrevious = false,
  });

  factory MediaInfo.fromJson(Map<String, dynamic> json) {
    final rawDuration = json['Duration'] is num
        ? (json['Duration'] as num).toDouble()
        : 0.0;
    final rawPosition = json['Position'] is num
        ? (json['Position'] as num).toDouble()
        : 0.0;
    final hasDuration =
        json['HasDuration'] == true && rawDuration.isFinite && rawDuration > 0;
    final hasPosition =
        json['HasPosition'] == true &&
        rawPosition.isFinite &&
        rawPosition >= 0 &&
        (!hasDuration || rawPosition <= rawDuration);
    String timelineStatus(Object? value, bool available) {
      final rawStatus = value is String ? value : null;
      if (rawStatus == 'available' ||
          rawStatus == 'unsupported' ||
          rawStatus == 'unavailable') {
        return rawStatus!;
      }
      return available ? 'available' : 'unavailable';
    }

    final rawUpdatedAt = json['TimelineUpdatedAt'];
    final timelineUpdatedAt = rawUpdatedAt is String
        ? DateTime.tryParse(rawUpdatedAt)
        : null;
    final timelineUpdatedAtStatus = timelineStatus(
      json['TimelineUpdatedAtStatus'],
      timelineUpdatedAt != null,
    );
    return MediaInfo(
      title: json['Title'] ?? '',
      artist: json['Artist'] ?? '',
      status: json['Status'] ?? 'Closed',
      source: json['Source'] ?? '',
      sessionId: json['SessionId'] ?? '',
      album: json['Album'] ?? '',
      duration: hasDuration ? rawDuration.toInt() : 0,
      position: hasPosition ? rawPosition.toInt() : 0,
      hasDuration: hasDuration,
      hasPosition: hasPosition,
      durationStatus: timelineStatus(
        json['TimelineDurationStatus'] as String?,
        hasDuration,
      ),
      positionStatus: timelineStatus(
        json['TimelinePositionStatus'] as String?,
        hasPosition,
      ),
      timelineUpdatedAt: timelineUpdatedAt,
      timelineUpdatedAtStatus: timelineUpdatedAtStatus,
      thumbnail: json['Thumbnail'] ?? '',
      canPlay: json['CanPlay'] == true,
      canPause: json['CanPause'] == true,
      canGoNext: json['CanGoNext'] == true,
      canGoPrevious: json['CanGoPrevious'] == true,
    );
  }

  bool get isPlaying => status.toLowerCase() == 'playing';

  String get formattedTimeline {
    if (!hasDuration || !hasPosition || duration <= 0) {
      return status.toUpperCase();
    }

    String formatTime(int secs) {
      final h = secs ~/ 3600;
      final m = (secs % 3600) ~/ 60;
      final s = secs % 60;

      if (h > 0) {
        return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      } else {
        return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      }
    }

    return '${formatTime(position)} / ${formatTime(duration)}';
  }
}

class MediaSessionService {
  static final MediaSessionService _instance = MediaSessionService._internal();
  factory MediaSessionService() => _instance;
  MediaSessionService._internal();

  Process? _powershellProcess;
  StreamSubscription? _stdoutSub;
  StreamSubscription? _stderrSub;
  final _controller = StreamController<MediaInfo>.broadcast();
  Stream<MediaInfo> get mediaStream => _controller.stream;

  MediaInfo _current = MediaInfo(
    title: '',
    artist: '',
    status: 'Closed',
    source: '',
    sessionId: '',
    album: '',
    duration: 0,
    position: 0,
    thumbnail: '',
  );
  MediaInfo get current => _current;

  bool _started = false;
  bool _startInProgress = false;
  final Set<String> _owners = {};
  bool get isStarted => _started;

  void start({String owner = 'default'}) async {
    _owners.add(owner);
    if (_startInProgress || (_started && _powershellProcess != null)) return;
    _startInProgress = true;
    _started = true;

    logInfo(
      'MediaSessionService',
      'Starting GSMTC monitoring for ${_owners.length} active consumer(s).',
    );

    if (!Platform.isWindows) {
      logInfo(
        'MediaSessionService',
        'GSMTC is only available on Windows; media monitoring is unavailable.',
      );
      _started = false;
      _startInProgress = false;
      _owners.remove(owner);
      return;
    }

    try {
      final script = '''
Add-Type -AssemblyName System.Runtime.WindowsRuntime

function Await(\$WinRtTask, \$ResultType) {
    if (-not \$WinRtTask) { return \$null }
    try {
        \$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | 
            Where-Object { \$_.Name -eq 'AsTask' -and \$_.GetParameters().Count -eq 1 -and \$_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
        
        \$asTask = \$asTaskGeneric.MakeGenericMethod(\$ResultType)
        \$netTask = \$asTask.Invoke(\$null, @(\$WinRtTask))
        if (-not \$netTask) { return \$null }
        if (\$netTask.IsCompleted) {
            if (\$netTask.IsFaulted -or \$netTask.IsCanceled) { return \$null }
            return \$netTask.Result
        }
        \$completed = \$netTask.Wait(4000)
        if (-not \$completed -or \$netTask.IsFaulted -or \$netTask.IsCanceled) {
            return \$null
        }
        return \$netTask.Result
    } catch {
        return \$null
    }
}

\$SessionManagerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]
\$SessionManager = Await (\$SessionManagerType::RequestAsync()) (\$SessionManagerType)

\$cachedTitle = ""
\$cachedArtist = ""
\$cachedAlbum = ""
\$cachedSessionId = ""
\$cachedBase64 = ""
\$lastSessionCount = -1
\$lastLoggedSessionId = ""
\$lastPlaybackStatus = ""
\$lastMetadataKey = ""
\$lastTimelineLog = [DateTime]::UtcNow
[Console]::Error.WriteLine("GSMTC session manager initialized.")

while (\$true) {
    \$sleepMs = 1000
    try {
        \$rawSessions = @(\$SessionManager.GetSessions())
        \$sessions = @(\$rawSessions | Where-Object {
            \$id = \$_.SourceAppUserModelId.ToLower()
            -not \$id.Contains("mpv") -and -not \$id.Contains("wallsync")
        })
        if (\$sessions.Count -ne \$lastSessionCount) {
            \$lastSessionCount = \$sessions.Count
            [Console]::Error.WriteLine("GSMTC session count changed: \$lastSessionCount")
        }
        \$currentSession = \$SessionManager.GetCurrentSession()
        if (\$currentSession) {
            \$currId = \$currentSession.SourceAppUserModelId.ToLower()
            if (\$currId.Contains("mpv") -or \$currId.Contains("wallsync")) {
                \$currentSession = \$null
            }
        }
        \$selectionReason = "Windows current session"
        \$availableSessions = @(\$sessions | Where-Object {
            \$_.GetPlaybackInfo().PlaybackStatus.ToString() -ne "Closed"
        })
        \$playingSessions = @(\$sessions | Where-Object {
            \$_.GetPlaybackInfo().PlaybackStatus.ToString() -eq "Playing"
        })
        if (\$currentSession -and
            \$currentSession.GetPlaybackInfo().PlaybackStatus.ToString() -eq "Closed") {
            \$currentSession = \$null
        }
        if (\$currentSession -and
            \$currentSession.GetPlaybackInfo().PlaybackStatus.ToString() -eq "Playing") {
            # Keep Windows' current session when it is actively playing.
        } elseif (\$playingSessions.Count -gt 0) {
            \$currentSession = \$playingSessions |
                Sort-Object SourceAppUserModelId |
                Select-Object -First 1
            \$selectionReason = "first playing session by application id"
        } elseif (-not \$currentSession -and \$sessions.Count -gt 0) {
            \$currentSession = \$availableSessions |
                Sort-Object SourceAppUserModelId |
                Select-Object -First 1
            \$selectionReason = "first available session by application id"
        }
        if (\$currentSession) {
            \$SessionType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSession, Windows.Media.Control, ContentType=WindowsRuntime]
            \$MediaPropertiesType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType=WindowsRuntime]
            
            \$props = Await (\$currentSession.TryGetMediaPropertiesAsync()) (\$MediaPropertiesType)
            \$status = \$currentSession.GetPlaybackInfo().PlaybackStatus.ToString()
            \$controls = \$currentSession.GetPlaybackInfo().Controls
            \$selectedId = \$currentSession.SourceAppUserModelId
            if (\$selectedId -ne \$lastLoggedSessionId) {
                \$lastLoggedSessionId = \$selectedId
                [Console]::Error.WriteLine("GSMTC selected session: \$selectedId (\$selectionReason)")
            }
            if (\$status -ne \$lastPlaybackStatus) {
                \$lastPlaybackStatus = \$status
                [Console]::Error.WriteLine("GSMTC playback status changed: \$status")
            }
            
            if (\$status -eq "Playing") {
                \$sleepMs = 1000
            } else {
                \$sleepMs = 2000
            }
            
            \$rawId = \$currentSession.SourceAppUserModelId.ToLower()
            \$appName = "System"
            if (\$rawId.Contains("spotify")) {
                \$appName = "Spotify"
            } elseif (\$rawId.Contains("chrome")) {
                \$appName = "Chrome"
            } elseif (\$rawId.Contains("edge")) {
                \$appName = "Edge"
            } elseif (\$rawId.Contains("brave")) {
                \$appName = "Brave"
            } elseif (\$rawId.Contains("firefox")) {
                \$appName = "Firefox"
            } elseif (\$rawId.Contains("vlc")) {
                \$appName = "VLC Media Player"
            } else {
                if (\$currentSession.SourceAppUserModelId -match '^([^.!_]+)') {
                    \$appName = \$Matches[1]
                    \$appName = (Get-Culture).TextInfo.ToTitleCase(\$appName)
                }
            }

            \$timeline = \$currentSession.GetTimelineProperties()
            \$duration = 0
            \$position = 0
            \$hasDuration = \$false
            \$hasPosition = \$false
            \$durationStatus = "unavailable"
            \$positionStatus = "unavailable"
            \$timelineUpdatedAt = ""
            \$timelineUpdatedAtStatus = "unavailable"
            if (\$timeline) {
                try {
                    \$durationValue = [double]\$timeline.EndTime.TotalSeconds
                    if (-not [double]::IsNaN(\$durationValue) -and
                        -not [double]::IsInfinity(\$durationValue) -and
                        \$durationValue -gt 0) {
                        \$duration = \$durationValue
                        \$hasDuration = \$true
                        \$durationStatus = "available"
                    }
                } catch {
                    \$durationStatus = "unsupported"
                }
                try {
                    \$positionValue = [double]\$timeline.Position.TotalSeconds
                    if (-not [double]::IsNaN(\$positionValue) -and
                        -not [double]::IsInfinity(\$positionValue) -and
                        \$positionValue -ge 0 -and
                        (-not \$hasDuration -or \$positionValue -le \$duration)) {
                        \$position = \$positionValue
                        \$hasPosition = \$true
                        \$positionStatus = "available"
                    }
                } catch {
                    \$positionStatus = "unsupported"
                }
                try {
                    \$lastUpdated = \$timeline.LastUpdatedTime
                    if (\$lastUpdated) {
                        \$timelineUpdatedAt = \$lastUpdated.ToUniversalTime().ToString("o")
                        \$timelineUpdatedAtStatus = "available"
                        if (\$hasPosition -and \$status -eq "Playing") {
                            \$elapsed = ([DateTimeOffset]::Now - \$lastUpdated).TotalSeconds
                            if (\$elapsed -gt 0 -and
                                -not [double]::IsNaN(\$elapsed) -and
                                -not [double]::IsInfinity(\$elapsed)) {
                                if (\$hasDuration) {
                                    \$position = [Math]::Min(\$duration, \$position + \$elapsed)
                                } else {
                                    \$position += \$elapsed
                                }
                            }
                        }
                    }
                } catch {
                    \$timelineUpdatedAtStatus = "unsupported"
                }
            }
            if (([DateTime]::UtcNow - \$lastTimelineLog).TotalSeconds -ge 30) {
                \$lastTimelineLog = [DateTime]::UtcNow
                \$positionState = if (\$hasPosition) { "available" } else { "unavailable" }
                \$durationState = if (\$hasDuration) { "available" } else { "unavailable" }
                [Console]::Error.WriteLine("GSMTC timeline fields (position=\$positionStatus, duration=\$durationStatus, updatedAt=\$(if (\$timelineUpdatedAt) { \$timelineUpdatedAt } else { 'unavailable' })).")
            }

            \$thumbToSend = ""
            if (\$props) {
                \$title = \$props.Title
                \$artist = \$props.Artist
                \$album = \$props.AlbumTitle
                \$sessionId = \$currentSession.SourceAppUserModelId
                \$metadataKey = "\$sessionId|\$title|\$artist|\$album"
                if (\$metadataKey -ne \$lastMetadataKey) {
                    \$lastMetadataKey = \$metadataKey
                    \$titleState = if ([string]::IsNullOrWhiteSpace(\$title)) { "missing" } else { "available" }
                    \$artistState = if ([string]::IsNullOrWhiteSpace(\$artist)) { "missing" } else { "available" }
                    \$albumState = if ([string]::IsNullOrWhiteSpace(\$album)) { "missing" } else { "available" }
                    [Console]::Error.WriteLine("GSMTC metadata updated for \$appName (title=\$titleState, artist=\$artistState, album=\$albumState, updatedAt=\$([DateTimeOffset]::UtcNow.ToString('o'))).")
                }
                if (\$title -ne \$cachedTitle -or
                    \$artist -ne \$cachedArtist -or
                    \$album -ne \$cachedAlbum -or
                    \$sessionId -ne \$cachedSessionId) {
                    \$cachedTitle = \$title
                    \$cachedArtist = \$artist
                    \$cachedAlbum = \$album
                    \$cachedSessionId = \$sessionId
                    \$cachedBase64 = ""
                    if (\$props.Thumbnail) {
                        \$stream = \$null
                        \$netStream = \$null
                        \$ms = \$null
                        try {
                            \$StreamType = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage, ContentType=WindowsRuntime]
                            \$stream = Await (\$props.Thumbnail.OpenReadAsync()) (\$StreamType)
                            if (\$stream) {
                                \$asStreamMethod = [System.IO.WindowsRuntimeStreamExtensions].GetMethods() |
                                    Where-Object {
                                        \$_.Name -eq "AsStreamForRead" -and
                                        \$_.GetParameters().Count -eq 1
                                    } |
                                    Select-Object -First 1
                                \$netStream = \$asStreamMethod.Invoke(\$null, @(\$stream))
                                \$ms = New-Object System.IO.MemoryStream
                                \$buffer = New-Object byte[] 81920
                                \$totalBytes = 0
                                while ((\$read = \$netStream.Read(\$buffer, 0, \$buffer.Length)) -gt 0) {
                                    \$totalBytes += \$read
                                    if (\$totalBytes -gt 5242880) {
                                        throw "Album-art stream exceeds the 5 MB limit."
                                    }
                                    \$ms.Write(\$buffer, 0, \$read)
                                }
                                if (\$totalBytes -gt 0) {
                                    \$cachedBase64 = [Convert]::ToBase64String(\$ms.ToArray())
                                    [Console]::Error.WriteLine("GSMTC album artwork retrieved (\$totalBytes bytes).")
                                }
                            } else {
                                [Console]::Error.WriteLine("Album-art reference was empty.")
                            }
                        } catch {
                            [Console]::Error.WriteLine("Album-art retrieval failed: " + \$_)
                            \$cachedBase64 = ""
                        } finally {
                            if (\$ms) { \$ms.Dispose() }
                            if (\$netStream) { \$netStream.Dispose() }
                            if (\$stream -and [Runtime.InteropServices.Marshal]::IsComObject(\$stream)) {
                                [Runtime.InteropServices.Marshal]::ReleaseComObject(\$stream) | Out-Null
                            }
                        }
                    }
                    \$thumbToSend = \$cachedBase64
                }
            } else {
                \$cachedTitle = ""
                \$cachedArtist = ""
                \$cachedAlbum = ""
                \$cachedSessionId = ""
                \$cachedBase64 = ""
            }

            \$info = @{
                Title = \$cachedTitle
                Artist = \$cachedArtist
                Album = if (\$props) { \$props.AlbumTitle } else { "" }
                Status = \$status
                Source = \$appName
                SessionId = \$currentSession.SourceAppUserModelId
                Duration = \$duration
                Position = \$position
                HasDuration = \$hasDuration
                HasPosition = \$hasPosition
                TimelineDurationStatus = \$durationStatus
                TimelinePositionStatus = \$positionStatus
                TimelineUpdatedAt = \$timelineUpdatedAt
                TimelineUpdatedAtStatus = \$timelineUpdatedAtStatus
                Thumbnail = \$thumbToSend
                CanPlay = \$controls.IsPlayEnabled
                CanPause = \$controls.IsPauseEnabled
                CanGoNext = \$controls.IsNextEnabled
                CanGoPrevious = \$controls.IsPreviousEnabled
            }
            Write-Output (ConvertTo-Json \$info -Compress)
        } else {
            if (\$lastLoggedSessionId -ne "") {
                [Console]::Error.WriteLine("GSMTC has no available media session.")
                \$lastLoggedSessionId = ""
            }
            \$cachedTitle = ""
            \$cachedArtist = ""
            \$cachedAlbum = ""
            \$cachedSessionId = ""
            \$cachedBase64 = ""
            \$lastMetadataKey = ""
            \$sleepMs = 4000
            if (\$lastPlaybackStatus -ne "Closed" -or \$lastLoggedSessionId -ne "") {
                \$lastLoggedSessionId = ""
                \$lastPlaybackStatus = "Closed"
                \$info = @{
                    Title = ""
                    Artist = ""
                    Status = "Closed"
                    Source = ""
                    SessionId = ""
                    Album = ""
                    Duration = 0
                    Position = 0
                    HasDuration = \$false
                    HasPosition = \$false
                    TimelineDurationStatus = "unavailable"
                    TimelinePositionStatus = "unavailable"
                    TimelineUpdatedAt = ""
                    TimelineUpdatedAtStatus = "unavailable"
                    Thumbnail = ""
                    CanPlay = \$false
                    CanPause = \$false
                    CanGoNext = \$false
                    CanGoPrevious = \$false
                }
                Write-Output (ConvertTo-Json \$info -Compress)
            }
        }
    } catch {
        [Console]::Error.WriteLine("Media session transient polling error: " + \$_)
        \$sleepMs = 3000
    }
    Start-Sleep -Milliseconds \$sleepMs
}
''';

      logInfo(
        'MediaSessionService',
        'Spawning PowerShell background process for media session monitoring...',
      );
      final process = await Process.start('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]);
      if (!_started) {
        process.kill();
        _startInProgress = false;
        return;
      }
      _powershellProcess = process;
      _startInProgress = false;
      logInfo(
        'MediaSessionService',
        'PowerShell background process spawned successfully.',
      );

      _stdoutSub?.cancel();
      _stdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            try {
              final trimmed = line.trim();
              if (trimmed.isEmpty) return;
              final json = jsonDecode(trimmed);
              if (json is Map<String, dynamic>) {
                final rawThumb = (json['Thumbnail'] as String?) ?? '';
                final title = json['Title'] as String? ?? '';
                final source = json['Source'] as String? ?? '';
                final sessionId = json['SessionId'] as String? ?? '';
                final sessionChanged =
                    title != _current.title ||
                    (json['Artist'] as String? ?? '') != _current.artist ||
                    (json['Album'] as String? ?? '') != _current.album ||
                    source != _current.source ||
                    sessionId != _current.sessionId;
                final effectiveThumb = rawThumb.isNotEmpty
                    ? rawThumb
                    : sessionChanged
                    ? ''
                    : _current.thumbnail;
                final parsedTimeline = MediaInfo.fromJson(json);
                final info = MediaInfo(
                  title: title,
                  artist: json['Artist'] as String? ?? '',
                  status: json['Status'] ?? 'Closed',
                  source: source,
                  sessionId: sessionId,
                  album: json['Album'] as String? ?? '',
                  duration: parsedTimeline.duration,
                  position: parsedTimeline.position,
                  hasDuration: parsedTimeline.hasDuration,
                  hasPosition: parsedTimeline.hasPosition,
                  durationStatus: parsedTimeline.durationStatus,
                  positionStatus: parsedTimeline.positionStatus,
                  thumbnail: effectiveThumb,
                  canPlay: json['CanPlay'] == true,
                  canPause: json['CanPause'] == true,
                  canGoNext: json['CanGoNext'] == true,
                  canGoPrevious: json['CanGoPrevious'] == true,
                );
                final hasChanged =
                    info.title != _current.title ||
                    info.artist != _current.artist ||
                    info.status != _current.status ||
                    info.source != _current.source ||
                    info.sessionId != _current.sessionId ||
                    info.album != _current.album ||
                    info.canPlay != _current.canPlay ||
                    info.canPause != _current.canPause ||
                    info.canGoNext != _current.canGoNext ||
                    info.canGoPrevious != _current.canGoPrevious ||
                    info.duration != _current.duration ||
                    info.position != _current.position ||
                    info.hasDuration != _current.hasDuration ||
                    info.hasPosition != _current.hasPosition ||
                    info.durationStatus != _current.durationStatus ||
                    info.positionStatus != _current.positionStatus ||
                    info.thumbnail != _current.thumbnail;
                final hasNonTimelineChange =
                    info.title != _current.title ||
                    info.artist != _current.artist ||
                    info.status != _current.status ||
                    info.source != _current.source ||
                    info.sessionId != _current.sessionId ||
                    info.album != _current.album ||
                    info.canPlay != _current.canPlay ||
                    info.canPause != _current.canPause ||
                    info.canGoNext != _current.canGoNext ||
                    info.canGoPrevious != _current.canGoPrevious ||
                    info.duration != _current.duration ||
                    info.hasDuration != _current.hasDuration ||
                    info.hasPosition != _current.hasPosition ||
                    info.durationStatus != _current.durationStatus ||
                    info.positionStatus != _current.positionStatus ||
                    info.thumbnail != _current.thumbnail;
                if (hasNonTimelineChange) {
                  logInfo(
                    'MediaSessionService',
                    'Media state received: source=${info.source.isEmpty ? "unknown" : info.source}, status=${info.status}, metadata=${info.title.isNotEmpty || info.artist.isNotEmpty || info.album.isNotEmpty ? "available" : "unavailable"}.',
                  );
                }
                if (hasChanged) {
                  _current = info;
                  _controller.add(info);
                }
              }
            } catch (e) {
              logError(
                'MediaSessionService',
                'Failed to parse a media-state JSON line.',
                e,
              );
            }
          });

      _stderrSub?.cancel();
      _stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final message = line.trim();
            if (message.isNotEmpty) {
              logWarning('MediaSessionService', message);
            }
          });

      // Handle process exit
      process.exitCode.then((code) {
        if (!_started) {
          logInfo(
            'MediaSessionService',
            'PowerShell media monitor exited after requested stop (code: $code).',
          );
          return;
        }
        if (identical(_powershellProcess, process)) {
          _powershellProcess = null;
        }
        logWarning(
          'MediaSessionService',
          'PowerShell media monitor exited unexpectedly (code: $code); scheduling restart.',
        );
        logInfo(
          'MediaSessionService',
          'Scheduling MediaSessionService restart in 5 seconds...',
        );
        Future.delayed(const Duration(seconds: 5), () {
          if (_started && _owners.isNotEmpty) start(owner: _owners.first);
        });
      });
    } catch (e, stack) {
      _startInProgress = false;
      _started = false;
      _powershellProcess = null;
      logError(
        'MediaSessionService',
        'Failed to start MediaSessionService',
        e,
        stack,
      );
    }
  }

  Future<bool> togglePlayPause() => _current.isPlaying ? pause() : play();

  Future<bool> play() {
    if (!_current.canPlay || _current.sessionId.isEmpty) {
      logWarning(
        'MediaSessionService',
        'Play is unsupported because the selected media session is unavailable or does not expose Play.',
      );
      return Future.value(false);
    }
    return _sendTransportCommand('Play');
  }

  Future<bool> pause() {
    if (!_current.canPause || _current.sessionId.isEmpty) {
      logWarning(
        'MediaSessionService',
        'Pause is unsupported because the selected media session is unavailable or does not expose Pause.',
      );
      return Future.value(false);
    }
    return _sendTransportCommand('Pause');
  }

  Future<bool> next() {
    if (!_current.canGoNext || _current.sessionId.isEmpty) {
      logWarning(
        'MediaSessionService',
        'Next is unsupported because the selected media session is unavailable or does not expose Next.',
      );
      return Future.value(false);
    }
    return _sendTransportCommand('Next');
  }

  Future<bool> previous() {
    if (!_current.canGoPrevious || _current.sessionId.isEmpty) {
      logWarning(
        'MediaSessionService',
        'Previous is unsupported because the selected media session is unavailable or does not expose Previous.',
      );
      return Future.value(false);
    }
    return _sendTransportCommand('Previous');
  }

  bool _commandInProgress = false;

  Future<bool> _sendTransportCommand(String action) async {
    if (!Platform.isWindows) return false;
    if (_commandInProgress) {
      logWarning(
        'MediaSessionService',
        'Ignoring overlapping $action command while another transport action is running.',
      );
      return false;
    }
    _commandInProgress = true;
    Process? process;
    try {
      final sessionId = _current.sessionId;
      final sessionBytes = <int>[
        for (final codeUnit in sessionId.codeUnits) ...[
          codeUnit & 0xFF,
          (codeUnit >> 8) & 0xFF,
        ],
      ];
      final encodedSessionId = base64Encode(sessionBytes);
      final script =
          '''
Add-Type -AssemblyName System.Runtime.WindowsRuntime
function Await(\$WinRtTask, \$ResultType) {
    if (-not \$WinRtTask) { return \$null }
    try {
        \$method = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object { \$_.Name -eq 'AsTask' -and \$_.GetParameters().Count -eq 1 -and \$_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
        \$task = \$method.MakeGenericMethod(\$ResultType).Invoke(\$null, @(\$WinRtTask))
        if (-not \$task) { return \$null }
        if (\$task.IsCompleted) {
            if (\$task.IsFaulted -or \$task.IsCanceled) { return \$null }
            return \$task.Result
        }
        \$completed = \$task.Wait(4000)
        if (-not \$completed -or \$task.IsFaulted -or \$task.IsCanceled) {
            return \$null
        }
        return \$task.Result
    } catch {
        return \$null
    }
}
\$targetId = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$encodedSessionId'))
\$action = '$action'
\$managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]
\$manager = Await (\$managerType::RequestAsync()) (\$managerType)
\$sessions = @(\$manager.GetSessions())
\$session = \$manager.GetCurrentSession()
if (\$session -and \$session.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Closed') {
    \$session = \$null
}
\$playing = @(\$sessions | Where-Object {
    \$_.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing'
})
\$available = @(\$sessions | Where-Object {
    \$_.GetPlaybackInfo().PlaybackStatus.ToString() -ne 'Closed'
})
if (\$session -and \$session.GetPlaybackInfo().PlaybackStatus.ToString() -eq 'Playing') {
    # Match the monitor's preference for the current playing session.
} elseif (\$playing.Count -gt 0) {
    \$session = \$playing | Sort-Object SourceAppUserModelId | Select-Object -First 1
} elseif (-not \$session) {
    \$session = \$available | Sort-Object SourceAppUserModelId | Select-Object -First 1
}
if (-not \$session) { exit 3 }
if (\$session.SourceAppUserModelId -ne \$targetId) { exit 6 }
switch (\$action) {
    'Play' { \$result = Await (\$session.TryPlayAsync()) ([bool]) }
    'Pause' { \$result = Await (\$session.TryPauseAsync()) ([bool]) }
    'Next' { \$result = Await (\$session.TrySkipNextAsync()) ([bool]) }
    'Previous' { \$result = Await (\$session.TrySkipPreviousAsync()) ([bool]) }
    default { exit 4 }
}
if (\$result) { 'OK' } else { exit 5 }
''';
      process = await Process.start('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]);
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          process!.kill();
          throw TimeoutException('Media transport command timed out.');
        },
      );
      final stdout = await stdoutFuture;
      final stderr = await stderrFuture;
      if (exitCode != 0 || stdout.trim() != 'OK') {
        logWarning(
          'MediaSessionService',
          '$action failed for the selected media session (exit $exitCode): ${stderr.trim()}',
        );
        return false;
      }
      logInfo(
        'MediaSessionService',
        '$action command accepted by the selected session.',
      );
      return true;
    } catch (e, stack) {
      logError(
        'MediaSessionService',
        'Failed to execute $action on the selected media session.',
        e,
        stack,
      );
      return false;
    } finally {
      _commandInProgress = false;
    }
  }

  void stop({String owner = 'default'}) {
    if (!_owners.remove(owner)) return;
    if (_owners.isNotEmpty) {
      logInfo(
        'MediaSessionService',
        'Retaining GSMTC monitor for ${_owners.length} active consumer(s).',
      );
      return;
    }
    if (!_started && _powershellProcess == null) return;
    logInfo('MediaSessionService', 'Stopping GSMTC monitor.');
    _started = false;
    _stdoutSub?.cancel();
    _stdoutSub = null;
    _stderrSub?.cancel();
    _stderrSub = null;
    final process = _powershellProcess;
    _powershellProcess = null;
    process?.kill();
  }

  Future<void> stopAndWait({String owner = 'default'}) async {
    final process = _powershellProcess;
    stop(owner: owner);
    if (process == null || identical(_powershellProcess, process)) return;
    await process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        logWarning(
          'MediaSessionService',
          'GSMTC PowerShell monitor did not exit within 2s after shutdown.',
        );
        return -1;
      },
    );
  }
}
