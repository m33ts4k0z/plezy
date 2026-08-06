import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;

import 'package:os_media_controls/os_media_controls.dart';
import 'package:rate_limiter/rate_limiter.dart';

import '../media/media_server_client.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
import '../media/media_kind.dart';
import '../utils/app_logger.dart';
import 'plezy_media_notification.dart';

/// Manages OS media controls integration for video playback.
///
/// Handles:
/// - Metadata updates (title, artwork, etc.)
/// - Playback state updates (playing/paused, position, speed)
/// - Control event streaming (play, pause, next, previous, seek)
/// - Position update throttling to prevent excessive API calls
class MediaControlsManager {
  /// Unified stream for the OS session and the persistent Android
  /// notification, translated to the standard media-control event types.
  Stream<MediaControlEvent> get controlEvents => _mergedControlEvents.stream;

  /// Throttled playback state update (1 second interval, leading + trailing)
  late final Throttle _throttledUpdate;

  /// Cached control enabled state to avoid redundant platform calls
  bool? _lastCanPlayPause;
  bool? _lastCanGoNext;
  bool? _lastCanGoPrevious;
  bool? _lastCanSeek;
  bool? _lastCanStop;
  bool? _lastCanSkip;
  bool? _lastCanSetSpeed;
  bool _updatesSuspended = false;

  String? _cachedTitle;
  String? _cachedArtist;
  String? _cachedAlbum;
  Uint8List? _cachedArtwork;
  Duration? _cachedDuration;
  bool _cachedIsPlaying = false;
  Duration _cachedPosition = Duration.zero;
  double _cachedSpeed = 1.0;

  final StreamController<MediaControlEvent> _mergedControlEvents = StreamController<MediaControlEvent>.broadcast();
  StreamSubscription<MediaControlEvent>? _osControlsSub;
  StreamSubscription<PlezyMediaNotificationEvent>? _plezyNotificationSub;

  MediaControlsManager() {
    _throttledUpdate = throttle(
      _doUpdatePlaybackState,
      const Duration(seconds: 1),
      leading: true,
      trailing: true, // Send final position at end of throttle window
    );
    _osControlsSub = OsMediaControls.controlEvents.listen(_mergedControlEvents.add);
    if (defaultTargetPlatform == TargetPlatform.android) {
      PlezyMediaNotification.instance.start();
      _plezyNotificationSub = PlezyMediaNotification.instance.events.listen((event) {
        _mergedControlEvents.add(_translatePlezyEvent(event));
        if (event is PlezyMediaStop) unawaited(clear());
      });
    }
  }

  MediaControlEvent _translatePlezyEvent(PlezyMediaNotificationEvent event) => switch (event) {
    PlezyMediaPlay() => const PlayEvent(),
    PlezyMediaPause() => const PauseEvent(),
    PlezyMediaTogglePlayPause() => const TogglePlayPauseEvent(),
    PlezyMediaNext() => const NextTrackEvent(),
    PlezyMediaPrevious() => const PreviousTrackEvent(),
    PlezyMediaStop() => const StopEvent(),
    PlezyMediaSeek(:final position) => SeekEvent(position),
    PlezyMediaFastForward() => const SkipForwardEvent(null),
    PlezyMediaRewind() => const SkipBackwardEvent(null),
  };

  /// Update media metadata displayed in OS media controls
  ///
  /// This includes title, artist, artwork, and duration. Backend-neutral —
  /// the [MediaServerClient.thumbnailUrl] adapter handles per-backend URL
  /// shape (Plex's `/photo/:/transcode` proxy vs. Jellyfin's
  /// self-authenticated image URL).
  Future<void> updateMetadata({required MediaItem metadata, MediaServerClient? client, Duration? duration}) async {
    if (_updatesSuspended) return;

    try {
      String? artworkUrl;
      Uint8List? artworkBytes;
      if (client != null && metadata.thumbPath != null) {
        try {
          artworkUrl = client.thumbnailUrl(metadata.thumbPath!);
          appLogger.d('Artwork URL for media controls: $artworkUrl');
        } catch (e) {
          appLogger.w('Failed to build artwork URL', error: e);
        }
        if (defaultTargetPlatform == TargetPlatform.android) {
          try {
            artworkBytes = await client.fetchThumbnailBytes(metadata.thumbPath!, width: 1024, height: 1024);
          } catch (e) {
            appLogger.w('Failed to fetch artwork bytes for media controls', error: e);
          }
        }
      }

      final title = metadata.title ?? '';
      final artist = _buildArtist(metadata);
      final album = metadata.kind == MediaKind.track ? metadata.albumTitle : null;

      await OsMediaControls.setMetadata(
        MediaMetadata(
          title: title,
          artist: artist,
          // Music-only: null for video content, so video behavior is untouched.
          album: album,
          artwork: artworkBytes,
          artworkUrl: artworkUrl,
          duration: duration,
        ),
      );

      _cachedTitle = title;
      _cachedArtist = artist;
      _cachedAlbum = album;
      _cachedArtwork = artworkBytes;
      _cachedDuration = duration;
      await _pushPlezyNotification();

      appLogger.d('Updated media controls metadata: ${metadata.title}');
    } catch (e) {
      appLogger.w('Failed to update media controls metadata', error: e);
    }
  }

