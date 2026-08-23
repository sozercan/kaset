# ADR-0029: Shared Now-Playing Mix Tracklist Provider

## Status

Accepted

## Context

Long "mix" videos (continuous DJ sets, radio-style uploads) have a sub-track
breakdown (`MixTracklist`) parsed from their description / watch-next data. That
parsing already existed, but lived inside `ScrobblingCoordinator` as a
scrobbling-private detail: it drove per-sub-track scrobbles and only ran when a
scrobble service (Last.fm) was connected.

The segmented seek bar — a YouTube-style progress lane that splits into one
segment per sub-track — needs the same parsed per-sub-track data, independent
of scrobbling. Re-parsing inside the view layer would duplicate network
fetches and couple a pure-playback UI feature to the scrobbling subsystem.
The scrobbler still needs its own classification lifecycle for unknown-duration
fallbacks, provisional playback credit, timeouts, and post-exit finalization.

There is also a timing hazard: YouTube reports a video's duration a beat after
the track object appears, and a duration value can briefly leak across a video
change. The mix-detection floor (a video must be longer than 10 minutes,
strictly `> 600s`, to be a mix worth segmenting) must be evaluated against the
duration that provably belongs to the current video, or a short track can
inherit a previous mix's duration and be mis-segmented.

## Decision

Extract current-item playback-UI tracklist ownership into a dedicated
`@MainActor @Observable` `NowPlayingTracklistProvider` in the Player layer. It
is the segmented seek bar's source of truth for "what are the sub-tracks of the
now-playing video."

- The provider is **driven** by `PlayerService` (`update(track:duration:)` on
  every track/duration change) but owns all fetch policy: a once-per-video latch,
  the `minMixDuration` (600s) gate, and cancellation of in-flight parses on video
  changes.
- It is **decoupled from scrobbling**: the fetch runs regardless of whether a
  scrobble service is connected, because mix segmentation is a playback concern.
- The segmented seek bar (`PlayerBar` → `PlayerBarProgressLane`) consumes the
  provider. `ScrobblingCoordinator` intentionally retains its own detection
  state machine because it must preserve provisional credit, resolve unknown
  durations, enforce parse timeouts, and finalize tracks after playback exits.
- A single `MixTracklistParser` (with cache and waiter-aware in-flight fetch
  coalescing) is shared between the provider and the coordinator, wired once in
  `KasetApp`. They share parsed data and network work, not classification state.
- Only duration observed with the current physical video identity may trip the
  provider's irreversible mix gate; `Song.duration` remains fallback metadata
  for reversible uses such as persistence.

## Consequences

Easier:

- One current-item source for seek-bar segmentation, while the scrobbler keeps
  the richer lifecycle needed for accounting and finalization.
- Shared parser results prevent duplicate network work and keep both consumers
  on the same parsed chapter/description payload when they request a video.
- Segmentation works with scrobbling off; the UI feature no longer depends on
  Last.fm being connected.
- Coalesced parsing means the two consumers requesting the same video share a
  single fetch instead of racing two.
- Clean degradation: no tracklist → the existing single-track lane renders
  unchanged; live streams are skipped.

More difficult / to watch:

- Adds a shared observable service to the Player layer whose lifecycle and
  ownership must be managed (a single instance in `KasetApp`, injected into the
  player and view hierarchy).
- Provider and scrobbler can resolve classification at different times or under
  different duration-evidence rules; their responsibilities must remain clearly
  documented even though they share the parser.
- The once-per-video latch, duration gate, and provenance correlation are subtle;
  the race between duration settling and the mix gate is guarded by
  `NowPlayingTracklistProviderTests` and must stay covered when the drive path
  changes.
