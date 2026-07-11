# ADR-0026: Gapless Playback via YouTube Music Native Queue

## Status

Accepted

## Context

Kaset plays YouTube Music through a singleton hidden `WKWebView` because DRM-protected
YouTube Music audio cannot be played through `AVPlayer`. Before this change, queue
advancement usually meant navigating the WebView to a new `watch` URL for every
track. That approach had two user-visible problems:

- a full page navigation could leave several seconds of silence between tracks;
- YouTube Music autoplay could briefly win the race and start an unrelated track
  before Kaset corrected back to its local queue.

Users reported this as both a gapless-playback feature request and a playback bug:
queued next tracks did not reliably start when the current track ended or when the
user pressed Next.

A native audio engine is not available for YouTube Music, so the realistic goal is
not sample-perfect gapless playback. The goal is to avoid unnecessary WebView page
reloads and let YouTube Music's own player perform the transition whenever Kaset
can safely keep YouTube Music's native queue aligned with Kaset's queue.

## Decision

Kaset keeps its local queue as the source of truth, but mirrors the next expected
track into YouTube Music's native **Up Next** queue ahead of time.

- `SingletonPlayerWebView` preloads the YouTube Music app shell after login so
  subsequent loads can prefer in-page router navigation over full page loads.
- `loadVideo(videoId:)` first tries YouTube Music's internal SPA router with a
  `watchEndpoint`; it falls back to a full `watch` URL only when the router is not
  available or rejects the command.
- `PlayerService+WebQueueSync` calls `syncWebQueue()` only when playback is in a
  stable state (`.playing` or `.paused`) and no main-document navigation is in
  progress. A navigation completion retries synchronization when playback had
  already started before `WKNavigationDelegate.didFinish`.
- `SingletonPlayerWebView+QueueInjection` opens the current player-bar menu,
  positively identifies **Play next**, temporarily replaces its native
  `queueAddEndpoint` target, invokes the menu item's own click path, and restores the
  endpoint immediately afterward. The script waits briefly for the player-bar action
  menu to mount after SPA navigation instead of treating the first missing DOM node
  as a permanent injection failure.
- Before dispatch, the menu endpoint's source video ID must still match Kaset's
  current queue song. The page preserves rendered queue-row occurrences, accepts an already aligned queue without clicking again, otherwise requires a
  post-click queue change, and reports success only when the expected target becomes
  the row immediately after the rendered selected source row. If that current row is
  absent, stale, duplicated, malformed, or otherwise unconfirmed, the attempt fails closed.
- Swift tracks queue injection as two separate states:
  - `pendingWebQueueInjectionVideoId`: an injection attempt has started but the
    WebView has not confirmed it;
  - `injectedWebQueueVideoId`: the WebView confirmed that the source-bound **Play
    next** click inserted the currently expected next track.
- `handleTrackEnded(observedVideoId:)` starts a bounded native handoff only when
  the readback-confirmed injected video ID still matches the expected next entry.
  The outgoing song remains visible until the media-bound observer reports that
  exact target. A wrong video or a three-second timeout falls back through
  `play(song:)` / `loadVideo(videoId:)`.
- Radio-queue enrichment preserves the active queue-entry UUID so replacing API
  metadata does not look like a new playback occurrence to the media-generation guard.
- A queue edit during a pending native handoff revalidates source/target UUID
  adjacency. If adjacency changes, Kaset deterministically loads the newly expected
  next entry rather than the stale target.
- Main-document completion/failure callbacks are matched to the latest `WKNavigation`
  and current `WKWebView` before they clear the injection gate.
- Any deterministic navigation, queue replacement, empty queue persistence, or stale
  result clears both Swift-side and page-side queue-injection state.
- Hidden preload and restored-session pages start with autoplay blocked. Explicit
  user actions such as Resume/Next/Previous unblock autoplay.

## Consequences

### Positive

- Queue transitions can be handled by YouTube Music's own player without reloading
  the whole WebView page for every track.
- Manual Next/Previous stay aligned with Kaset's queue through deterministic
  navigation, while natural track-end handling uses native web-player transitions
  only after both queue readback and actual media identity are confirmed.
- Duplicate tracks, stale `ended` events, failed injection attempts, queue edits,
  repeat modes, and mix/smart-shuffle continuation boundaries have explicit guard
  paths and regression tests.
- If native injection fails or becomes stale, playback correctness wins over
  gaplessness: Kaset performs a deterministic load instead of trusting the web
  queue blindly.

### Negative / Risks

- The queue-injection path depends on YouTube Music DOM structure and command
  payload shape, especially the player-bar menu and **Play next** command.
- The implementation uses YouTube Music's internal `queueAddEndpoint`, menu-click,
  and queue-renderer contracts, which are more fragile than a public API would be.
- Command dispatch no longer rewrites arbitrary YouTube Music JSON payloads.
- Real-world gaplessness still depends on YouTube Music buffering, WebKit timing,
  network state, and YouTube's internal player behavior.
- The code must carefully cancel stale page-side injection attempts when Swift
  state changes, because same-document SPA navigation keeps JavaScript globals
  alive.

## Validation

The implementation adds/updates regression coverage in:

- `PlayerServiceWebQueueSyncTests`
- `PlayerServiceWebQueueSyncFollowUpTests`
- `PlaybackObserverIdentityTests`
- `QueueInjectionScriptTests`
- `PlayerServiceQueueTests`
- `AutoplayRecoveryTests`
- `PlayerServiceLibraryTests`

The covered cases include queue readback confirmation, stale injection results,
duplicate video IDs, navigation races, native handoff confirmation/wrong-track/timeout
fallbacks, active queue-entry identity preservation, empty/edited queues, manual
Next/Previous, repeat modes, restored playback seeks, autoplay blocking, and
account-scoped like/dislike completion races.
