import 'package:audioplayers/audioplayers.dart';

import '../media/media_backend.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../utils/app_logger.dart';
import '../utils/plex_url_helper.dart';
import 'plex_client.dart';

/// Plays the theme music attached to a Plex show on detail screens.
///
/// Backend-scoped: Plex is the only backend that exposes a per-show theme
/// asset, so this service is a no-op for Jellyfin items. Theme paths come
/// from the per-item `raw` map populated by `PlexMappers.mediaItem` —
/// `theme` for the show itself, `grandparentTheme` for items lower in the
/// hierarchy (seasons, episodes) that should still inherit the show's
/// theme.
///
/// The service serializes its own play/stop operations through a
/// future-chain so rapid lifecycle ticks (route push/pop, app foreground
/// flips) can't race the underlying [AudioPlayer].
class ThemeMusicService {
  ThemeMusicService._();

  static final ThemeMusicService instance = ThemeMusicService._();

  final AudioPlayer _player = AudioPlayer()..setReleaseMode(ReleaseMode.release);

  String? _activeOwnerId;
  String? _activeUrl;
  double? _activeVolume;
  Future<void> _operationChain = Future.value();
  int _operationSerial = 0;

  Future<void> playForMetadata({
    required String ownerId,
    required MediaItem metadata,
    required PlexClient client,
    required double volume,
  }) {
    return _enqueueOperation(
      () => _playForMetadataInternal(ownerId: ownerId, metadata: metadata, client: client, volume: volume),
    );
  }

  Future<void> _playForMetadataInternal({
    required String ownerId,
    required MediaItem metadata,
    required PlexClient client,
    required double volume,
  }) async {
    final themePath = _themePathFor(metadata);
    if (volume <= 0 || themePath == null || themePath.isEmpty) {
      appLogger.d(
        'Theme music skipped',
        error: {
          'ownerId': ownerId,
          'id': metadata.id,
          'kind': metadata.kind.name,
          'title': metadata.title,
          'hasThemePath': themePath?.isNotEmpty == true,
          'volume': volume,
        },
      );
      await _stopInternal(ownerId: ownerId, reason: 'missing_theme_or_zero_volume');
      return;
    }

    final url = themePath.toPlexUrl(client.config.baseUrl, client.config.token);
    if (_activeOwnerId == ownerId && _activeUrl == url && _player.state == PlayerState.playing) {
      if (_activeVolume != volume) {
        await _player.setVolume(volume);
        _activeVolume = volume;
      }
      return;
    }

    try {
      final shouldReplaceSource = _activeUrl != url;
      _activeOwnerId = ownerId;
      _activeUrl = url;
      _activeVolume = volume;
      if (shouldReplaceSource) {
        await _player.stop();
        await _player.setSource(UrlSource(url));
      }
      await _player.setVolume(volume);
      await _player.resume();
    } catch (e) {
      appLogger.w('Failed to play theme music', error: e);
      await _stopInternal(ownerId: ownerId, reason: 'play_failed');
    }
  }

  Future<void> stop({String? ownerId}) {
    return _enqueueOperation(() => _stopInternal(ownerId: ownerId, reason: 'explicit_stop'));
  }

  Future<void> _stopInternal({String? ownerId, required String reason}) async {
    if (ownerId != null && ownerId != _activeOwnerId) return;

    try {
      await _player.stop();
    } catch (e) {
      appLogger.w('Failed to stop theme music', error: e);
    } finally {
      if (ownerId == null || ownerId == _activeOwnerId) {
        _activeOwnerId = null;
        _activeUrl = null;
        _activeVolume = null;
      }
    }
  }

  /// Resolve the theme path. Plex shows expose `theme`; items below a show
  /// (season, episode) inherit `grandparentTheme`. Non-Plex items and items
  /// outside the show hierarchy (movies, music) return null.
  String? _themePathFor(MediaItem metadata) {
    if (metadata.backend != MediaBackend.plex) return null;
    final raw = metadata.raw;
    if (raw == null) return null;

    if (metadata.kind == MediaKind.show) {
      final theme = raw['theme'];
      return theme is String ? theme : null;
    }

    if (metadata.kind == MediaKind.season || metadata.kind == MediaKind.episode) {
      final grandparent = raw['grandparentTheme'];
      if (grandparent is String && grandparent.isNotEmpty) return grandparent;
      final theme = raw['theme'];
      return theme is String ? theme : null;
    }

    return null;
  }

  Future<void> _enqueueOperation(Future<void> Function() operation) {
    final operationId = ++_operationSerial;
    final next = _operationChain.then(
      (_) async {
        await operation();
      },
      onError: (_) async {
        await operation();
      },
    );

    _operationChain = next.catchError((Object e) {
      appLogger.w('Theme music operation failed', error: {'operationId': operationId, 'error': e});
    });

    return next;
  }
}
