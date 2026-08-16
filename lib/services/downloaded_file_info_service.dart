import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../media/media_file_info.dart';
import '../utils/app_logger.dart';

typedef LocalMediaNativeProbe = Future<Map<Object?, Object?>?> Function(String source);

/// Reads technical information from the physical downloaded file rather than
/// returning the source version reported by the media server.
///
/// Android uses [MediaMetadataRetriever] through the in-tree native plugin so
/// both app-private paths and Storage Access Framework `content://` URIs work.
/// Other platforms still report an exact filesystem size and container; the
/// server remains the caller's fallback when the local file cannot be read.
class DownloadedFileInfoService {
  DownloadedFileInfoService._({LocalMediaNativeProbe? nativeProbe, bool? useNativeProbe})
    : _nativeProbe = nativeProbe ?? _invokeNativeProbe,
      _useNativeProbe = useNativeProbe ?? Platform.isAndroid;

  static final instance = DownloadedFileInfoService._();

  @visibleForTesting
  factory DownloadedFileInfoService.forTesting({LocalMediaNativeProbe? nativeProbe, bool useNativeProbe = true}) {
    return DownloadedFileInfoService._(nativeProbe: nativeProbe, useNativeProbe: useNativeProbe);
  }

  static const _channel = MethodChannel('com.plezy/local_media_info');

  final LocalMediaNativeProbe _nativeProbe;
  final bool _useNativeProbe;

  static Future<Map<Object?, Object?>?> _invokeNativeProbe(String source) {
    return _channel.invokeMapMethod<Object?, Object?>('probe', {'source': source});
  }

  Future<MediaFileInfo?> probe(String source, {int? fallbackSizeBytes}) async {
    Map<Object?, Object?>? native;
    if (_useNativeProbe) {
      try {
        native = await _nativeProbe(source);
      } on MissingPluginException catch (error, stackTrace) {
        appLogger.d('Downloaded file native probe is unavailable', error: error, stackTrace: stackTrace);
      } on PlatformException catch (error, stackTrace) {
        appLogger.w('Downloaded file native probe failed for $source', error: error, stackTrace: stackTrace);
      }
    }

    var result = LocalMediaProbeResult.fromMap(native);
    if (!source.startsWith('content://')) {
      final filePath = _filePath(source);
      try {
        final file = File(filePath);
        if (await file.exists()) {
          final stat = await file.stat();
          result = result.copyWith(displayName: result.displayName ?? p.basename(filePath), fileSizeBytes: stat.size);
        }
      } on FileSystemException catch (error, stackTrace) {
        appLogger.w('Could not stat downloaded file $filePath', error: error, stackTrace: stackTrace);
      }
    }

    final effectiveSize = result.fileSizeBytes ?? _positive(fallbackSizeBytes);
    result = result.copyWith(fileSizeBytes: effectiveSize);
    if (!result.hasUsefulInformation) return null;
    return result.toMediaFileInfo(source);
  }

  static String _filePath(String source) {
    final uri = Uri.tryParse(source);
    if (uri?.scheme == 'file') return uri!.toFilePath(windows: Platform.isWindows);
    return source;
  }
}

@immutable
class LocalMediaProbeResult {
  final String? displayName;
  final String? mimeType;
  final int? fileSizeBytes;
  final int? durationMs;
  final int? bitrateBps;
  final int? width;
  final int? height;
  final double? frameRate;
  final int? rotation;

  const LocalMediaProbeResult({
    this.displayName,
    this.mimeType,
    this.fileSizeBytes,
    this.durationMs,
    this.bitrateBps,
    this.width,
    this.height,
    this.frameRate,
    this.rotation,
  });

  factory LocalMediaProbeResult.fromMap(Map<Object?, Object?>? map) {
    if (map == null) return const LocalMediaProbeResult();
    return LocalMediaProbeResult(
      displayName: _nonEmptyString(map['displayName']),
      mimeType: _nonEmptyString(map['mimeType']),
      fileSizeBytes: _positive(_asInt(map['fileSizeBytes'])),
      durationMs: _positive(_asInt(map['durationMs'])),
      bitrateBps: _positive(_asInt(map['bitrateBps'])),
      width: _positive(_asInt(map['width'])),
      height: _positive(_asInt(map['height'])),
      frameRate: _positiveDouble(map['frameRate']),
      rotation: _asInt(map['rotation']),
    );
  }

  bool get hasUsefulInformation =>
      fileSizeBytes != null || durationMs != null || width != null || height != null || displayName != null;

  LocalMediaProbeResult copyWith({String? displayName, int? fileSizeBytes}) {
    return LocalMediaProbeResult(
      displayName: displayName ?? this.displayName,
      mimeType: mimeType,
      fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
      durationMs: durationMs,
      bitrateBps: bitrateBps,
      width: width,
      height: height,
      frameRate: frameRate,
      rotation: rotation,
    );
  }

  MediaFileInfo toMediaFileInfo(String source) {
    final container = _containerFor(displayName ?? source, mimeType);
    final bitrateKbps = bitrateBps == null ? null : (bitrateBps! / 1000).round();
    final hasVideoDetails = width != null || height != null || frameRate != null || rotation != null;
    final streams = hasVideoDetails
        ? [
            MediaStreamDetails(
              kind: MediaStreamKind.video,
              ordinal: 1,
              width: width,
              height: height,
              frameRate: frameRate,
              rotation: rotation,
            ),
          ]
        : const <MediaStreamDetails>[];
    final aspectRatio = width != null && height != null && height! > 0 ? width! / height! : null;

    return MediaFileInfo(
      versions: [
        MediaFileVersion(
          container: container,
          bitrateKbps: bitrateKbps,
          durationMs: durationMs,
          width: width,
          height: height,
          aspectRatio: aspectRatio,
          protocol: source.startsWith('content://') ? 'Content' : 'File',
          videoType: 'VideoFile',
          sourceType: 'Downloaded',
          supportsDirectPlay: true,
          parts: [
            MediaFilePart(
              filePath: displayName ?? source,
              fileSize: fileSizeBytes,
              container: container,
              durationMs: durationMs,
              exists: true,
              accessible: true,
              streams: streams,
            ),
          ],
        ),
      ],
    );
  }
}

int? _asInt(Object? value) => switch (value) {
  final int value => value,
  final num value => value.toInt(),
  final String value => int.tryParse(value),
  _ => null,
};

int? _positive(int? value) => value != null && value > 0 ? value : null;

double? _positiveDouble(Object? value) {
  final parsed = switch (value) {
    final num value => value.toDouble(),
    final String value => double.tryParse(value),
    _ => null,
  };
  return parsed != null && parsed > 0 ? parsed : null;
}

String? _nonEmptyString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _containerFor(String source, String? mimeType) {
  final extension = p.extension(source).replaceFirst('.', '').toLowerCase();
  if (extension.isNotEmpty && extension.length <= 8) return extension;
  return switch (mimeType?.toLowerCase()) {
    'video/x-matroska' || 'video/matroska' => 'mkv',
    'video/mp4' => 'mp4',
    'video/webm' => 'webm',
    'video/mp2t' => 'ts',
    'video/mpeg' => 'mpeg',
    'video/quicktime' => 'mov',
    _ => null,
  };
}
