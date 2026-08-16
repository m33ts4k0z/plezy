import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_file_info.dart';
import 'package:plezy/services/downloaded_file_info_service.dart';

void main() {
  test('native probe builds downloaded file info from physical output metadata', () async {
    final service = DownloadedFileInfoService.forTesting(
      nativeProbe: (_) async => <Object?, Object?>{
        'displayName': 'S01E02 - Converted.mkv',
        'mimeType': 'video/x-matroska',
        'fileSizeBytes': 734003200,
        'durationMs': 2700000,
        'bitrateBps': 2175000,
        'width': 1280,
        'height': 720,
        'frameRate': 23.976,
        'rotation': 0,
      },
    );

    final info = await service.probe('content://downloads/converted');

    expect(info, isNotNull);
    final version = info!.versions.single;
    expect(version.container, 'mkv');
    expect(version.totalFileSize, 734003200);
    expect(version.resolutionFormatted, '1280x720');
    expect(version.durationMs, 2700000);
    expect(version.bitrateKbps, 2175);
    expect(version.sourceType, 'Downloaded');
    final video = version.parts.single.streams.single;
    expect(video.kind, MediaStreamKind.video);
    expect(video.resolutionFormatted, '1280x720');
    expect(video.frameRate, closeTo(23.976, 0.0001));
    expect(video.rotation, 0);
  });

  test('filesystem stat overrides stale transfer size with exact completed file size', () async {
    final directory = await Directory.systemTemp.createTemp('plezy-local-info-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}converted.mp4');
    await file.writeAsBytes(List<int>.filled(1537, 1));
    final service = DownloadedFileInfoService.forTesting(useNativeProbe: false);

    final info = await service.probe(file.path, fallbackSizeBytes: 999999);

    expect(info, isNotNull);
    final version = info!.versions.single;
    expect(version.container, 'mp4');
    expect(version.totalFileSize, 1537);
    expect(version.parts.single.fileName, 'converted.mp4');
  });

  test('SAF stat can fall back to persisted transfer bytes when provider omits size', () async {
    final service = DownloadedFileInfoService.forTesting(
      nativeProbe: (_) async => <Object?, Object?>{'displayName': 'converted.webm', 'width': 854, 'height': 480},
    );

    final info = await service.probe('content://downloads/converted', fallbackSizeBytes: 123456789);

    expect(info, isNotNull);
    final version = info!.versions.single;
    expect(version.container, 'webm');
    expect(version.totalFileSize, 123456789);
    expect(version.resolutionFormatted, '854x480');
  });
}
