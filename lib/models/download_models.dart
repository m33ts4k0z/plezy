// ignore_for_file: invalid_annotation_target
import 'package:freezed_annotation/freezed_annotation.dart';

import '../utils/formatters.dart';

part 'download_models.freezed.dart';

enum DownloadStatus {
  queued,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
  partial, // Some episodes downloaded, but not all (for shows/seasons)
  /// Server is transcoding the file before Plezy can fetch any bytes.
  /// Only used for Plex server-side transcoded downloads (the
  /// `/downloadQueue` flow): once we POST to enqueue the transcode, the
  /// download sits in this state until status flips to `available`, then
  /// transitions to [downloading]. The `progress` field reports the
  /// server-side transcode percent so the downloads UI can show it.
  preparing,
}

@freezed
sealed class DownloadProgress with _$DownloadProgress {
  const DownloadProgress._();

  const factory DownloadProgress({
    required String globalKey,
    required DownloadStatus status,
    @Default(0) int progress,
    @Default(0) int downloadedBytes,
    @Default(0) int totalBytes,
    @Default(0.0) double speed,
    String? errorMessage,
    String? currentFile,
    String? thumbPath,
  }) = _DownloadProgress;

  double get progressPercent => progress / 100.0;

  String get speedFormatted => ByteFormatter.formatSpeed(speed);

  bool get hasArtworkPaths => thumbPath != null;
}

@freezed
sealed class DeletionProgress with _$DeletionProgress {
  const DeletionProgress._();

  const factory DeletionProgress({
    required String globalKey,
    required String itemTitle,
    required int currentItem,
    required int totalItems,
    String? currentOperation,
  }) = _DeletionProgress;

  double get progressPercent => totalItems > 0 ? (currentItem / totalItems) : 0.0;

  int get progressPercentInt => (progressPercent * 100).round();

  bool get isComplete => currentItem >= totalItems;
}
