import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mirushin/features/player/domain/player_models.dart';
import 'package:mirushin/features/player/engine/player_engine.dart';
import 'package:mirushin/features/player/engine/video_player_engine.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Android adapter preserves headers, resume and native completion',
    () async {
      final previous = VideoPlayerPlatform.instance;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final platform = _VideoPlatform();
      VideoPlayerPlatform.instance = platform;
      final engine = VideoPlayerEngine();
      addTearDown(() async {
        await engine.dispose();
        await platform.events.close();
        VideoPlayerPlatform.instance = previous;
        debugDefaultTargetPlatformOverride = null;
      });

      await engine.open(
        const PlayerSource(
          url: 'https://example.com/episode.m3u8',
          streamType: StreamType.hls,
          headers: {'Referer': 'https://example.com'},
        ),
        startAt: const Duration(minutes: 2),
        autoplay: false,
      );
      expect(platform.source?.httpHeaders, {'Referer': 'https://example.com'});
      expect(platform.source?.formatHint, VideoFormat.hls);
      expect(platform.viewType, VideoViewType.platformView);
      expect(platform.seeks, [const Duration(minutes: 2)]);
      expect(engine.managesInitialPosition, isTrue);
      expect(engine.value.position, const Duration(minutes: 2));
      expect(engine.value.isPlaying, isFalse);
      expect(engine.value.isCompleted, isFalse);

      await engine.play();
      expect(engine.value.isPlaying, isTrue);
      platform.events.add(VideoEvent(eventType: VideoEventType.completed));
      await Future<void>.delayed(Duration.zero);
      expect(engine.value.isCompleted, isTrue);
      expect(engine.value.position, const Duration(minutes: 10));

      await engine.seekTo(const Duration(minutes: 3));
      expect(engine.value.isCompleted, isFalse);
      expect(engine.value.position, const Duration(minutes: 3));
    },
  );
}

class _VideoPlatform extends VideoPlayerPlatform {
  final events = StreamController<VideoEvent>.broadcast();
  final seeks = <Duration>[];
  DataSource? source;
  VideoViewType? viewType;
  Duration position = Duration.zero;

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    source = options.dataSource;
    viewType = options.viewType;
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    scheduleMicrotask(
      () => events.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(minutes: 10),
          size: const Size(1280, 720),
        ),
      ),
    );
    return events.stream;
  }

  @override
  Future<void> dispose(int playerId) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> play(int playerId) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> seekTo(int playerId, Duration value) async {
    position = value;
    seeks.add(value);
  }

  @override
  Future<Duration> getPosition(int playerId) async => position;
}
