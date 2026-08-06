part of '../../video_player_screen.dart';

extension _VideoPlayerSeekingMethods on VideoPlayerScreenState {
  Future<void> _seekPlayback(Duration position) async {
    final currentPlayer = player;
    if (!mounted || currentPlayer == null) return;

    final target = clampSeekPosition(currentPlayer, position);
    // Parked on a dead stream (#1520): a native seek would land inside the
    // drained cache — rebuild the stream at the target instead.
    if (_spuriousEofRecoveryParked && !widget.isLive && _playbackTransition == _PlaybackTransition.idle) {
      await _retrySpuriousEofRecovery(reason: 'seek', resumePosition: target);
      return;
    }

    if (_plexTranscodeSeekAction(currentPlayer, target) == PlexTranscodeSeekAction.restartTranscode) {
      await _queuePlexTranscodeRestart(target);
      return;
    }
    await currentPlayer.seek(target);
  }

  bool get _usesPlexVodTranscodeSeekPolicy {
    return _isTranscoding &&
        !widget.isLive &&
        !_isOfflinePlayback &&
        _currentMetadata.backend == MediaBackend.plex &&
        !_selectedQualityPreset.isOriginal;
  }

  PlexTranscodeSeekAction _plexTranscodeSeekAction(Player currentPlayer, Duration target) {
    if (!_usesPlexVodTranscodeSeekPolicy) return PlexTranscodeSeekAction.nativeSeek;

    final state = currentPlayer.state;
    final action = resolvePlexTranscodeSeekAction(
      currentPosition: state.position,
      target: target,
      bufferRanges: state.bufferRanges,
      // MPV can seek safely inside its reported local buffer. ExoPlayer's
      // progressive source reports ranges that are not consistently seekable.
      allowBufferedNativeSeek: _playerBackendLabel == 'mpv',
    );
    appLogger.d(
      'Plex transcode seek decision: action=${action.name}, '
      'position=${state.position.inSeconds}s, target=${target.inSeconds}s, '
      'buffer=${state.buffer.inSeconds}s, ranges=${state.bufferRanges.length}',
    );
    return action;
  }

  /// Coalesce timeline drag updates before reopening the progressive Plex
  /// transcode. If another target arrives during a reopen, process the newest
  /// target immediately afterwards so the release position always wins.
  Future<void> _queuePlexTranscodeRestart(Duration target) {
    _pendingPlexTranscodeSeekTarget = target;
    final active = _plexTranscodeSeekCompleter;
    if (active != null) return active.future;

    final completer = Completer<void>();
    _plexTranscodeSeekCompleter = completer;
    unawaited(_drainPlexTranscodeSeeks(completer));
    return completer.future;
  }

  Future<void> _drainPlexTranscodeSeeks(Completer<void> completer) async {
    try {
      // VideoControls dispatches scrub updates on a 200 ms throttle. Waiting
      // one interval avoids reopening at the first intermediate drag point.
      await Future<void>.delayed(const Duration(milliseconds: 225));
      while (mounted) {
        await _waitForPlaybackTransitionIdle();
        if (!mounted) break;

        final target = _pendingPlexTranscodeSeekTarget;
        _pendingPlexTranscodeSeekTarget = null;
        if (target == null) break;

        final currentPlayer = player;
        if (currentPlayer == null) break;
        if (!_usesPlexVodTranscodeSeekPolicy) {
          await currentPlayer.seek(clampSeekPosition(currentPlayer, target));
          continue;
        }

        final outcome = await _restartPlexTranscodeAt(target);
        if (outcome == _MediaReloadOutcome.failed || outcome == _MediaReloadOutcome.rejected) break;
      }
    } catch (error, stackTrace) {
      appLogger.w('Failed to process Plex transcode seek', error: error, stackTrace: stackTrace);
    } finally {
      if (identical(_plexTranscodeSeekCompleter, completer)) {
        _plexTranscodeSeekCompleter = null;
      }
      if (!completer.isCompleted) completer.complete();
    }
  }

  Future<_MediaReloadOutcome> _restartPlexTranscodeAt(Duration target) {
    appLogger.d('Restarting Plex transcode at ${target.inSeconds}s');
    _chromeController.show();
    return _reloadMediaInPlace(
      metadata: _currentMetadata.copyWith(viewOffsetMs: target.inMilliseconds),
      selectedMediaIndex: _effectiveSelectedMediaIndex,
      selectedMediaSourceId: _requestedMediaSourceId,
      qualityPreset: _selectedQualityPreset,
      selectedAudioStreamId: _selectedAudioStreamId,
      resumePosition: target,
      preserveCurrentTrackSelection: true,
      reason: 'Plex transcode seek',
    );
  }

  /// Relative seek shared by the companion remote and the OS media-control
  /// skip commands, including the live-TV capture-buffer branch.
  Future<void> _seekRelative(Duration delta) async {
    final currentPlayer = player;
    if (currentPlayer == null) return;
    if (widget.isLive && _live.captureBuffer != null) {
      _liveSeek.seekBy(delta.inSeconds);
      return;
    }
    await _seekPlayback(currentPlayer.state.position + delta);
  }
}
