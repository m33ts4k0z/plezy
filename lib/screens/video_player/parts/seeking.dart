part of '../../video_player_screen.dart';

extension _VideoPlayerSeekingMethods on VideoPlayerScreenState {
  Future<void> _seekPlayback(Duration position) async {
    final currentPlayer = player;
    if (!mounted || _shuttingDown || currentPlayer == null) return;
    final target = clampSeekPosition(currentPlayer, position);
    // Declare intentional seeks before the delegate can unbind/reload at EOF.
    _activeWatchTogetherSession()?.onLocalSeek(target);
    await _performSeekPlayback(target);
  }

  Future<void> _performSeekPlayback(Duration position, {bool Function()? isCurrent}) async {
    final currentPlayer = player;
    if (!mounted || _shuttingDown || currentPlayer == null) return;
    final generation = _transitionGate.generation;

    final target = clampSeekPosition(currentPlayer, position);
    // Parked on a dead stream (#1520): a native seek would land inside the
    // drained cache — rebuild the stream at the target instead.
    if (_eofRecovery.parked && !widget.isLive && _transitionGate.transition == PlaybackTransition.idle) {
      await _eofRecovery.retry(reason: 'seek', resumePosition: target);
      return;
    }
    // A stacked item's other file: a native seek cannot leave the open one.
    final partTimeline = _currentMediaInfo?.partTimeline;
    if (!widget.isLive && partTimeline != null && !partTimeline.covers(target)) {
      if (!(isCurrent?.call() ?? true)) return;
      await _openStackedPartAt(target, reason: 'stacked part seek');
      return;
    }
    // A progressive Plex transcode (HTTP/MKV) only holds what the server has
    // already produced: a seek outside that window restarts the transcode at
    // the target instead of stalling on bytes that do not exist yet.
    if (_plexTranscodeSeekAction(currentPlayer, target) == PlexTranscodeSeekAction.restartTranscode) {
      if (!(isCurrent?.call() ?? true)) return;
      await _queuePlexTranscodeRestart(target);
      return;
    }
    // Finish an already-dispatched seek before issuing a newer target; an old
    // native completion must not land after the user's superseding seek.
    while (_nativeSeekDrain != null) {
      await _nativeSeekDrain!.future;
    }
    if (!_isCurrentPlaybackGeneration(generation, currentPlayer) || !(isCurrent?.call() ?? true)) return;
    _nativeSeekDrain = Completer<void>();
    try {
      await currentPlayer.seek(target);
    } finally {
      _nativeSeekDrain!.complete();
      _nativeSeekDrain = null;
    }
  }

  /// Open the file of a stacked item that holds [target] in place of the one
  /// playing: a seek past the open file's span, or the open file playing out
  /// with another one after it. The item, its session and its selections
  /// carry on; only the file changes.
  Future<MediaReloadOutcome> _openStackedPartAt(Duration target, {required String reason}) {
    return _reloadMediaInPlace(
      metadata: _currentMetadata,
      resumePosition: target,
      preserveCurrentTrackSelection: true,
      startPaused: !_playbackIntentShouldPlay,
      reason: reason,
    );
  }

  /// The open file of a stacked item played out and another one follows:
  /// open it rather than finishing the item. False when there is no next
  /// file, so the caller runs the normal completion flow.
  bool _advanceStackedPart() {
    final partTimeline = _currentMediaInfo?.partTimeline;
    if (widget.isLive || partTimeline == null || !partTimeline.hasNext) return false;
    if (_transitionGate.transition != PlaybackTransition.idle) return false;
    final next = partTimeline.parts[partTimeline.currentIndex + 1];
    appLogger.i(
      'Stacked part ${partTimeline.currentIndex + 1}/${partTimeline.parts.length} ended; '
      'opening part ${partTimeline.currentIndex + 2} at ${next.start.inMilliseconds}ms',
    );
    unawaited(_openStackedPartAt(next.start, reason: 'stacked part advance'));
    return true;
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
        await _transitionGate.waitForIdle(() => mounted);
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
        if (outcome == MediaReloadOutcome.failed || outcome == MediaReloadOutcome.rejected) break;
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

  Future<MediaReloadOutcome> _restartPlexTranscodeAt(Duration target) {
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

  /// One skip step, as the viewer configured it.
  ///
  /// Every OS skip command carries the interval the platform advertised —
  /// Android's MediaSession hardcodes 15 s — and it is deliberately ignored:
  /// a lock-screen skip, a companion-remote skip and an in-app skip all move
  /// the playhead by the same amount.
  Duration get _configuredSkipStep => Duration(seconds: SettingsService.instance.read(SettingsService.seekTimeSmall));

  /// Skip one configured step in [forward]'s direction.
  void _skipByConfiguredStep({required bool forward}) {
    final step = _configuredSkipStep;
    _seekRelative(forward ? step : -step);
  }

  /// Relative seek shared by the companion remote, the OS media-control skip
  /// commands and the screen's own transport keys, including the live-TV
  /// capture-buffer branch.
  ///
  /// Off live TV the step is accumulated rather than dispatched: all three
  /// sources arrive in bursts faster than a native seek completes, and
  /// [_performSeekPlayback] serialises on the in-flight one — so a seek per
  /// event would have every queued event rebase off the same stale position.
  void _seekRelative(Duration delta) {
    final currentPlayer = player;
    if (currentPlayer == null) return;
    // Live TV keeps its own epoch accumulator: an absolute target is
    // meaningless against a moving live edge (#1253). Without a capture
    // buffer there is no window to step through at all, so the skip is
    // dropped rather than handed to the VOD accumulator.
    if (widget.isLive) {
      if (_live.captureBuffer != null) _liveSeek.seekBy(delta.inSeconds);
      return;
    }
    _relativeSkip.seekBy(delta);
  }
}
