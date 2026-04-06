import 'package:audioplayers/audioplayers.dart';

import '../models/plex_metadata.dart';
import '../services/plex_client.dart';
import '../utils/app_logger.dart';
import '../utils/plex_url_helper.dart';

class ThemeMusicService {
  ThemeMusicService._();

  static final ThemeMusicService instance = ThemeMusicService._();

  final AudioPlayer _player = AudioPlayer()..setReleaseMode(ReleaseMode.loop);

  String? _activeOwnerId;
  String? _activeUrl;
  double? _activeVolume;
  Future<void> _operationChain = Future.value();
  int _operationSerial = 0;

  Future<void> playForMetadata({
    required String ownerId,
    required PlexMetadata metadata,
    required PlexClient client,
    required double volume,
  }) {
    return _enqueueOperation(() => _playForMetadataInternal(
          ownerId: ownerId,
          metadata: metadata,
          client: client,
          volume: volume,
        ));
  }

  Future<void> _playForMetadataInternal({
    required String ownerId,
    required PlexMetadata metadata,
    required PlexClient client,
    required double volume,
  }) async {
    final themePath = _themePathFor(metadata);
    if (volume <= 0 || themePath == null || themePath.isEmpty) {
      appLogger.d(
        'Theme music skipped',
        error: {
          'ownerId': ownerId,
          'ratingKey': metadata.ratingKey,
          'type': metadata.type,
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
      appLogger.d(
        'Theme music already playing',
        error: {'ownerId': ownerId, 'ratingKey': metadata.ratingKey, 'title': metadata.title, 'volume': volume},
      );
      return;
    }

    try {
      final shouldReplaceSource = _activeUrl != url;
      appLogger.i(
        'Starting theme music',
        error: {
          'ownerId': ownerId,
          'ratingKey': metadata.ratingKey,
          'title': metadata.title,
          'themePath': themePath,
          'reusingSource': !shouldReplaceSource,
          'volume': volume,
        },
      );
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
      appLogger.d(
        'Stopping theme music',
        error: {'ownerId': ownerId, 'activeOwnerId': _activeOwnerId, 'reason': reason},
      );
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

  String? _themePathFor(PlexMetadata metadata) {
    if (metadata.mediaType == PlexMediaType.show) return metadata.theme;
    if (metadata.mediaType.isShowRelated) return metadata.grandparentTheme ?? metadata.theme;
    return null;
  }

  Future<void> _enqueueOperation(Future<void> Function() operation) {
    final operationId = ++_operationSerial;
    final next = _operationChain.then((_) async {
      appLogger.d('Running theme music operation', error: {'operationId': operationId});
      await operation();
    }, onError: (_) async {
      appLogger.d('Recovering theme music operation chain', error: {'operationId': operationId});
      await operation();
    });

    _operationChain = next.catchError((e) {
      appLogger.w('Theme music operation failed', error: {'operationId': operationId, 'error': e});
    });

    return next;
  }
}
