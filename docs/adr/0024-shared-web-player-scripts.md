# ADR-0024: Shared Web-Player Scripts Across Music and YouTube Playback

## Status

Accepted

## Context

ADR-0020 introduced regular-YouTube playback as a stack deliberately parallel
to YouTube Music: separate API clients, models, observers, and a second
playback WebView (`YouTubeWatchWebView`) alongside the music one
(`SingletonPlayerWebView`). The guiding rule was *"parallel everything; share
only what is provably origin-neutral."*

That rule was correct, but it was applied conservatively — nothing was shared
between the two playback WebViews at all. As a result several primitives that
have **nothing to do with origin** ended up duplicated byte-for-byte (or nearly
so) across the two stacks:

- The `__kasetTargetVolume` bootstrap line and its `0...1`/non-finite clamp.
- The basic `<video>`-element commands `play` / `pause` / `seek` (the music
  variants also carried `return` strings that no caller ever read — every call
  site uses `completionHandler: nil`).
- `WKWebView` reparenting (`ensureInHierarchy`) — identical autoresizing logic.
- Content-process crash recovery — reload, then re-load the tracked video after
  a one-second beat.

Duplicated code drifts. Two copies of "set the video's volume target" or "walk
the WebView back into its container" are two things to fix when one breaks.

## Decision

Extract the **origin-neutral** playback primitives into a single
`WebPlayerScripts` enum (plus a `WKWebView.reparent(into:)` extension) that both
playback WebViews compose from. What counts as origin-neutral is concrete: it
operates on a generic HTML `<video>` element or on the `WKWebView` host, with no
`ytmusic-*` or `ytp-*`/`#movie_player`-specific DOM knowledge.

Shared:

- `WebPlayerScripts.clampVolume` / `targetVolumeBootstrap` — one volume policy.
- `WebPlayerScripts.play/pause/seek(_: VideoElement)` — the `VideoElement` enum
  carries the only real difference, the element accessor expression
  (`document.querySelector('video')` for music vs the `#movie_player video`
  preference for YouTube).
- `WKWebView.reparent(into:)` — the shared hosting move.
- `WebPlayerScripts.recoverFromContentProcessTermination` — the shared recovery
  shape, parameterized by closures over each singleton's tracked-id state.

Explicitly **not** shared (the divergence is real, not incidental):

- The two observer scripts (`STATE_UPDATE` shapes, `ytmusic-player-bar` vs
  `getVideoData()`/ad detection, autoplay-recovery and lyrics polling).
- `playPause` (music clicks the YT-Music player-bar button first to keep that
  app's own queue in sync; YouTube toggles the element directly).
- `setVolume` (music drives the `ytmusic-player` API and never unmutes; YouTube
  unmutes and drives `movie_player`, with a different debounce).
- The video-surface **extraction scripts**. Both use the same ancestor-chain
  `.kaset-visible` technique, but the surrounding CSS (caption whitelists,
  `ytp-chrome-*` hiding, cursor restoration), the activation wrapper
  (`window.__kasetExtractVideo()` vs inline), and YT-Music's
  `playerPage.videoMode` forcing make a faithful single builder leakier than the
  duplication it would remove. Kept parallel by design.

This extends ADR-0020's principle rather than reversing it: the sharing is
limited to what is *provably* origin-neutral, and the proof is mechanical —
`WebPlayerScriptsTests` pins the generated JS, and the pre-existing
`AutoplayRecoveryTests` / `YouTubeWatchScriptTests` continue to pin each path's
composed output.

## Consequences

- One source of truth for volume policy, generic video commands, reparenting,
  and crash recovery. A fix lands once.
- The music path was touched, but behavior-preservingly: the only removed code
  was the provably-dead `return` strings in `play/pause/seek`. Golden tests
  guard the composed output of both paths.
- Future origin-neutral primitives have an obvious home. The observers,
  `setVolume`, and the extraction scripts remain intentionally separate; a
  future ADR would be needed to justify sharing any of those.

## Follow-ups implemented

After the shared layer landed, a feasibility study evaluated borrowing the
richer regular-YouTube video features onto the music side. A runtime probe
(temporary, launch-arg-gated) against the live in-app `#movie_player` on
music.youtube.com confirmed:

- **Quality levels are real and selectable.** The music player reports the same
  identifiers as YouTube (`hd720/large/medium/small/tiny/auto`) and
  `setPlaybackQualityRange` actually changes the resolution (not a no-op).
- **Captions are empty.** `getOption('captions','tracklist')` returned no tracks
  for OMVs across retries in the `WEB_REMIX` player, so a music caption picker
  was **not** built.

Two features were borrowed onto the music video path, both additive and leaving
the audio path untouched:

1. **Native fullscreen** for the floating video window — `VideoWindowController`
   switched to `.fullScreenPrimary` with a `toggleFullscreen()` and a
   hover/`⌃⌘F`/double-click affordance, mirroring `YouTubeVideoWindowController`
   (minus the inline-return branch the music path has no surface for). Tradeoff:
   the window no longer floats over other apps' fullscreen spaces.
2. **Resolution picker** — `SingletonPlayerWebView+VideoQuality` ports the
   YouTube player-API quality JS verbatim (same `#movie_player`),
   `PlayerService+VideoQuality` owns the per-track state, and `PlayerBar` shows a
   gearshape menu reusing `YouTubeQuality.displayName`. The Swift state mirrors
   `YouTubePlayerService`'s, but the two playback services stay parallel.
   Discovery is keyed to the active `videoId` (via a `MusicVideoQualitySource`
   seam, behind `refreshVideoQualityOptionsIfNeeded()`), not to the
   video-window-open transition — so the menu repopulates when the track changes
   while video mode stays open, and the per-video guard latches only after a
   successful fetch so a not-yet-ready player retries. (An adversarial review
   caught the original showVideo-transition-keyed version, which could leave the
   menu permanently empty for subsequent or slow-loading videos.)
