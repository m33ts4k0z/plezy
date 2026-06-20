import 'package:flutter/services.dart';

import '../../models.dart';
import '../player_base.dart';

/// Android implementation of [Player] using ExoPlayer.
/// Provides hardware-accelerated playback with ASS subtitle support via libass-android.
class PlayerAndroid extends PlayerBase {
  static const _methodChannel = MethodChannel('com.plezy/exo_player');
  static const _eventChannel = EventChannel('com.plezy/exo_player/events');

  int? _bufferSizeBytes;
  bool _tunnelingEnabled = true;
  Future<void>? _initFuture;
  String _dvConversionMode = 'auto';
  bool _audioNormalizationEnabled = false;
  bool _audioPassthroughEnabled = false;

  static const String _passthroughCodecs = 'ac3,eac3,dts,dts-hd,truehd';

  /// The native plugin switched from ExoPlayer to its mpv fallback for this
  /// session. Sticky for the instance lifetime, mirroring the native flag
  /// (which resets only on initialize/dispose).
  bool _usingMpvFallback = false;

  /// Stored subtitle track ID when subtitles are hidden via sub-visibility.
  String? _hiddenSubtitleTrackId;

  @override
  MethodChannel get methodChannel => _methodChannel;

  @override
  EventChannel get eventChannel => _eventChannel;

  @override
  String get logPrefix => 'ExoPlayer';

  @override
  String get playerType => 'exoplayer';

  @override
  bool get supportsSecondarySubtitles => false;

  // ExoPlayer attaches external subtitles to the MediaItem before prepare;
  // the Android mpv fallback mirrors PlayerNative by passing sub-files through
  // loadfile options.
  @override
  bool get attachesExternalSubtitlesAtOpen => true;

  // The fallback runs mpv over MediaCodec — the same display-switch decoder
  // constraint as PlayerNative on Android. The whole startup-gate chain
  // (setVideoFrameRate, playback-restart, seek/drop-buffers refresh,
  // open-paused) already routes per-core natively.
  @override
  bool get needsDecoderRefreshAfterDisplaySwitch => _usingMpvFallback;

  @override
  bool get detectsFpsAfterRender => true;

  @override
  bool get providesNativeStats => true;

  @override
  bool get audioPassthroughActive => _audioPassthroughEnabled;

  @override
  void handlePlayerEvent(String name, Map? data) {
    // Handle Android-specific events
    if (name == 'backend-switched') {
      // Native player switched from ExoPlayer to MPV due to unsupported format.
      // Clear stale ExoPlayer tracks so applyTrackSelectionWhenReady waits for
      // mpv's track-list instead of immediately applying with ExoPlayer IDs.
      final wasUsingMpvFallback = _usingMpvFallback;
      _usingMpvFallback = true;
      if (!wasUsingMpvFallback) {
        clearTracks();
      }
      backendSwitchedController.add(null);
      return;
    }

    // Delegate to base class for common events
    super.handlePlayerEvent(name, data);
  }

  // ============================================
  // Initialization
  // ============================================

  Future<void> _ensureInitialized() async {
    if (initialized) return;
    return _initFuture ??= _doInitialize();
  }

  Future<void> _doInitialize() async {
    try {
      final result = await invoke<bool>('initialize', {
        'bufferSizeBytes': _bufferSizeBytes,
        'tunnelingEnabled': _tunnelingEnabled,
        'dvConversionMode': _dvConversionMode,
        'audioPassthroughEnabled': _audioPassthroughEnabled,
      });
      if (result != true) {
        throw Exception('Failed to initialize ExoPlayer');
      }

      // Register property observers before flipping `initialized` so partial
      // failures don't leave us in a half-initialized state that the memoized
      // future would falsely treat as ready.
      await observeCoreProperties(trackListFormat: 'string');
      await observeProperty('demuxer-cache-time', 'double');

      initialized = true;
    } catch (e) {
      _initFuture = null;
      errorController.add(PlayerError('Initialization failed: $e'));
      rethrow;
    }
  }

