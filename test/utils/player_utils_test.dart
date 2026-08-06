import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart' show BufferRange, Player, PlayerState;
import 'package:plezy/utils/player_utils.dart';

void main() {
  group('shouldRestartBeforePreviousItem', () {
    test('keeps previous item behavior within the restart threshold', () {
      expect(shouldRestartBeforePreviousItem(Duration.zero), isFalse);
      expect(shouldRestartBeforePreviousItem(const Duration(seconds: 3)), isFalse);
    });

    test('restarts the current item after the threshold', () {
      expect(shouldRestartBeforePreviousItem(const Duration(milliseconds: 3001)), isTrue);
    });
  });

  group('clampSeekPosition', () {
    test('clamps negative positions to zero', () {
      final player = _FakePlayer(duration: const Duration(minutes: 5));

      expect(clampSeekPosition(player, const Duration(seconds: -10)), Duration.zero);
    });

    test('clamps positions beyond a known duration', () {
      final player = _FakePlayer(duration: const Duration(minutes: 5));

      expect(clampSeekPosition(player, const Duration(minutes: 6)), const Duration(minutes: 5));
    });

    test('does not upper-clamp when duration is unknown', () {
      final player = _FakePlayer(duration: Duration.zero);

      expect(clampSeekPosition(player, const Duration(minutes: 6)), const Duration(minutes: 6));
    });
  });

  group('resolvePlexTranscodeSeekAction', () {
    test('uses a native seek inside a buffered range', () {
      expect(
        resolvePlexTranscodeSeekAction(
          currentPosition: const Duration(seconds: 10),
          target: const Duration(seconds: 20),
          bufferRanges: const [BufferRange(start: Duration.zero, end: Duration(seconds: 30))],
        ),
        PlexTranscodeSeekAction.nativeSeek,
      );
    });

    test('restarts the transcode outside buffered ranges', () {
      expect(
        resolvePlexTranscodeSeekAction(
          currentPosition: const Duration(seconds: 10),
          target: const Duration(minutes: 2),
          bufferRanges: const [BufferRange(start: Duration.zero, end: Duration(seconds: 30))],
        ),
        PlexTranscodeSeekAction.restartTranscode,
      );
    });

    test('restarts when buffered native seeking is disabled', () {
      expect(
        resolvePlexTranscodeSeekAction(
          currentPosition: const Duration(seconds: 10),
          target: const Duration(seconds: 20),
          bufferRanges: const [BufferRange(start: Duration.zero, end: Duration(seconds: 30))],
          allowBufferedNativeSeek: false,
        ),
        PlexTranscodeSeekAction.restartTranscode,
      );
    });

    test('keeps near-noop seeks native even without a buffer range', () {
      expect(
        resolvePlexTranscodeSeekAction(
          currentPosition: const Duration(seconds: 10),
          target: const Duration(milliseconds: 10750),
          bufferRanges: const [],
        ),
        PlexTranscodeSeekAction.nativeSeek,
      );
    });

    test('ignores malformed buffered ranges', () {
      expect(
        resolvePlexTranscodeSeekAction(
          currentPosition: const Duration(seconds: 10),
          target: const Duration(seconds: 20),
          bufferRanges: const [BufferRange(start: Duration(seconds: 30), end: Duration(seconds: 5))],
        ),
        PlexTranscodeSeekAction.restartTranscode,
      );
    });
  });
}

class _FakePlayer implements Player {
  _FakePlayer({required Duration duration}) : _state = PlayerState(duration: duration);

  final PlayerState _state;

  @override
  PlayerState get state => _state;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
