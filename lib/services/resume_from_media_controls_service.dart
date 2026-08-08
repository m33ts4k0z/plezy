import 'dart:async';
import 'dart:io' show Platform;

import 'package:os_media_controls/os_media_controls.dart';

import '../media/media_item.dart';
import '../navigation/profile_navigation_scope.dart';
import '../utils/app_logger.dart';
import '../utils/video_player_navigation.dart';
import 'plezy_media_notification.dart';

/// Keeps the Android lock-screen / media-notification widget alive after the
/// video player is disposed, so the user can tap play to jump back into the
/// player at the saved position — like the official Plex app does.
///
/// Scope is intentionally narrow:
/// - Android only (no-op elsewhere).
/// - In-process only (state is dropped on app restart by design).
/// - The service is "armed" by [VideoPlayerScreen] right before its
///   [MediaControlsManager] is disposed; it then owns the OS media controls
///   subscription until the user taps play (resume), stop (dismiss), or a
///   new player attaches and calls [disarm].
class ResumeFromMediaControlsService {
  ResumeFromMediaControlsService._();
  static final ResumeFromMediaControlsService instance = ResumeFromMediaControlsService._();

  _PendingResume? _pending;
  StreamSubscription<dynamic>? _subscription;
  StreamSubscription<PlezyMediaNotificationEvent>? _plezyNotifSubscription;
  bool _navigating = false;

  /// True while a paused notification is being held for resume. Useful for
  /// callers that want to know whether they should suppress a redundant
  /// `OsMediaControls.clear()` (e.g. the player's own teardown).
  bool get isArmed => _pending != null;

  /// Capture the last-known playback state and keep the OS notification in
  /// the paused state. The caller MUST NOT call `OsMediaControls.clear()`
  /// after invoking this — that would defeat the whole feature.
  ///
  /// Returns `false` (and does nothing) on non-Android platforms or when the
  /// supplied state isn't suitable for resume (no metadata, zero position,
  /// live content). The caller should fall back to its normal clear path
  /// when this returns `false`.
  bool arm({required MediaItem metadata, required Duration position, required bool isOffline}) {
    if (!Platform.isAndroid) return false;
    // Skip very-early and very-late positions: < 5s isn't worth resuming, and
    // within 30s of the end the user has effectively finished — pinning a
    // "resume at credits" widget would be more annoying than useful.
    if (position < const Duration(seconds: 5)) return false;
    final durationMs = metadata.durationMs;
    if (durationMs != null && durationMs > 0) {
      final remaining = Duration(milliseconds: durationMs) - position;
      if (remaining < const Duration(seconds: 30)) return false;
    }

    _pending = _PendingResume(metadata: metadata, position: position, isOffline: isOffline);
    _attachListener();
    // Force both surfaces into the paused state. The player disposal
    // cancels its own per-instance playback-state listener before the
    // final pause/stop is reflected, so without this the lock-screen
    // widget and home-screen launcher tile can keep showing a "pause"
    // icon (= OS thinks playback is ongoing) even though the player is
    // gone.
    unawaited(
      OsMediaControls.setPlaybackState(
        MediaPlaybackState(state: PlaybackState.paused, position: position, speed: 0.0),
      ).catchError((Object e) {
        appLogger.w('ResumeFromMediaControlsService: failed to set paused state', error: e);
      }),
    );
    unawaited(
      PlezyMediaNotification.instance.setPlaybackState(
        isPlaying: false,
        position: position,
        speed: 0.0,
      ),
    );
    appLogger.d('ResumeFromMediaControlsService armed for ${metadata.title} at $position');
    return true;
  }

