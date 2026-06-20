/// Video transcode quality presets modeled on Plex Web's custom-quality table.
///
/// When a non-[original] preset is selected, playback asks the active backend
/// for a capped transcode stream. [original] bypasses transcoding entirely and
/// uses the direct-play URL.
enum TranscodeQualityPreset {
  original(null, null, null),
  // Curated tier list — only presets that reliably deliver their
  // advertised resolution are kept. Plex's transcoder uses bitrate as
  // the primary input for resolution (with `videoResolution` acting
  // only as a ceiling), so 720p@2–3 Mbps presets capped at 480p output
  // server-side and misled users; 320p was redundant with 240p / 480p.
  p240_320(320, '420x240', 30),
  p480_1_5mbps(1500, '720x480', 60),
  p720_4mbps(4000, '1280x720', 100),
  p1080_8mbps(8000, '1920x1080', 60),
  p1080_10mbps(10000, '1920x1080', 75),
  p1080_12mbps(12000, '1920x1080', 90),
  p1080_20mbps(20000, '1920x1080', 100);

  const TranscodeQualityPreset(this.videoBitrateKbps, this.videoResolution, this.videoQuality);

  final int? videoBitrateKbps;
  final String? videoResolution;
  final int? videoQuality;

  bool get isOriginal => this == TranscodeQualityPreset.original;

  String get storageKey => name;

  static TranscodeQualityPreset fromStorage(String? stored) {
    if (stored == null) return TranscodeQualityPreset.original;
    for (final v in TranscodeQualityPreset.values) {
      if (v.name == stored) return v;
    }
    return TranscodeQualityPreset.original;
  }

  /// Resolution height (e.g. 720, 1080) parsed from [videoResolution]. Null for original.
  int? get resolutionHeight {
    final r = videoResolution;
    if (r == null) return null;
    final parts = r.split('x');
    if (parts.length != 2) return null;
    return int.tryParse(parts[1]);
  }

  /// Order shared by every picker surface so they can't drift apart:
  /// [original] pinned first, then transcode presets highest-bitrate first.
  static final List<TranscodeQualityPreset> displayOrder = List.unmodifiable([
    original,
    ...values.where((p) => !p.isOriginal).toList().reversed,
  ]);
}

/// Outcome of a transcode decision call.
enum TranscodeDecisionOutcome {
  /// Decision indicates transcode is available (`transcodeDecisionCode == 1001`).
  transcodeOk,

  /// Decision indicates only direct play is available (`transcodeDecisionCode == 1000`).
  /// Caller should fall back to the direct-play URL.
  directPlayOnly,

  /// Decision failed (HTTP error, code >= 2000, or parse error).
  failed,
}
