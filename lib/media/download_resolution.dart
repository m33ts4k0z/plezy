/// Backend-neutral download resolution types.
///
/// Returned by [MediaServerClient] download-resolution methods so the
/// [DownloadManagerService] doesn't need to know whether it's talking to
/// Plex or Jellyfin.
library;

/// Spec for a single external subtitle track that should be downloaded
/// alongside the video file.
///
/// `id` is a backend-stable integer used in the on-disk filename
/// (Plex stream id, Jellyfin stream index).
class DownloadSubtitleSpec {
  final int id;
  final String url;
  final String? codec;
  final String? language;
  final String? languageCode;
  final bool forced;
  final String? displayTitle;

  const DownloadSubtitleSpec({
    required this.id,
    required this.url,
    this.codec,
    this.language,
    this.languageCode,
    this.forced = false,
    this.displayTitle,
  });
}

/// Spec for a single artwork file. `localKey` is the deterministic key the
/// storage service hashes to compute the on-disk filename — Plex passes the
/// backend-relative path so cache deduplication works across items that
/// reference the same blob; Jellyfin passes the absolute URL since artwork
/// URLs are already unique per item after stripping auth query parameters.
class DownloadArtworkSpec {
  final String localKey;
  final String url;

  const DownloadArtworkSpec({required this.localKey, required this.url});
}

/// Bundle of everything the download pipeline needs to fetch the primary
/// video file and its companion subtitle sidecars for a chosen media
/// version.
class DownloadResolution {
  final String? videoUrl;
  final List<DownloadSubtitleSpec> externalSubtitles;

  /// True when [videoUrl] points at a server-side transcoder rather than
  /// the original file. Transcoded streams aren't seekable (no Range
  /// support, no Content-Length) so the download manager must disable
  /// pause/resume and tighten retry semantics to avoid restarting the
  /// transcode in a loop.
  final bool isTranscoded;

  /// Extra headers to attach to the download task. Used by Plex
  /// transcoded downloads to set `Known-Content-Length`, which the
  /// background_downloader package picks up when the server doesn't
  /// send a real Content-Length — without it the package treats the
  /// task as "size unknown" and Android cancels the background work.
  final Map<String, String> extraHeaders;

  /// Plex downloadQueue queue id. Non-null only when the resolution
  /// represents a server-side transcoded download that has already been
  /// queued on PMS but isn't ready yet — the download manager polls
  /// [PlexClient.pollServerSideTranscode] until the file is `available`
  /// before starting the actual byte fetch at [videoUrl]. Must appear
  /// together with [serverTranscodeItemId].
  final int? serverTranscodeQueueId;

  /// Plex downloadQueue item id paired with [serverTranscodeQueueId].
  /// Also used to DELETE the queue item from the server when the local
  /// download is cancelled, so the server-side ffmpeg stops and disk
  /// is freed.
  final int? serverTranscodeItemId;

  const DownloadResolution({
    required this.videoUrl,
    this.externalSubtitles = const [],
    this.isTranscoded = false,
    this.extraHeaders = const {},
    this.serverTranscodeQueueId,
    this.serverTranscodeItemId,
  });

  /// Whether the caller must poll the server's downloadQueue before
  /// kicking off the byte download — true for in-flight server-side
  /// transcodes, false for direct downloads or already-ready files.
  bool get needsServerTranscodePolling => serverTranscodeQueueId != null && serverTranscodeItemId != null;
}
