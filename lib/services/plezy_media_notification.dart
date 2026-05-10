import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../utils/app_logger.dart';

/// Bridge to the in-tree Android plugin that posts a `MediaStyle`
/// `Notification` linked to a `MediaSessionCompat`.
///
/// `os_media_controls` only manages a `MediaSessionCompat`, which OnePlus
/// SystemUI / Pixel SystemUI / lock-screen widgets read directly. Third-party
/// launchers (Niagara, KISS, Action Launcher) only see media via
/// `NotificationListenerService`, so they need an actual posted notification.
/// This service emits one alongside the existing session so plezy shows up
/// on those launchers' home-screen media tiles.
///
/// Android-only — every method is a no-op on other platforms.
class PlezyMediaNotification {
  PlezyMediaNotification._();
  static final PlezyMediaNotification instance = PlezyMediaNotification._();

  static const _methodChannel = MethodChannel('com.plezy/media_notification');
  static const _eventChannel = EventChannel('com.plezy/media_notification/events');

  // ignore: cancel_subscriptions
  StreamSubscription<dynamic>? _eventSub;
  final _eventController = StreamController<PlezyMediaNotificationEvent>.broadcast();

  /// Stream of control events from the launcher / lock-screen notification.
  Stream<PlezyMediaNotificationEvent> get events => _eventController.stream;

  /// Begin listening to native control events. Idempotent.
  void start() {
    if (!Platform.isAndroid) return;
    _eventSub ??= _eventChannel.receiveBroadcastStream().listen(
      (raw) {
        if (raw is! Map) return;
        final type = raw['type'] as String?;
        if (type == null) return;
        final event = PlezyMediaNotificationEvent._fromType(type, raw);
        if (event != null) _eventController.add(event);
      },
      onError: (Object e, StackTrace st) {
        appLogger.w('PlezyMediaNotification event stream error', error: e, stackTrace: st);
      },
    );
  }

  /// Push the current playback snapshot to the notification + session.
  /// On non-Android this is a no-op.
  Future<void> update({
    required String title,
    String? artist,
    Uint8List? artwork,
    required bool isPlaying,
    required Duration position,
    Duration? duration,
    double speed = 1.0,
    bool canGoNext = false,
    bool canGoPrevious = false,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _methodChannel.invokeMethod('update', {
        'title': title,
        'artist': artist,
        'artwork': artwork,
        'isPlaying': isPlaying,
        'positionMs': position.inMilliseconds,
        'durationMs': duration?.inMilliseconds ?? 0,
        'speed': speed,
        'canGoNext': canGoNext,
        'canGoPrevious': canGoPrevious,
      });
    } on PlatformException catch (e) {
      appLogger.w('PlezyMediaNotification.update failed', error: e);
    }
  }

  /// Update only playback state, reusing the last metadata + artwork. Used
  /// by the resume coordinator to flip to "paused" without re-fetching the
  /// poster bytes. No-op if [update] hasn't been called yet.
  Future<void> setPlaybackState({required bool isPlaying, required Duration position, double speed = 1.0}) async {
    if (!Platform.isAndroid) return;
    try {
      await _methodChannel.invokeMethod('setPlaybackState', {
        'isPlaying': isPlaying,
        'positionMs': position.inMilliseconds,
        'speed': speed,
      });
    } on PlatformException catch (e) {
      appLogger.w('PlezyMediaNotification.setPlaybackState failed', error: e);
    }
  }

  /// Cancel the notification and release the session.
  Future<void> clear() async {
    if (!Platform.isAndroid) return;
    try {
      await _methodChannel.invokeMethod('clear');
    } on PlatformException catch (e) {
      appLogger.w('PlezyMediaNotification.clear failed', error: e);
    }
  }
}

/// Discriminated event type for control taps from the home-screen notification.
sealed class PlezyMediaNotificationEvent {
  const PlezyMediaNotificationEvent();

  static PlezyMediaNotificationEvent? _fromType(String type, Map<dynamic, dynamic> raw) {
    switch (type) {
      case 'play':
        return const PlezyMediaPlay();
      case 'pause':
        return const PlezyMediaPause();
      case 'togglePlayPause':
        return const PlezyMediaTogglePlayPause();
      case 'next':
        return const PlezyMediaNext();
      case 'previous':
        return const PlezyMediaPrevious();
      case 'stop':
        return const PlezyMediaStop();
      case 'seek':
        final ms = (raw['positionMs'] as num?)?.toInt() ?? 0;
        return PlezyMediaSeek(Duration(milliseconds: ms));
      case 'fastForward':
        return const PlezyMediaFastForward();
      case 'rewind':
        return const PlezyMediaRewind();
    }
    return null;
  }
}

class PlezyMediaPlay extends PlezyMediaNotificationEvent {
  const PlezyMediaPlay();
}

class PlezyMediaPause extends PlezyMediaNotificationEvent {
  const PlezyMediaPause();
}

class PlezyMediaTogglePlayPause extends PlezyMediaNotificationEvent {
  const PlezyMediaTogglePlayPause();
}

class PlezyMediaNext extends PlezyMediaNotificationEvent {
  const PlezyMediaNext();
}

class PlezyMediaPrevious extends PlezyMediaNotificationEvent {
  const PlezyMediaPrevious();
}

class PlezyMediaStop extends PlezyMediaNotificationEvent {
  const PlezyMediaStop();
}

class PlezyMediaSeek extends PlezyMediaNotificationEvent {
  final Duration position;
  const PlezyMediaSeek(this.position);
}

class PlezyMediaFastForward extends PlezyMediaNotificationEvent {
  const PlezyMediaFastForward();
}

class PlezyMediaRewind extends PlezyMediaNotificationEvent {
  const PlezyMediaRewind();
}
