# ADR-0026: Shared Now-Playing Mix Tracklist Provider

## Status

Accepted

## Context

Long "mix" videos (continuous DJ sets, radio-style uploads) have a sub-track
breakdown (`MixTracklist`) parsed from their description / watch-next data. That
parsing already existed, but lived inside `ScrobblingCoordinator` as a
scrobbling-private detail: it drove per-sub-track scrobbles and only ran when a
scrobble service (Last.fm) was connected.

The segmented seek bar — a YouTube-style progress lane that splits into one
segment per sub-track — needs the same per-sub-track data, independent of
scrobbling. Re-parsing inside the view layer would duplicate network fetches,
risk the two consumers diverging on "is this a mix / what are its sub-tracks",
and couple a pure-playback UI feature to the scrobbling subsystem.

There is also a timing hazard: YouTube reports a video's duration a beat after
the track object appears, and a duration value can briefly leak across a video
change. The mix-detection floor (a video must be ≥ 10 min to be a mix worth
segmenting) must be evaluated against the duration that provably belongs to the
current video, or a short track can inherit a previous mix's duration and be
mis-segmented.

## Decision

Extract tracklist ownership into a dedicated `@MainActor @Observable`
`NowPlayingTracklistProvider` in the Player layer, as the single source of truth
for "what are the sub-tracks of the now-playing video."

- The provider is **driven** by `PlayerService` (`update(track:duration:)` on
  every track/duration change) but owns all fetch policy: a once-per-video latch,
  the `minMixDuration` (600s) gate, and cancellation of in-flight parses on video
  changes.
- It is **decoupled from scrobbling**: the fetch runs regardless of whether a
  scrobble service is connected, because mix segmentation is a playback concern.
- Both consumers read the same provider — the segmented seek bar
  (`PlayerBar` → `PlayerBarProgressLane`) always, and `ScrobblingCoordinator`
  when connected.
- A single `MixTracklistParser` (with in-flight fetch coalescing) is shared
  between the provider and the coordinator, wired once in `KasetApp`.
- Duration is provenance-correlated to its originating video so the mix gate
  cannot be tripped by a duration belonging to a different track.

## Consequences

Easier:

- One source of truth; the seek bar and the scrobbler cannot disagree about the
  now-playing tracklist.
- Segmentation works with scrobbling off; the UI feature no longer depends on
  Last.fm being connected.
- Coalesced parsing means the two consumers requesting the same video share a
  single fetch instead of racing two.
- Clean degradation: no tracklist → the existing single-track lane renders
  unchanged; live streams are skipped.

More difficult / to watch:

- Adds a shared observable service to the Player layer whose lifecycle and
  ownership must be managed (a single instance in `KasetApp`, injected into both
  the player and the coordinator).
- The once-per-video latch, duration gate, and provenance correlation are subtle;
  the race between duration settling and the mix gate is guarded by
  `NowPlayingTracklistProviderTests` and must stay covered when the drive path
  changes.
