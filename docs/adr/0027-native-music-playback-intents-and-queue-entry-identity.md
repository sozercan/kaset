# ADR-0027: Native Music Playback Intents and Queue-Entry Identity

## Status

Accepted

## Context

ADR-0026 scopes JavaScript bridge events to the active Web document and media
occurrence. Native playback work has a separate race: a user action can start an
API request or schedule a corrective task, suspend, and later mutate playback
after a newer queue selection, pause, resume, or Stop.

The previous `playbackRequestGeneration` advanced only at account/privacy
boundaries. Mix, radio, playlist, album, and continuation responses therefore
remained authorized across ordinary playback changes. A delayed initial mix
could replace a newer direct queue or resurrect playback after Stop. A delayed
radio response could replace a newer queue when both selected the same video ID,
and a stale continuation could append songs or restore its token into a
replacement queue.

Video identity is also not queue-occurrence identity. Authored queues may contain
the same `Song` or video ID more than once. Matching only `videoId` can resume the
wrong occurrence, re-key the active radio seed, enrich the first duplicate, or
realign the queue to an arbitrary duplicate.

## Decision

`PlayerService` owns a monotonically increasing, opaque `MusicPlaybackIntent`.

- Valid user playback commands reserve a new intent synchronously, before
  suspension. Empty queues, invalid indices, and disappeared UUID selections are
  preflighted as true no-ops and do not supersede active playback.
  This includes direct song/video/queue playback, mix/radio selection, playlist
  and album resolution, queue-entry selection, play/pause/resume, next/previous,
  seek, Stop, restoration adoption, and queue-replacing clear/undo/redo actions.
- Work that must parse before its action is known (for example Command Bar AI
  requests) captures a non-mutating `MusicPlaybackReservation`. It can claim a
  new intent only if no newer playback action has occurred since submission.
  Queue-only commands also retain the submission-time queue generation instead
  of acquiring ownership after parsing finishes.
- Async work captures the intent that authorized it and checks ownership after
  every suspension before mutating playback, queue, continuation, persistence,
  or recovery state. Task cancellation is an optimization, not the correctness
  boundary.
- Scheduled Web queue-correction tasks capture both the intent and the expected
  `QueueEntry.id`. A newer user action or queue replacement makes the task a
  no-op before it can replay, advance, or pause newer playback. Queue-only
  mutations that retain the active occurrence may still accept its already-
  emitted terminal event.
- Rapid Media Session and native transport commands—including Next/Previous
  and relative skips—are admitted into one ordered remote-command batch under
  one intent. Later native actions invalidate the whole batch, while later
  relative commands do not cancel earlier commands. Relative skips read Web
  snapshots in FIFO order and coalesce from the last admitted seek target.
  Materialized transport transitions drain before exact-owner metadata and
  queue-maintenance follow-up; only end-of-queue target discovery is a barrier.
- Native `MPRemoteCommand` callbacks first enter a lock-backed ingress that
  captures callback sequence, wall-clock issuance, monotonic admission time,
  and scalar payload before scheduling one MainActor drain. Play, Pause, Toggle,
  Next/Previous, relative seek, and absolute seek therefore preserve callback
  FIFO, and a callback captured before a newer UI intent is rejected as stale.
- Bridge ordering uses the highest-resolution shared wall clock WebKit exposes.
  State/end events must be strictly newer than the native intent; remote commands
  may share a timestamp only inside the already-admitted batch. Ended signals are
  retried and remain occurrence-idempotent, and an explicit pause consumes a late
  end without advancing playback.
- Mix-continuation requests also have a request-owner UUID. A stale request cannot
  clear the in-flight state owned by a newer request.
- Stop, privacy clearing, restoration adoption, and every verified account
  identity transition invalidate playback, queue-load, mutation, and history
  ownership before inspecting current media. Idle requests and authenticated
  continuations therefore cannot cross accounts. Delayed destructive UI writes
  carry both account ID and session generation from snapshot capture through the
  preflight and postflight checks.
- Privacy-boundary invalidation advances the same native intent epoch; document
  and media generations remain separate Web transport boundaries.

`QueueEntry.id` is the authoritative logical occurrence identity inside a live
queue.

- Queue callers pass the exact entry ID into the internal play operation instead
  of asking `play(song:)` to rediscover identity from a video ID.