  // ============================================
  // Playback Control
  // ============================================

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration timelineOffset = Duration.zero,
    Duration? timelineDuration,
  }) async {
    if (disposed) return;
    await _ensureInitialized();
    final startPosition = media.start ?? Duration.zero;
    final hasStartPosition = media.start != null && startPosition > Duration.zero;
    // ExoPlayer reports Plex copyts transcodes in source-time coordinates,
    // unlike mpv which rebases them to zero. Do not add the timeline offset
    // again on Android ExoPlayer or seeks/progress jump to roughly 2x (#1221).
    configureTimeline(offset: Duration.zero, duration: timelineDuration);
    clearTracks();
    setExternalSubtitleMetadata(externalSubtitles);
    setSeekable(false);

    // ExoPlayer handles HLS seeking via the manifest. Plex now serves the
    // transcode from source 0 (full manifest), so ExoPlayer can seek to any
    // position — including before the user's resume point, fixing backward
    // seek and resume-after-quality-change. The wrapper's "server-managed
    // start" mode (which told ExoPlayer to start at 0 and adjusted reported
    // time-pos by the offset) is no longer needed: with ExoPlayer doing the
    // seek locally via setMediaItem(item, startPositionMs), time-pos already
    // reflects source-time and sidecar SRT timestamps line up naturally.

    // Show the video layer
    await setVisible(true);

    await invoke('open', {
      'uri': media.uri,
      'headers': media.headers,
      'startPositionMs': startPosition.inMilliseconds,
      'hasStartPosition': hasStartPosition,
      'autoPlay': play,
      'isLive': isLive,
      if (externalSubtitles != null && externalSubtitles.isNotEmpty)
        'externalSubtitles': externalSubtitles
            .where((s) => s.uri != null)
            .map(
              (s) => {
                'uri': s.uri,
                'title': s.title,
                'language': s.language,
                'codec': s.codec,
                'isDefault': s.isDefault,
                'isForced': s.isForced,
              },
            )
            .toList(),
    });
    resetPlaybackProgress(media.start ?? timelineOffset);
  }

  @override
  Future<void> play() async {
    await invoke('play');
  }

  @override
  Future<void> pause() async {
    await invoke('pause');
  }

  @override
  Future<void> stop() async {
    await invoke('stop');
    setSeekable(false);
    await setVisible(false);
  }

  @override
  Future<void> seek(Duration position) async {
    final sourcePosition = sourceSeekPosition(position);
    await runSeek(position, () => invoke('seek', {'positionMs': sourcePosition.inMilliseconds}));
  }

  // ============================================
  // Track Selection
  // ============================================

  @override
  Future<void> selectAudioTrack(AudioTrack track) async {
    await invoke('selectAudioTrack', {'trackId': track.id});
  }

  @override
  Future<void> selectSubtitleTrack(SubtitleTrack track) async {
    await invoke('selectSubtitleTrack', {'trackId': track.id});
  }

  @override
  Future<void> addSubtitleTrack({required String uri, String? title, String? language, bool select = false}) async {
    await invoke('addSubtitleTrack', {'uri': uri, 'title': title, 'language': language, 'select': select});
  }

  // ============================================
  // Volume and Rate
  // ============================================

  @override
  Future<void> setVolume(double volume) async {
    await invoke('setVolume', {'volume': volume});
    if (!disposed) setVolumeState(volume);
  }

  @override
  Future<void> setRate(double rate) async {
    await invoke('setRate', {'rate': rate});
  }

  // ============================================
  // MPV Properties (Compatibility Layer)
  // ============================================

  @override
  Future<void> setProperty(String name, String value) async {
    if (disposed) return;
    // ExoPlayer doesn't use MPV properties, but we handle common ones
    switch (name) {
      case 'pause':
        if (value == 'yes') {
          await pause();
        } else {
          await play();
        }
        break;
      case 'volume':
        await setVolume(double.tryParse(value) ?? 100);
        break;
      case 'speed':
        await setRate(double.tryParse(value) ?? 1.0);
        break;
      case 'demuxer-max-bytes':
        _bufferSizeBytes = int.tryParse(value);
        break;
      case 'tunneled-playback':
        _tunnelingEnabled = value != 'no';
        break;
      case 'dv-conversion-mode':
        _dvConversionMode = value;
        if (initialized) {
          await invoke('setDvConversionMode', {'mode': value});
        }
        // If not yet initialized, the value is passed through the next
        // `_ensureInitialized()` call via the initialize() payload.
        break;
      case 'sub-visibility':
        if (value == 'no') {
          // Store current subtitle track and disable
          final current = state.track.subtitle;
          if (current != null && current.id != 'no') {
            _hiddenSubtitleTrackId = current.id;
            await selectSubtitleTrack(SubtitleTrack.off);
          }
        } else {
          // Restore previously hidden subtitle track
          final storedId = _hiddenSubtitleTrackId;
          if (storedId != null) {
            _hiddenSubtitleTrackId = null;
            final track = state.tracks.subtitle.cast<SubtitleTrack?>().firstWhere(
              (t) => t?.id == storedId,
              orElse: () => null,
            );
            if (track != null) {
              await selectSubtitleTrack(track);
            }
          }
        }
        break;
      default:
        // Forward unknown properties to Kotlin for MPV fallback
        await invoke('setMpvProperty', {'name': name, 'value': value});
    }
  }

  @override
  Future<void> setAudioNormalization(bool enabled) async {
    if (disposed) return;
    _audioNormalizationEnabled = enabled;
    final initFuture = _initFuture;
    if (initialized) {
      await invoke('setAudioNormalization', {'enabled': enabled});
    } else if (initFuture != null) {
      await initFuture;
      if (!disposed && initialized && _audioNormalizationEnabled == enabled) {
        await invoke('setAudioNormalization', {'enabled': enabled});
      }
    }
    // Keep the mpv af property flowing through setMpvProperty so the plugin's
    // pendingMpvProperties replay applies loudnorm if exo falls back to mpv.
    await super.setAudioNormalization(enabled);
  }

  @override
  Future<void> setAudioPassthrough(bool enabled) async {
    if (disposed) return;
    _audioPassthroughEnabled = enabled;
    final initFuture = _initFuture;
    if (initialized) {
      await invoke('setAudioPassthrough', {'enabled': enabled});
    } else if (initFuture != null) {
      await initFuture;
      if (!disposed && initialized && _audioPassthroughEnabled == enabled) {
        await invoke('setAudioPassthrough', {'enabled': enabled});
      }
    }
    await setProperty('audio-spdif', enabled ? _passthroughCodecs : '');
  }

  @override
  Future<String?> getProperty(String name) async {
    if (disposed) return null;
    // Return state-based values for common properties
    switch (name) {
      case 'pause':
        return state.playing ? 'no' : 'yes';
      case 'volume':
        return state.volume.toString();
      case 'speed':
        return state.rate.toString();
      case 'time-pos':
        return (state.position.inMilliseconds / 1000.0).toString();
      case 'duration':
        return (state.duration.inMilliseconds / 1000.0).toString();
      case 'seekable':
        return state.seekable ? 'yes' : 'no';
      // Video frame rate - query from ExoPlayer stats
      case 'container-fps':
        final fpsStats = await getStats();
        final fps = fpsStats['videoFps'];
        return fps?.toString();
      // Video dimensions - query from ExoPlayer stats
      case 'width':
      case 'dwidth':
        final stats = await getStats();
        final width = stats['videoWidth'];
        return width?.toString();
      case 'height':
      case 'dheight':
        final stats = await getStats();
        final height = stats['videoHeight'];
        return height?.toString();
      default:
        return null;
    }
  }

  @override
  Future<Map<String, dynamic>> getStats() async {
    if (disposed) return {};
    try {
      final result = await invoke<Map>('getStats');
      return Map<String, dynamic>.from(result ?? {});
    } catch (e) {
      return {};
    }
  }

  /// Get the device's large heap size in MB (Android only).
  /// Returns 0 if unavailable.
  static Future<int> getHeapSize() async {
    try {
      final result = await _methodChannel.invokeMethod<int>('getHeapSize');
      return result ?? 0;
    } catch (e) {
      return 0;
    }
  }

  @override
  Future<String> runtimePlayerType() async {
    if (disposed) return 'unknown';
    try {
      final result = await invoke<String>('getPlayerType');
      return result ?? 'unknown';
    } catch (e) {
      return 'unknown';
    }
  }

  @override
  Future<void> command(List<String> args) async {
    if (disposed) return;
    // Handle MPV commands by translating to ExoPlayer equivalents
    if (args.isEmpty) return;

    switch (args.first) {
      case 'loadfile':
        if (args.length > 1) {
          await open(Media(args[1]));
        }
        break;
      case 'seek':
        if (args.length > 1) {
          final seconds = double.tryParse(args[1]) ?? 0;
          final mode = args.length > 2 ? args[2] : 'relative';
          if (mode == 'absolute') {
            await seek(Duration(milliseconds: (seconds * 1000).toInt()));
          } else {
            final newPos = state.position + Duration(milliseconds: (seconds * 1000).toInt());
            await seek(newPos);
          }
        }
        break;
      case 'stop':
        await stop();
        break;
      case 'sub-add':
        if (args.length > 1) {
          final select = args.length > 2 && args[2] == 'select';
          await addSubtitleTrack(uri: args[1], select: select);
        }
        break;
    }
  }

  // ============================================
  // Subtitle Styling (ExoPlayer Native)
  // ============================================

  /// Apply subtitle styling to the native ExoPlayer layer.
  ///
  /// For non-ASS subtitles, applies CaptionStyleCompat (color, border, background).
  /// For ASS subtitles, applies font scale via libass setFontScale().
  @override
  Future<void> setSubtitleStyle({
    required double fontSize,
    required String textColor,
    required double borderSize,
    required String borderColor,
    required String bgColor,
    required int bgOpacity,
    int subtitlePosition = 100,
    bool bold = false,
    bool italic = false,
  }) async {
    if (disposed || !initialized) return;
    await invoke('setSubtitleStyle', {
      'fontSize': fontSize,
      'textColor': textColor,
      'borderSize': borderSize,
      'borderColor': borderColor,
      'bgColor': bgColor,
      'bgOpacity': bgOpacity,
      'subtitlePosition': subtitlePosition,
      'bold': bold,
      'italic': italic,
    });
  }

  /// Apply the box-fit mode to the native ExoPlayer layer.
  /// Maps to AspectRatioFrameLayout resize mode: 0=FIT, 1=ZOOM, 2=FILL.
  @override
  Future<void> setBoxFitMode(int mode) async {
    if (disposed || !initialized) return;
    await invoke('setBoxFitMode', {'mode': mode});
  }

  /// Apply custom zoom to the native ExoPlayer layer.
  @override
  Future<void> setVideoZoom(double scale) async {
    if (disposed || !initialized) return;
    await invoke('setVideoZoom', {'scale': scale});
  }

  @override
  Future<bool> setVideoFrameRate(double fps, int durationMs, {int extraDelayMs = 0}) async {
    if (disposed || !initialized) return false;
    await invoke('setVideoFrameRate', {'fps': fps, 'duration': durationMs});
    return true;
  }

  @override
  Future<void> clearVideoFrameRate() async {
    if (disposed || !initialized) return;
    await invoke('clearVideoFrameRate');
  }

  @override
  Future<void> updateFrame() async {
    if (disposed || !initialized) return;
    await invoke('updateFrame');
  }

  // ============================================
  // Audio Focus
  // ============================================

  @override
  Future<bool> requestAudioFocus() async {
    if (disposed) return false;
    await _ensureInitialized();
    return await invoke<bool>('requestAudioFocus') ?? false;
  }

  @override
  Future<void> abandonAudioFocus() async {
    if (disposed || !initialized) return;
    await invoke('abandonAudioFocus');
  }

  // ============================================
  // Log Level
  // ============================================

  @override
  Future<void> setLogLevel(String level) async {
    if (disposed) return;
    await invoke('setLogLevel', {'level': level});
  }
}