  Future<void> _pushPlezyNotification() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    final title = _cachedTitle;
    if (title == null) return;
    await PlezyMediaNotification.instance.update(
      title: title,
      artist: _cachedArtist ?? _cachedAlbum,
      artwork: _cachedArtwork,
      isPlaying: _cachedIsPlaying,
      position: _cachedPosition,
      duration: _cachedDuration,
      speed: _cachedSpeed,
      canGoNext: _lastCanGoNext ?? false,
      canGoPrevious: _lastCanGoPrevious ?? false,
    );
  }

  /// Update playback state in OS media controls
  ///
  /// Updates the current playing state, position, and playback speed.
  /// Position updates are throttled to avoid excessive API calls.
  Future<void> updatePlaybackState({
    required bool isPlaying,
    required Duration position,
    required double speed,
    bool force = false,
  }) async {
    if (_updatesSuspended) return;

    final params = _PlaybackStateParams(isPlaying: isPlaying, position: position, speed: speed);

    if (force) {
      // Cancel any pending throttled update to prevent stale state from overwriting
      _throttledUpdate.cancel();
      await _doUpdatePlaybackState(params);
    } else {
      _throttledUpdate([params]);
    }
  }

  Future<void> _doUpdatePlaybackState(_PlaybackStateParams params) async {
    _cachedIsPlaying = params.isPlaying;
    _cachedPosition = params.position;
    _cachedSpeed = params.speed;
    try {
      await OsMediaControls.setPlaybackState(
        MediaPlaybackState(
          state: params.isPlaying ? PlaybackState.playing : PlaybackState.paused,
          position: params.position,
          speed: params.speed,
        ),
      );
    } catch (e) {
      appLogger.w('Failed to update media controls playback state', error: e);
    }
    await _pushPlezyNotification();
  }

  /// Enable or disable transport controls in the OS media session.
  ///
  /// next/previous/seek reflect the content (adjacent episodes, playlist
  /// position, seekability). stop/skip/speed reflect what the active surface
  /// actually handles — the platform sides enable several commands by
  /// default, so anything the caller leaves disabled here is explicitly
  /// un-advertised rather than shown as a dead button.
  ///
  /// [canSkip] is never honored on iOS/macOS: enabling the
  /// MPRemoteCommandCenter skip commands displaces the next/previous track
  /// buttons on the lock screen / Control Center, and next/previous are the
  /// primary transport there. Android's fast-forward/rewind actions are
  /// independent of next/previous, so skip is safe to advertise.
  Future<void> setControlsEnabled({
    bool canPlayPause = false,
    bool canGoNext = false,
    bool canGoPrevious = false,
    bool canSeek = false,
    bool canStop = false,
    bool canSkip = false,
    bool canSetSpeed = false,
  }) async {
    if (_updatesSuspended) return;

    final effectiveCanSkip =
        canSkip && defaultTargetPlatform != TargetPlatform.iOS && defaultTargetPlatform != TargetPlatform.macOS;

    try {
      final controlsToEnable = <MediaControl>[];
      final controlsToDisable = <MediaControl>[];

      if (canPlayPause != _lastCanPlayPause) {
        (canPlayPause ? controlsToEnable : controlsToDisable)
          ..add(MediaControl.play)
          ..add(MediaControl.pause);
      }
      if (canGoPrevious != _lastCanGoPrevious) {
        (canGoPrevious ? controlsToEnable : controlsToDisable).add(MediaControl.previous);
      }
      if (canGoNext != _lastCanGoNext) {
        (canGoNext ? controlsToEnable : controlsToDisable).add(MediaControl.next);
      }
      if (canSeek != _lastCanSeek) {
        (canSeek ? controlsToEnable : controlsToDisable).add(MediaControl.seek);
      }
      if (canStop != _lastCanStop) {
        (canStop ? controlsToEnable : controlsToDisable).add(MediaControl.stop);
      }
      if (effectiveCanSkip != _lastCanSkip) {
        (effectiveCanSkip ? controlsToEnable : controlsToDisable)
          ..add(MediaControl.skipForward)
          ..add(MediaControl.skipBackward);
      }
      if (canSetSpeed != _lastCanSetSpeed) {
        (canSetSpeed ? controlsToEnable : controlsToDisable).add(MediaControl.changeSpeed);
      }

      if (controlsToEnable.isEmpty && controlsToDisable.isEmpty) return;

      if (controlsToEnable.isNotEmpty) {
        await OsMediaControls.enableControls(controlsToEnable);
      }
      if (controlsToDisable.isNotEmpty) {
        await OsMediaControls.disableControls(controlsToDisable);
      }

      _lastCanPlayPause = canPlayPause;
      _lastCanGoNext = canGoNext;
      _lastCanGoPrevious = canGoPrevious;
      _lastCanSeek = canSeek;
      _lastCanStop = canStop;
      _lastCanSkip = effectiveCanSkip;
      _lastCanSetSpeed = canSetSpeed;
      appLogger.d(
        'Media controls updated - Play/Pause: $canPlayPause, Previous: $canGoPrevious, '
        'Next: $canGoNext, Seek: $canSeek, Stop: $canStop, Skip: $effectiveCanSkip, '
        'Speed: $canSetSpeed',
      );
      await _pushPlezyNotification();
    } catch (e) {
      appLogger.w('Failed to set media controls enabled state', error: e);
    }
  }

  /// Enable/disable Android background playback: while enabled, the plugin
  /// keeps audio alive with a `mediaPlayback` foreground service and shows a
  /// MediaStyle notification for the session. No-op on other platforms.
  Future<void> setBackgroundMode(bool enabled) async {
    try {
      await OsMediaControls.setBackgroundMode(enabled);
      appLogger.d('Media controls background mode: $enabled');
    } catch (e) {
      appLogger.w('Failed to set media controls background mode', error: e);
    }
  }

  /// Clear all media controls
  ///
  /// Should be called when playback stops or screen is disposed.
  Future<void> clear() async {
    try {
      await OsMediaControls.clear();
      _throttledUpdate.cancel();
      _lastCanPlayPause = null;
      _lastCanGoNext = null;
      _lastCanGoPrevious = null;
      _lastCanSeek = null;
      _lastCanStop = null;
      _lastCanSkip = null;
      _lastCanSetSpeed = null;
      _cachedTitle = null;
      _cachedArtist = null;
      _cachedAlbum = null;
      _cachedArtwork = null;
      _cachedDuration = null;
      _cachedIsPlaying = false;
      _cachedPosition = Duration.zero;
      _cachedSpeed = 1.0;
      await PlezyMediaNotification.instance.clear();
      appLogger.d('Media controls cleared');
    } catch (e) {
      appLogger.w('Failed to clear media controls', error: e);
    }
  }

  void suspendUpdates() {
    if (_updatesSuspended) return;
    _updatesSuspended = true;
    _throttledUpdate.cancel();
    appLogger.d('Media controls updates suspended');
  }

  void resumeUpdates() {
    if (!_updatesSuspended) return;
    _updatesSuspended = false;
    appLogger.d('Media controls updates resumed');
  }

  /// Dispose resources
  void dispose() {
    _throttledUpdate.cancel();
    unawaited(_osControlsSub?.cancel());
    unawaited(_plezyNotificationSub?.cancel());
    _osControlsSub = null;
    _plezyNotificationSub = null;
    unawaited(_mergedControlEvents.close());
  }

  /// Build artist string from metadata
  ///
  /// For music tracks: the performing artist
  /// For episodes: "Show Name - Season X Episode Y"
  /// For movies: Director or studio
  /// For other content: Fallback to year or empty
  String _buildArtist(MediaItem metadata) {
    if (metadata.kind == MediaKind.track) {
      // Performing artist with album-artist fallback (compilations store the
      // track's own artist separately).
      return metadata.trackArtistTitle ?? '';
    }
    if (metadata.isEpisode) {
      final parts = <String>[];

      if (metadata.grandparentTitle != null) {
        parts.add(metadata.grandparentTitle!);
      }

      if (metadata.parentIndex != null && metadata.index != null) {
        parts.add('S${metadata.parentIndex} E${metadata.index}');
      } else if (metadata.parentTitle != null) {
        parts.add(metadata.parentTitle!);
      }

      return parts.join(' • ');
    } else if (metadata.isMovie) {
      if (metadata.year != null) {
        return metadata.year.toString();
      }
    }

    return '';
  }
}

/// Parameters for playback state update (used with throttle)
class _PlaybackStateParams {
  final bool isPlaying;
  final Duration position;
  final double speed;

  const _PlaybackStateParams({required this.isPlaying, required this.position, required this.speed});
}