- Different entry IDs always create a fresh native occurrence even when their
  `Song` values and video IDs are identical. Reselecting the same pending/active
  entry deduplicates into resume. A direct video-ID request detaches queue and
  episode ownership, starts a fresh native occurrence, clears stale restored
  load state, installs the requested pending/current identity before resume,
  and refreshes detached metadata even when the already-loaded Web media can be
  resumed in place.
- Radio expansion preserves the existing seed entry ID.
- Metadata fetches and background enrichment capture an entry ID and relocate it
  by UUID after suspension; they never update the first matching video ID.
- Web-reported drift may realign to a unique matching queue entry. Ownership,
  visible track metadata, and persistence are updated in that order. If multiple
  entries share the observed video ID, Kaset retains and reasserts native queue
  ownership rather than selecting the first duplicate.
- Queue transformations preserve entry IDs for rows they retain. Duplicate
  removal retains the active occurrence (or stopped current cursor) at the first
  video-position slot instead of transferring ownership to a different duplicate;
  unrelated replacements clear ownership. The destructive whole-queue API always
  stops playback first; `clearQueue()` remains the distinct preserve-current-track
  operation.
- UI selection, delayed removal, context menus, swipe actions, drag payloads, and
  scripting resolve rows by UUID. A stale displayed index cannot mutate a newer
  row after insertion or reorder.
- Undo/redo replays the exact restored entry, physical media clock, transport
  intent, mix continuation, pre-shuffle authored order, and detached artist-
  episode identity before persisting; live episodes return to the live edge rather
  than entering fixed-clock restoration, and paused intent is installed before
  any replacement navigation can capture autoplay. Ended restores synchronously
  derive video availability from the restored song. The outgoing undo/redo state
  is captured before playback-context reset so redo cannot lose the pre-shuffle
  authored permutation. History is structural: it strips account-scoped
  rating/library fields and refreshes the restored owner instead of
  replaying stale action tokens. Playback intent gates admission/restoration;
  once the queue is installed, queue generation owns structural finalization so
  pause/resume/seek cannot orphan persistence or Smart Shuffle rearming. Adopting
  a persisted session clears prior live history, and history restore downgrades
  Smart Shuffle when its feature setting is disabled.
  Detached playback is persisted as its own
  singleton occurrence instead of attaching its clock to an unrelated valid
  queue index.
- Metadata merging preserves the logical song identity and already-complete
  display fields. Account metadata is sanitized at identity boundaries; active
  refreshes update complete rows, while background enrichment never imports
  rating/library tokens.
- Rating and library mutations carry latest-operation revisions and are serialized
  per account/video so both local state and server write order follow the newest
  user intent. The predecessor/tail is registered synchronously at submission,
  before any unstructured completion task can begin, so rapid toggles cannot
  reverse backend write order. Session-generation fences prevent stale identity
  completions from repopulating account-scoped confirmed rollback baselines, and
  a matching post-mutation refresh promotes authoritative server action tokens.
  Metadata reads cannot promote library fields while that account/video/session
  has a pending serialized mutation. Library membership and action tokens fan out
  to every duplicate occurrence of the same account/video while display metadata
  remains exact-entry scoped.
- Shuffle mode and duplicate-safe authored order are part of queue history and
  persisted playback sessions, not merely global preferences.

Runtime entry UUIDs remain in-memory only. Persisted queue index continues to
identify the selected duplicate across launches, while an optional pre-shuffle
permutation preserves every non-active duplicate occurrence payload. UUID
persistence is not needed.

## Consequences

- Delayed mix, radio, playlist, album, and continuation work cannot replace a
  newer direct queue or resurrect playback after Stop.
- Native corrective tasks cannot pause, replay, or advance after a newer intent.
- Rapid remote transport commands remain deterministic, and a pause/end race
  cannot restart Music while regular YouTube owns playback.
- Duplicate video IDs remain distinct queue occurrences throughout playback,
  radio expansion, metadata enrichment, and Web drift reconciliation.
- Internal playback methods accept an intent and optional queue-entry ID, while
  existing public APIs remain source-compatible wrappers that reserve intent.
- Queue-only pagination still uses its queue-load generation so a simple pause
  need not discard already-committed playlist continuation loading.
- Command Bar ownership is submission-scoped, streaming partials are request-ID
  scoped, and hard timeouts do not await cancellation-insensitive model work.
- This decision does not replace ADR-0026 document/media generations and does not
  claim that a requested video ID proves ready physical media. Authoritative
  requested/in-flight/observed media readiness and pending-control routing remain
  a separate follow-up concern.
