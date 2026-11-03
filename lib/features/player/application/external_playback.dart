import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/models/media_item.dart';
import '../../library/application/canonical_library_repository.dart';
import '../../library/application/local_library_provider.dart';
import '../../tracking/application/tracker_sync_coordinator.dart';
import '../../tracking/data/tracking_sync_store.dart';
import 'player_settings.dart';

enum ExternalPlayer {
  internal('MiruShin'),
  internalHardwareCopy('MiruShin · аппаратное (совместимость)'),
  internalSoftware('MiruShin · программное декодирование'),
  vimu('Vimu'),
  mx('MX Player'),
  mxSoftware('MX Player · программное декодирование'),
  next('Next Player'),
  nextSoftware('Next Player · программное декодирование');

  const ExternalPlayer(this.label);
  final String label;
}

bool get supportsExternalPlayback =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

final externalPlayerProvider =
    AsyncNotifierProvider<ExternalPlayerPreference, ExternalPlayer>(
      ExternalPlayerPreference.new,
    );

class ExternalPlayerPreference extends AsyncNotifier<ExternalPlayer> {
  static const key =
      'android.externalPlayer'; // Device-local, outside Drive settings.
  @override
  Future<ExternalPlayer> build() async {
    if (!supportsExternalPlayback) return ExternalPlayer.internal;
    final prefs = await SharedPreferences.getInstance();
    return ExternalPlayer.values.firstWhere(
      (value) => value.name == prefs.getString(key),
      orElse: () => ExternalPlayer.internal,
    );
  }

  Future<void> select(ExternalPlayer value) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(key, value.name)) {
      throw StateError('Не удалось сохранить выбор плеера');
    }
    state = AsyncData(value);
  }
}

class ExternalPlaybackBridge {
  static const channel = MethodChannel('mirushin/external_playback');
  static String? attachedSessionId;

  static Future<bool> hasAccess() async =>
      await channel.invokeMethod<bool>('access') ?? false;

  static Future<void> openAccessSettings() => channel.invokeMethod('settings');

  static Future<Map<String, dynamic>?> map(
    String method, [
    Object? args,
  ]) async {
    final raw = await channel.invokeMapMethod<String, dynamic>(method, args);
    return raw == null ? null : Map<String, dynamic>.from(raw);
  }
}

/// A successful database write must precede journal acknowledgement. Account
/// mismatches and failed writes keep the journal intact for a later retry.
Future<bool> replayExternalCheckpoint({
  required Map<String, dynamic> checkpoint,
  required String workspaceId,
  required Future<void> Function(Map<String, dynamic>) save,
  required Future<void> Function() acknowledge,
}) async {
  final context = Map<String, dynamic>.from(checkpoint['context'] as Map);
  if (context['workspaceId'] != workspaceId) return false;
  if (checkpoint['observed'] == true && context['ignoreProgress'] != true) {
    await save(checkpoint);
  }
  await acknowledge();
  return true;
}

Future<void>? _recovery;

final externalPlaybackRecoveryProvider = FutureProvider<void>((ref) async {
  ref.watch(libraryWorkspaceScopeProvider);
  if (supportsExternalPlayback) await recoverExternalPlayback(ref);
});

Future<void> recoverExternalPlayback(Ref ref, {bool returned = false}) {
  if (!supportsExternalPlayback ||
      (!returned && ExternalPlaybackBridge.attachedSessionId != null)) {
    return Future<void>.value();
  }
  return _recovery ??= _recover(ref).whenComplete(() => _recovery = null);
}

Future<void> _recover(Ref ref) async {
  final checkpoint = await ExternalPlaybackBridge.map('pending');
  if (checkpoint == null || !ref.mounted) return;
  final workspace = ref.read(libraryWorkspaceScopeProvider).workspaceId;
  final repository = ref.read(canonicalLibraryRepositoryProvider);
  final library = ref.read(localLibraryProvider.notifier);
  final coordinator = ref.read(trackerSyncCoordinatorProvider);
  final settings = await ref.read(playerSettingsProvider.future);
  await replayExternalCheckpoint(
    checkpoint: checkpoint,
    workspaceId: workspace,
    save: (value) async {
      final context = Map<String, dynamic>.from(value['context'] as Map);
      final media = MediaItem.fromJson(
        Map<String, dynamic>.from(context['media'] as Map),
      );
      final season = (context['season'] as num).toInt();
      final episode = (context['episode'] as num).toDouble();
      final updatedAt = DateTime.fromMillisecondsSinceEpoch(
        (value['updatedAtMs'] as num).toInt(),
      );
      final previous = await repository.loadEpisodeProgress(
        mediaId: media.id,
        season: season,
        episode: episode,
      );
      // A recovered checkpoint must never undo newer playback or a deliberate reset.
      if (previous != null && previous.updatedAt.isAfter(updatedAt)) return;
      final duration = (value['durationMs'] as num).toInt() ~/ 1000;
      final position = (value['positionMs'] as num).toInt() ~/ 1000;
      final ended =
          value['completed'] ==
          true; // Explicit, documented player result only.
      final watched = ended || (duration >= 120 && position >= duration * .85);
      final savedPosition = ended ? 0 : position;
      final savedDuration = duration > 0 ? duration : null;
      // Call the strict repository API: compatibility-cache failures must not
      // falsely acknowledge a checkpoint that SQLite never committed.
      await repository.saveEpisodeProgress(
        mediaId: media.id,
        season: season,
        episode: episode,
        positionSeconds: savedPosition,
        durationSeconds: savedDuration,
        completed: watched,
        mediaItem: media,
        occurredAt: updatedAt,
      );
      if (!ref.mounted ||
          ref.read(libraryWorkspaceScopeProvider).workspaceId != workspace) {
        throw StateError('Во время восстановления изменилась учётная запись');
      }
      await library.saveEpisodeProgress(
        mediaId: media.id,
        season: season,
        episode: episode,
        positionSeconds: savedPosition,
        durationSeconds: savedDuration,
        completed: watched,
        mediaItem: media,
        persistCanonical: false,
      );
      if (settings.autoAnilistSync) {
        await library.updateWatchProgress(
          mediaId: media.id,
          seasonNumber: season,
          episodeNumber: episode,
          positionFraction: watched
              ? 1
              : (duration > 0 ? position / duration : null),
        );
        if (watched) {
          await coordinator.pushEpisodeProgress(
            externalIds: media.externalIds,
            mediaId: media.id,
            mediaTitle: media.title,
            mediaItem: media,
            episode: episode.round(),
            total: media.episodeCount,
            episodeCheckpoint: TrackingEpisodeCheckpoint(
              mediaId: media.id,
              season: season,
              episode: episode,
              positionSeconds: savedPosition,
              durationSeconds: savedDuration,
              completed: true,
            ),
          );
        }
      }
    },
    acknowledge: () async {
      if (!ref.mounted ||
          ref.read(libraryWorkspaceScopeProvider).workspaceId != workspace) {
        throw StateError('Во время восстановления изменилась учётная запись');
      }
      await ExternalPlaybackBridge.channel.invokeMethod('ack', {
        'sessionId': checkpoint['sessionId'],
        'revision': checkpoint['revision'],
      });
    },
  );
}
