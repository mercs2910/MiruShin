import 'package:flutter_test/flutter_test.dart';
import 'package:mirushin/features/player/application/external_playback.dart';

void main() {
  Map<String, dynamic> checkpoint({bool observed = true, bool ignore = false}) => {
    'context': {'workspaceId': 'anilist:1', 'ignoreProgress': ignore},
    'observed': observed,
  };

  test('recovery commits before acknowledging native journal', () async {
    final calls = <String>[];
    await replayExternalCheckpoint(checkpoint: checkpoint(), workspaceId: 'anilist:1',
      save: (_) async { calls.add('save'); }, acknowledge: () async { calls.add('ack'); });
    expect(calls, ['save', 'ack']);
  });

  test('failed persistence keeps native journal for retry', () async {
    var acknowledged = false;
    await expectLater(replayExternalCheckpoint(checkpoint: checkpoint(), workspaceId: 'anilist:1',
      save: (_) async => throw StateError('disk full'),
      acknowledge: () async { acknowledged = true; }), throwsStateError);
    expect(acknowledged, isFalse);
  });

  test('different account cannot consume or write a checkpoint', () async {
    var touched = false;
    final replayed = await replayExternalCheckpoint(checkpoint: checkpoint(), workspaceId: 'anilist:2',
      save: (_) async { touched = true; }, acknowledge: () async { touched = true; });
    expect(replayed, isFalse);
    expect(touched, isFalse);
  });

  for (final value in [checkpoint(observed: false), checkpoint(ignore: true)]) {
    test('cancelled/unobserved or untracked playback never invents progress: $value', () async {
      var saved = false;
      var acknowledged = false;
      await replayExternalCheckpoint(checkpoint: value, workspaceId: 'anilist:1',
        save: (_) async { saved = true; }, acknowledge: () async { acknowledged = true; });
      expect(saved, isFalse);
      expect(acknowledged, isTrue);
    });
  }
}
