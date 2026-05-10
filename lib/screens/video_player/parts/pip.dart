part of '../../video_player_screen.dart';

extension _VideoPlayerPipMethods on VideoPlayerScreenState {
  /// Initialize VideoFilterManager and VideoPIPManager if not already set up.
  /// Called from both live TV and VOD playback paths.
  Future<void> _initVideoFilterAndPip() async {
    if (player == null || _videoFilterManager != null) return;
    final settings = await SettingsService.getInstance();
    _videoFilterManager = VideoFilterManager(
      player: player!,
      availableVersions: _availableVersions,
      selectedMediaIndex: widget.selectedMediaIndex,
      initialBoxFitMode: settings.read(SettingsService.defaultBoxFitMode),
      onBoxFitModeChanged: (mode) => settings.write(SettingsService.defaultBoxFitMode, mode),
    );
    _videoFilterManager!.updateVideoFilter();

    _videoPIPManager = VideoPIPManager(player: player!);
    _videoPIPManager!.onBeforeEnterPip = _preparePipFiltersForEntry;
    _videoPIPManager!.isPipActive.addListener(_onPipStateChanged);
  }

  Future<void> _togglePIPMode() async {
    final result = await _videoPIPManager?.togglePIP();
    if (result != null && !result.$1 && mounted) {
      _restorePipFiltersAfterExit();
      showErrorSnackBar(context, result.$2 ?? t.videoControls.pipFailed);
    }
  }

  void _preparePipFiltersForEntry() {
    if (_pipFiltersPrepared) return;
    _pipFiltersPrepared = true;
    _videoFilterManager?.enterPipMode();
  }

  void _restorePipFiltersAfterExit() {
    final filterManager = _videoFilterManager;
    if (filterManager == null) {
      _pipFiltersPrepared = false;
      return;
    }

    final restoreAmbient = filterManager.hadAmbientLightingBeforePip;
    filterManager.exitPipMode();
    if (restoreAmbient) {
      filterManager.clearPipAmbientLightingFlag();
      _restoreAmbientLighting();
    }
    _pipFiltersPrepared = false;
  }

  /// Handle PiP state changes to restore video scaling when exiting PiP
  void _onPipStateChanged() {
    final isInPip = _videoPIPManager?.isPipActive.value ?? PipService().isPipActive.value;
    _setAndroidAutoPipTransitionInFlight(false, reason: 'pip_state_changed');
    _recordLifecycleState('pip_state_changed', action: isInPip ? 'entered' : 'exited');

    if (_videoPIPManager == null || _videoFilterManager == null) return;

    if (isInPip) {
      _preparePipFiltersForEntry();
    } else {
      _restorePipFiltersAfterExit();

      // Android: tapping X on the PiP window dismisses PiP while the app is
      // still backgrounded. The user's intent here is "stop playback" — not
      // "pause and let me resume from the home-screen widget". Mark this
      // exit path as non-resumable and pop the route so the dispose path
      // tears down both OS media surfaces.
      if (Platform.isAndroid && mounted) {
        final lifecycleState = WidgetsBinding.instance.lifecycleState;
        final appBackgrounded =
            lifecycleState == AppLifecycleState.paused || lifecycleState == AppLifecycleState.hidden;
        if (appBackgrounded) {
          _suppressResumeArm = true;
          player?.pause();
          final navigator = Navigator.of(context);
          if (navigator.canPop()) {
            _isExiting.value = true;
            unawaited(_sendStoppedProgressOnce().then((_) {
              if (mounted) navigator.pop(true);
            }));
          }
        }
      }
    }
  }
}
