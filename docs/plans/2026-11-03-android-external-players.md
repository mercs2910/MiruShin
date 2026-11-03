# Android external playback

User-approved scope: open videos from MiruShin in Vimu or MX Player, retain
episode progress and resume position, and preserve opening/ending skipping
where the external player supports Android media controls.

The user subsequently confirmed both progress requirements and authorized
running all tests directly, starting with the internal patched player and then
the external players. Include a device-local internal software-decoding choice
to bypass the stalled Realtek codec while retaining the full internal feature set.
This is the agreed design lock (brainstorming light mode); implementation follows.

The user later clarified that reliable hardware decoding should be the priority;
software decoding remains a fallback. Vimu and MX hardware paths have already
played past the original failure window. Add an isolated internal hardware-copy
compatibility experiment and verify actual `hwdec-current`, not just the selected
setting. This preserves the internal player controls while testing a different
frame transfer path; it does not claim to repair the closed Realtek driver.

## Evidence

- RockTek/Skyworth RTD1325, Android 14, armeabi-v7a, MiruShin 2.9.24.
- H.264 720p playback repeatedly stalls after roughly 2–3 minutes.
- Realtek `DequeueLoop` uses an entire CPU core and repeatedly reports
  `mOutputBuffers is empty(1000)`; it stays busy while playback is paused.
- Closing the internal player releases the stalled decoder.
- Memory remains available and there is no reported thermal throttling.
- Fixed 23.976 Hz and Android's unrestricted match-frame-rate preference both
  failed. Original display preferences have been restored.
- Both external players document activity results with resume position.

## Decisions

1. Keep existing internal playback and desktop behavior as defaults.
2. Store the Android external-player choice locally, outside Drive-synced
   player settings, so choosing a TV player does not change the Mac player.
3. Treat external playback as a player engine and reuse MiruShin's checkpoint,
   watched threshold, skip-marker and next-episode logic.
4. Never initialize an internal decoder or thumbnail decoder for external
   playback. Pass the selected stream and its headers to the chosen player.
5. Explicitly target MX Player's playback activity and request activity results.
   Use Vimu's documented `startfrom` and completion/interruption result codes.
6. Observe only the selected external player's Android media session, after
   the user grants notification-listener access. Use confirmed media position
   and supported transport commands for periodic saves and automatic skips.
7. Persist a small native checkpoint every five seconds. On app/process restart,
   replay it into the existing library only for the matching account workspace;
   acknowledge it only after a successful database save.
8. A hard power loss can recover the last durable checkpoint, not a guaranteed
   exact final frame. Never invent progress or completion after a missing result.
9. Build a separately named/package test APK. Keep the installed production app
   and its data available for comparison. Do not include user data in source/CI.
10. Verify real playback for longer than the original failure interval, normal
    return position, reopening, completion, process interruption, and supported
    opening/ending skips on the actual Android box.

Primary API references:
- https://vimu.tv/player-api/
- https://sites.google.com/site/mxvpen/api

## Build

This Mac has no Flutter SDK, Android SDK, or Java runtime installed. Prepare
the minimal patch locally and use an isolated fork/branch and manual GitHub
Actions job to run Flutter checks and build the diagnostic APK.
