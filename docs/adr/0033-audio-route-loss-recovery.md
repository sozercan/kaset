# ADR-0033: Audio Route Loss Recovery and Now Playing Ownership

## Status

Implemented

## Context

Media keys (F8) stopped controlling playback after Bluetooth headphones disconnected and
reconnected. Clicking Play in Kaset's window restored them. The behavior was reproduced with a
timestamped file trace (see `docs/common-bug-patterns.md`) rather than inferred; three separate
defects turned out to stack.

### 1. WebKit's Now Playing session survives a route loss as a zombie

WebKit registers its own Now Playing client with the system, independent of the app's
`MPNowPlayingInfoCenter`. When the audio route disappears, that registration outlives the media
session it described: Control Center still shows its card, and the card still captures the media
keys — but its transport actions do nothing. Pressing the card's own play button is a no-op,
while Kaset's card next to it works.

The registration cannot be withdrawn from the app side. Clearing `navigator.mediaSession`
metadata and `playbackState` was tried and only blanks the card's contents; WebKit keeps the
registration as long as a media element that has played still exists. The only thing that
rebinds the session to a live route is playback actually running again — which is exactly what
the manual "click Play" workaround did.

### 2. A route-loss pause was recorded as a deliberate user pause

macOS stops playback on a vanished route by sending the app an ordinary `pause` remote command,
indistinguishable from the user pressing Pause. Kaset's handler set
`isExplicitPauseIntentActive`, whose purpose is to stop YouTube's autoplay from overriding a
user's pause. With it set, `applyObservedPlaybackState` re-pauses the page the instant anything
resumes it — so even a media key that did reach a healthy session started playback and had it
killed a moment later.

### 3. The native Now Playing claim could never be released

`NowPlayingManager` published a tagged minimal claim while paused so media keys still reached
Kaset (ADR-less, from #387). Its hands-off branch waited for "WebKit to atomically replace the
app-wide metadata" before standing down. WebKit never does that — it does not write
`MPNowPlayingInfoCenter` at all — so the claim was never withdrawn and Kaset kept a second,
permanently stale Control Center entry once it had paused even once.

## Decision

**Resume playback when the audio route returns**, scoped precisely to playback the route loss
itself stopped. This restores what the user was listening to and, as a direct consequence,
rebinds WebKit's media session so the media keys work again for everything afterward.

Supporting decisions:

- **Classify the pause at its source.** `MusicPauseOrigin` distinguishes `.user` from
  `.routeLoss(at:)`. Only a user pause records the standing intent to stay paused.
- **Identify a route loss by a device disappearing**, not by any output change. A manual output
  switch or a device being added must not arm recovery. `DefaultOutputDeviceMonitor` remembers
  the previous default device and checks both device-list membership and
  `kAudioDevicePropertyDeviceIsAlive` — Core Audio can mark a device dead before dropping its
  ID.
- **Attribute from both sides.** Core Audio's listener timestamps a change immediately but only
  publishes it after several synchronous device queries, while the `pause` it provokes drains
  independently. Either can win. A pause that arrives first is treated as the user's but keeps
  its admission instant, and the route event re-attributes it when it lands — the route event is
  the thing that arrives late, not the pause. Classifying only at admission would leave the
  explicit-pause intent set with no way to undo it, which is precisely the original failure.
- **Anchor timing to command admission.** Remote commands drain onto the MainActor
  asynchronously, so both the classification window and the recovery marker use the ingress
  admission instant. Dating either to handling time lets a busy main actor misclassify a real
  route pause, or sort the marker after a reconnect that already happened.
- **Bound recovery by intent, not by a timer.** The marker is retired by a user pause or by
  playback actually starting — never by elapsed time. A resume can therefore only ever continue
  exactly what the route loss interrupted, so reconnecting an hour later is still the same
  interrupted song. It deliberately survives *issuing* a resume so the second attempt can retry
  while the route is still settling.
- **Release the native claim whenever WebKit owns the card**, since the event it was waiting for
  does not exist.

## Consequences

### Positive

- Media keys work after a Bluetooth disconnect/reconnect without touching the app.
- Reconnecting headphones continues the interrupted track, matching AirPods behavior elsewhere.
- Exactly one Control Center entry during playback instead of a stale duplicate.

### Negative

- Playback restarts on its own when a route returns. This is a deliberate behavior change; it is
  narrowly scoped to a pause the system imposed, and any user transport action retires it.
- Classification rests on a 1.5s correlation window between a device disappearing and the `pause`
  command (measured at 40–60ms). It is a heuristic, not a signal the OS provides.

### Out of scope: the YouTube video source

Only the music player recovers. When `PlaybackArbiter` routes media keys to
`YouTubePlayerService`, the same system pause still reaches `handleRemotePause` unclassified, no
recovery marker is recorded, and reconnecting cannot rebind that video's WebKit media session —
so the media-key failure described above remains for video playback.

This is a gap, not a regression: nothing about the video path changed. It is left out because it
needs its own recovery marker and resume path in a separate service, and none of it could be
verified against the reproduction that drove this work, which was music-only. Shipping an
unverified parallel implementation alongside a verified one was judged worse than recording the
gap. It deserves its own change, reproduced and traced the same way.

### Known limitation

`DefaultOutputDeviceMonitor` watches only which device is the *default output*. A route change
within one device — some Macs expose speakers and the headphone jack as data sources on the same
built-in device — leaves that selection untouched and goes unseen, so recovery does not arm.
Covering it requires listening on the current device's output data source and retargeting those
listeners on every default-device change. Bluetooth always swaps the device itself. A missed
change degrades to the previous behavior rather than misbehaving.

## References

- ADR-0001: WebView-Based Playback
- ADR-0026: Generation-Scoped Web Playback Bridge
- `docs/common-bug-patterns.md` — the trace workflow that localized this
