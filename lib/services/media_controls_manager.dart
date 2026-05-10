import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:os_media_controls/os_media_controls.dart';
import 'package:rate_limiter/rate_limiter.dart';

import '../media/media_server_client.dart';
import '../media/media_item.dart';
import '../media/media_item_types.dart';
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
  /// Stream of control events from OS media controls. On Android, merges
  /// events from the in-tree `PlezyMediaNotification` plugin (lock-screen /
  /// launcher button taps) with those from `os_media_controls` so callers
  /// pattern-match on a single stream.
  Stream<dynamic> get controlEvents => _mergedControlEvents.stream;

  /// Throttled playback state update (1 second interval, leading + trailing)
  late final Throttle _throttledUpdate;

  /// Cached control enabled state to avoid redundant platform calls
  bool? _lastCanGoNext;
  bool? _lastCanGoPrevious;
  bool? _lastCanSeek;
  bool _updatesSuspended = false;

  /// Cached metadata snapshot — needed to push the home-screen notification
  /// (which requires title/artist/artwork together) on every state change.
  String? _cachedTitle;
  String? _cachedArtist;
  Uint8List? _cachedArtwork;
  Duration? _cachedDuration;
  bool _cachedIsPlaying = false;
  Duration _cachedPosition = Duration.zero;
  double _cachedSpeed = 1.0;

  final StreamController<dynamic> _mergedControlEvents = StreamController<dynamic>.broadcast();
  StreamSubscription<dynamic>? _osControlsSub;
  StreamSubscription<PlezyMediaNotificationEvent>? _plezyNotifSub;

  MediaControlsManager() {
    _throttledUpdate = throttle(
      _doUpdatePlaybackState,
      const Duration(seconds: 1),
      leading: true,
      trailing: true, // Send final position at end of throttle window
    );

    _osControlsSub = OsMediaControls.controlEvents.listen(_mergedControlEvents.add);
    if (Platform.isAndroid) {
      PlezyMediaNotification.instance.start();
      _plezyNotifSub = PlezyMediaNotification.instance.events.listen((event) {
        _mergedControlEvents.add(_translatePlezyEvent(event));
        // Native PiP-X path emits "stop" alongside cancelling the OS
        // notification + releasing the session. Wipe our Dart-side cache
        // too so a stale `_pushPlezyNotification` from a queued throttle
        // tick can't recreate the tile a moment later.
        if (event is PlezyMediaStop) {
          unawaited(clear());
        }
      });
    }
  }

  /// Translate a `PlezyMediaNotification` event into the matching
  /// `os_media_controls` event class so existing per-player listeners that
  /// pattern-match on `PlayEvent`/`PauseEvent`/etc. handle it transparently.
  dynamic _translatePlezyEvent(PlezyMediaNotificationEvent event) {
    return switch (event) {
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
  }

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

        // Android's MediaSession only renders a Bitmap on the lock screen —
        // it ignores artwork URLs. Pre-fetch the bytes via the authenticated
        // server client so the lock-screen widget shows the show poster
        // instead of a generic music icon. Other platforms read the URL.
        if (Platform.isAndroid) {
          try {
            artworkBytes = await client.fetchThumbnailBytes(metadata.thumbPath!, width: 1024, height: 1024);
            if (artworkBytes == null) {
              appLogger.d('Artwork bytes unavailable for media controls (null)');
            }
          } catch (e) {
            appLogger.w('Failed to fetch artwork bytes for media controls', error: e);
          }
        }
      }

      final title = metadata.title ?? '';
      final artist = _buildArtist(metadata);

      await OsMediaControls.setMetadata(
        MediaMetadata(
          title: title,
          artist: artist,
          artwork: artworkBytes,
          artworkUrl: artworkUrl,
          duration: duration,
        ),
      );

      _cachedTitle = title;
      _cachedArtist = artist;
      _cachedArtwork = artworkBytes;
      _cachedDuration = duration;
      await _pushPlezyNotification();

      appLogger.d('Updated media controls metadata: ${metadata.title}');
    } catch (e) {
      appLogger.w('Failed to update media controls metadata', error: e);
    }
  }

  /// Push the current cached snapshot to the in-tree home-screen notification
  /// plugin. Skipped on non-Android and when no metadata has been seen yet.
  Future<void> _pushPlezyNotification() async {
    if (!Platform.isAndroid) return;
    final title = _cachedTitle;
    if (title == null) return;
    await PlezyMediaNotification.instance.update(
      title: title,
      artist: _cachedArtist,
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

  /// Enable or disable next/previous track controls
  ///
  /// This should be called based on content type and playback mode.
  /// For example:
  /// - Episodes: Enable both if there are adjacent episodes
  /// - Playlist items: Enable based on playlist position
  /// - Movies: Usually disabled
  Future<void> setControlsEnabled({bool canGoNext = false, bool canGoPrevious = false, bool canSeek = false}) async {
    if (_updatesSuspended) return;

    try {
      final controlsToEnable = <MediaControl>[];
      final controlsToDisable = <MediaControl>[];

      if (canGoPrevious != _lastCanGoPrevious) {
        (canGoPrevious ? controlsToEnable : controlsToDisable).add(MediaControl.previous);
      }
      if (canGoNext != _lastCanGoNext) {
        (canGoNext ? controlsToEnable : controlsToDisable).add(MediaControl.next);
      }
      if (canSeek != _lastCanSeek) {
        (canSeek ? controlsToEnable : controlsToDisable).add(MediaControl.seek);
      }

      if (controlsToEnable.isEmpty && controlsToDisable.isEmpty) return;

      if (controlsToEnable.isNotEmpty) {
        await OsMediaControls.enableControls(controlsToEnable);
      }
      if (controlsToDisable.isNotEmpty) {
        await OsMediaControls.disableControls(controlsToDisable);
      }

      _lastCanGoNext = canGoNext;
      _lastCanGoPrevious = canGoPrevious;
      _lastCanSeek = canSeek;
      appLogger.d('Media controls updated - Previous: $canGoPrevious, Next: $canGoNext, Seek: $canSeek');
    } catch (e) {
      appLogger.w('Failed to set media controls enabled state', error: e);
    }
    await _pushPlezyNotification();
  }

  /// Clear all media controls
  ///
  /// Should be called when playback stops or screen is disposed.
  Future<void> clear() async {
    try {
      await OsMediaControls.clear();
      _throttledUpdate.cancel();
      _lastCanGoNext = null;
      _lastCanGoPrevious = null;
      _lastCanSeek = null;
      _cachedTitle = null;
      _cachedArtist = null;
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
    unawaited(_plezyNotifSub?.cancel());
    _osControlsSub = null;
    _plezyNotifSub = null;
    unawaited(_mergedControlEvents.close());
  }

  /// Build artist string from metadata
  ///
  /// For episodes: "Show Name - Season X Episode Y"
  /// For movies: Director or studio
  /// For other content: Fallback to year or empty
  String _buildArtist(MediaItem metadata) {
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
