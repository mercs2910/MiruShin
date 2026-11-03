import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../application/external_playback.dart';
import '../domain/player_models.dart';
import 'player_engine.dart';

/// The external app owns decoding. This engine only adapts confirmed Android
/// media state to MiruShin's existing progress, skip and next-episode workers.
class ExternalPlayerEngine extends PlayerEngine {
  ExternalPlayerEngine({required this.target, required this.title,
    required this.context, required this.prepare, required this.onReturn});

  final ExternalPlayer target;
  final String title;
  final Map<String, Object?> context;
  final Future<void> Function() prepare;
  final Future<void> Function(ExternalPlayerEngine) onReturn;
  final _state = ValueNotifier(const PlayerEngineState());
  final _commands = StreamController<PlayerEngineUiCommand>.broadcast();
  final _sessionId = const Uuid().v4();
  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;
  bool _returned = false;
  bool explicitCompletion = false;
  bool _canControl = false;
  bool _canSeek = false;
  double? _startupSpeed;

  @override
  ValueListenable<PlayerEngineState> get state => _state;
  @override
  Stream<PlayerEngineUiCommand> get uiCommands => _commands.stream;
  @override
  bool get managesInitialPosition => true;
  @override
  bool get managesStartupPlaybackSpeed => true;
  @override
  bool get initialPositionSettled => _state.value.isInitialized;

  @override
  Widget buildVideoSurface(BuildContext context) => Center(
    child: Text('Воспроизведение в ${target.label}. Вернитесь кнопкой «Назад».'),
  );

  @override
  Future<void> open(PlayerSource source, {Duration? startAt, bool autoplay = false}) async {
    await prepare();
    await ExternalPlaybackBridge.channel.invokeMethod('start', {
      'sessionId': _sessionId, 'target': target.name, 'title': title,
      'url': source.url, 'headers': source.headers,
      'mime': switch (source.streamType) {
        StreamType.hls => 'application/x-mpegURL',
        StreamType.dash => 'application/dash+xml',
        _ => 'video/*',
      },
      'positionMs': (startAt ?? Duration.zero).inMilliseconds,
      'context': context,
    });
    ExternalPlaybackBridge.attachedSessionId = _sessionId;
    // Initial requested position is not an observation and must not be saved.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(_poll()));
  }

  Future<void> _poll() async {
    if (_polling || _disposed || _returned) return;
    _polling = true;
    try {
      final value = await ExternalPlaybackBridge.map('state', {'sessionId': _sessionId});
      if (value == null || _disposed) return;
      explicitCompletion = value['completed'] == true;
      _canControl = value['observed'] == true && value['active'] == true;
      _canSeek = value['canSeek'] == true;
      _returned = value['returned'] == true;
      _state.value = _state.value.copyWith(
        position: Duration(milliseconds: (value['positionMs'] as num).toInt()),
        duration: Duration(milliseconds: (value['durationMs'] as num).toInt()),
        isInitialized: value['observed'] == true,
        hasVideoSurface: value['observed'] == true,
        isPlaying: value['playing'] == true,
        isBuffering: value['buffering'] == true,
        isCompleted: explicitCompletion,
        playbackSpeed: (value['speed'] as num?)?.toDouble(),
      );
      if (_canControl && _startupSpeed != null) {
        final speed = _startupSpeed!;
        _startupSpeed = null;
        await _command('speed', {'speed': speed});
      }
      if (_returned) {
        _timer?.cancel();
        await onReturn(this);
        if (!_disposed && value['error'] == true) {
          _state.value = _state.value.copyWith(hasError: true,
            errorDescription: '${target.label} не смог воспроизвести видео. Попробуйте другой режим плеера.');
          return;
        }
        if (!_disposed && !explicitCompletion) {
          _commands.add(PlayerEngineUiCommand.exitPlayer);
        }
      }
    } on Object catch (error) {
      if (!_disposed) {
        _state.value = _state.value.copyWith(hasError: true,
          errorDescription: 'Не удалось получить или сохранить состояние внешнего плеера (${error.runtimeType}).');
      }
    } finally { _polling = false; }
  }

  Future<void> _command(String command, [Map<String, Object?> args = const {}]) async {
    if (!_canControl || _disposed || (command == 'seek' && !_canSeek)) return;
    await ExternalPlaybackBridge.channel.invokeMethod('command', {
      'sessionId': _sessionId, 'command': command, ...args,
    });
  }
  @override
  Future<void> play() => _command('play');
  @override
  Future<void> pause() => _command('pause');
  @override
  Future<void> seekTo(Duration position) => _command('seek', {'positionMs': position.inMilliseconds});
  @override
  Future<void> setPlaybackSpeed(double speed) async {
    if (!_canControl) { _startupSpeed = speed; return; }
    await _command('speed', {'speed': speed});
  }
  @override
  Future<void> setVolume(double volume) async {} // External player uses system volume.
  @override
  void addListener(VoidCallback listener) => _state.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => _state.removeListener(listener);
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    if (ExternalPlaybackBridge.attachedSessionId == _sessionId) {
      ExternalPlaybackBridge.attachedSessionId = null;
    }
    await ExternalPlaybackBridge.channel.invokeMethod('detach', {'sessionId': _sessionId});
    await _commands.close();
    _state.dispose();
  }
}