  /// Drop pending state and clear the OS notification. Called when:
  /// - a new [VideoPlayerScreen] attaches (it'll install its own controls);
  /// - the user explicitly stops via the notification's stop control;
  /// - the user signs out / closes the app.
  Future<void> disarm({bool clearOsControls = true}) async {
    final wasArmed = _pending != null;
    _pending = null;
    await _subscription?.cancel();
    _subscription = null;
    await _plezyNotifSubscription?.cancel();
    _plezyNotifSubscription = null;
    if (wasArmed && clearOsControls) {
      try {
        await OsMediaControls.clear();
      } catch (e) {
        appLogger.w('ResumeFromMediaControlsService: failed to clear OS controls', error: e);
      }
      try {
        await PlezyMediaNotification.instance.clear();
      } catch (e) {
        appLogger.w('ResumeFromMediaControlsService: failed to clear plezy notification', error: e);
      }
    }
  }

  void _attachListener() {
    _subscription ??= OsMediaControls.controlEvents.listen(_onEvent);
    // Also subscribe to the in-tree home-screen notification's events.
    // Niagara / launcher button taps come through this channel — they
    // don't hit os_media_controls' MediaSession at all.
    _plezyNotifSubscription ??= PlezyMediaNotification.instance.events.listen(_onPlezyEvent);
  }

  Future<void> _onPlezyEvent(PlezyMediaNotificationEvent event) async {
    final pending = _pending;
    if (pending == null) return;
    if (event is PlezyMediaPlay || event is PlezyMediaTogglePlayPause) {
      if (_navigating) return;
      _navigating = true;
      try {
        await _resume(pending);
      } finally {
        _navigating = false;
      }
    } else if (event is PlezyMediaStop) {
      await disarm();
    }
  }

  Future<void> _onEvent(dynamic event) async {
    final pending = _pending;
    if (pending == null) return;

    if (event is PlayEvent || event is TogglePlayPauseEvent) {
      if (_navigating) return;
      _navigating = true;
      try {
        await _resume(pending);
      } finally {
        _navigating = false;
      }
    } else if (event is StopEvent) {
      await disarm();
    }
    // Pause / Seek / Next / Previous: ignore. The player is gone; there's
    // nothing to seek and we don't want to silently start playback for
    // ambiguous events.
  }

  Future<void> _resume(_PendingResume pending) async {
    // Hand over to the new player. Disarm BEFORE navigating so the new
    // VideoPlayerScreen's per-instance media-control subscription is the
    // sole owner of OS events. Keep the OS notification alive (no clear)
    // — the new MediaControlsManager will refresh its metadata on init.
    final resumeMetadata = pending.metadata.copyWith(viewOffsetMs: pending.position.inMilliseconds);
    _pending = null;
    await _subscription?.cancel();
    _subscription = null;
    await _plezyNotifSubscription?.cancel();
    _plezyNotifSubscription = null;

    // Playback providers and the content navigator are profile-scoped. The
    // app-wide root navigator sits above that scope, so pushing from its
    // context builds a player that cannot resolve PlaybackStateProvider.
    // Use the active profile navigator's overlay context: it is beneath the
    // providers and Navigator.of(context) resolves to that same navigator.
    final context = profileNavigationRegistry.navigationContext;
    if (context == null || !context.mounted) {
      appLogger.w('ResumeFromMediaControlsService: no profile navigator context, dropping resume');
      return;
    }

    appLogger.d('ResumeFromMediaControlsService: resuming ${resumeMetadata.title} at ${pending.position}');
    try {
      await navigateToVideoPlayer(context, metadata: resumeMetadata, isOffline: pending.isOffline);
    } catch (e, st) {
      appLogger.w('ResumeFromMediaControlsService: navigation failed', error: e, stackTrace: st);
      // Navigation failed — drop the stale notification rather than leave a
      // dead widget that can't be resumed.
      try {
        await OsMediaControls.clear();
      } catch (_) {}
      try {
        await PlezyMediaNotification.instance.clear();
      } catch (_) {}
    }
  }
}

class _PendingResume {
  final MediaItem metadata;
  final Duration position;
  final bool isOffline;

  const _PendingResume({required this.metadata, required this.position, required this.isOffline});
}
