import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirushin/features/player/application/external_playback.dart';
import 'package:mirushin/features/player/engine/external_player_engine.dart';
import 'package:mirushin/features/player/engine/player_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic> checkpoint({
    bool observed = true,
    bool ignore = false,
  }) => {
    'context': {'workspaceId': 'anilist:1', 'ignoreProgress': ignore},
    'observed': observed,
  };

  test('recovery commits before acknowledging native journal', () async {
    final calls = <String>[];
    await replayExternalCheckpoint(
      checkpoint: checkpoint(),
      workspaceId: 'anilist:1',
      save: (_) async {
        calls.add('save');
      },
      acknowledge: () async {
        calls.add('ack');
      },
    );
    expect(calls, ['save', 'ack']);
  });

  test('failed persistence keeps native journal for retry', () async {
    var acknowledged = false;
    await expectLater(
      replayExternalCheckpoint(
        checkpoint: checkpoint(),
        workspaceId: 'anilist:1',
        save: (_) async => throw StateError('disk full'),
        acknowledge: () async {
          acknowledged = true;
        },
      ),
      throwsStateError,
    );
    expect(acknowledged, isFalse);
  });

  test('different account cannot consume or write a checkpoint', () async {
    var touched = false;
    final replayed = await replayExternalCheckpoint(
      checkpoint: checkpoint(),
      workspaceId: 'anilist:2',
      save: (_) async {
        touched = true;
      },
      acknowledge: () async {
        touched = true;
      },
    );
    expect(replayed, isFalse);
    expect(touched, isFalse);
  });

  for (final value in [checkpoint(observed: false), checkpoint(ignore: true)]) {
    test(
      'cancelled/unobserved or untracked playback never invents progress: $value',
      () async {
        var saved = false;
        var acknowledged = false;
        await replayExternalCheckpoint(
          checkpoint: value,
          workspaceId: 'anilist:1',
          save: (_) async {
            saved = true;
          },
          acknowledge: () async {
            acknowledged = true;
          },
        );
        expect(saved, isFalse);
        expect(acknowledged, isTrue);
      },
    );
  }

  test(
    'TV player choice leaves synchronized desktop settings unchanged',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({
        'mirushin.player.settings': '{"playerBackend":"auto"}',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(externalPlayerProvider.future);
      await container
          .read(externalPlayerProvider.notifier)
          .select(ExternalPlayer.vimu);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('mirushin.player.settings'),
        '{"playerBackend":"auto"}',
      );
      expect(container.read(externalPlayerProvider).value, ExternalPlayer.vimu);
    },
  );

  test(
    'normal return saves confirmed position before leaving MiruShin',
    () async {
      var snapshot = <String, dynamic>{
        'observed': false,
        'active': true,
        'returned': false,
        'completed': false,
        'positionMs': 250000,
        'durationMs': 0,
      };
      final calls = <MethodCall>[];
      final persisted = Completer<void>();
      final returnStarted = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ExternalPlaybackBridge.channel, (
            call,
          ) async {
            calls.add(call);
            return call.method == 'state' ? snapshot : null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ExternalPlaybackBridge.channel, null),
      );
      final engine = ExternalPlayerEngine(
        target: ExternalPlayer.mx,
        title: 'Episode 11',
        context: const {},
        prepare: () async {},
        onReturn: (engine) async {
          expect(engine.value.position.inMilliseconds, 876000);
          expect(engine.explicitCompletion, isFalse);
          returnStarted.complete();
          await persisted.future;
        },
      );
      addTearDown(engine.dispose);
      final commands = <PlayerEngineUiCommand>[];
      final subscription = engine.uiCommands.listen(commands.add);
      await engine.open(
        const PlayerSource(url: 'https://example.com/11.m3u8'),
        startAt: const Duration(seconds: 250),
      );
      expect((calls.first.arguments as Map)['positionMs'], 250000);
      expect(
        engine.value.isInitialized,
        isFalse,
      ); // A requested position is not playback evidence.
      snapshot = {
        ...snapshot,
        'observed': true,
        'active': false,
        'returned': true,
        'positionMs': 876000,
        'durationMs': 1400000,
      };
      await returnStarted.future.timeout(const Duration(seconds: 3));
      expect(commands, isEmpty);
      final exit = engine.uiCommands.first;
      persisted.complete();
      expect(
        await exit.timeout(const Duration(seconds: 3)),
        PlayerEngineUiCommand.exitPlayer,
      );
      await engine.dispose();
      await subscription.cancel();
    },
  );

  test(
    'explicit external completion works without inventing a duration',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            ExternalPlaybackBridge.channel,
            (call) async => call.method == 'state'
                ? {
                    'observed': true,
                    'active': false,
                    'returned': true,
                    'completed': true,
                    'positionMs': 0,
                    'durationMs': 0,
                  }
                : null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ExternalPlaybackBridge.channel, null),
      );
      final saved = Completer<void>();
      final engine = ExternalPlayerEngine(
        target: ExternalPlayer.vimu,
        title: 'Episode 11',
        context: const {},
        prepare: () async {},
        onReturn: (_) async {
          saved.complete();
        },
      );
      addTearDown(engine.dispose);
      await engine.open(const PlayerSource(url: 'https://example.com/11.m3u8'));
      await saved.future.timeout(const Duration(seconds: 3));
      expect(engine.explicitCompletion, isTrue);
      expect(engine.value.duration, Duration.zero);
      await engine.dispose();
    },
  );
}
