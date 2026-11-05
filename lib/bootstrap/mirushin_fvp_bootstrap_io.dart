import 'dart:io';

import 'package:fvp/fvp.dart' as fvp;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Register FVP once with MiruShin-friendly native defaults.
///
/// Keep the global defaults moderate. FvpPlayerEngine applies stronger
/// per-source/per-speed cache settings before opening each stream.
void configureMiruShinFvp() {
  final androidVideoPlayer = Platform.isAndroid
      ? VideoPlayerPlatform.instance
      : null;
  fvp.registerWith(
    options: <String, Object>{
      'fastSeek': false,
      if (Platform.isMacOS)
        'global': const <String, Object>{
          // Recent libmdk can drop video frames that are already too late to
          // present. Without this, accelerated playback can fall progressively
          // behind audio and look like repeated freezing even for local HLS.
          'avsync.video.decoder_drop': 1,
        },
      'player': <String, String>{
        'buffer': '3000+180000',
        'demux.buffer.protocols': 'file,http,https',
        'demux.buffer.ranges': '16',
        'avformat.strict': 'experimental',
        'avformat.safe': '0',
        'avformat.extension_picky': '0',
        'avformat.allowed_segment_extensions': 'ALL',
        'avio.reconnect': '1',
        'avio.reconnect_streamed': '1',
        'avio.reconnect_at_eof': '1',
        'avio.reconnect_delay_max': '5',
        'avio.rw_timeout': '15000000',
      },
    },
  );
  // Keep MDK configured for the direct FVP engine and use the stock Media3
  // plugin for Android's VideoPlayerController.
  if (androidVideoPlayer != null) {
    VideoPlayerPlatform.instance = androidVideoPlayer;
  }
}
