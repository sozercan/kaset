# ADR-0031: Saved-Album Library Identity and Reconciliation

## Status

Accepted

## Context

YouTube Music represents one saved album with two distinct identifiers:

- an `MPRE...` browse ID for album detail navigation; and
- an `OLAK...` playlist ID for add/remove Library mutations.

Library responses are also eventually consistent. A successful mutation may not
appear in `FEmusic_liked_albums` immediately, while the Library landing page
contains only a non-authoritative preview. Saved-album responses can span grid
or shelf renderers, multiple continuation chains, and partially understood
response shapes.

Treating every refresh as authoritative causes visible albums to disappear or
reappear while the backend converges. Treating `MPRE...` and `OLAK...` as the
same interchangeable identifier can also break either navigation or mutation.
Account switches add another boundary: delayed mutation or reconciliation work
from one account must never update the next account's Library.

## Decision

Saved albums use an explicit identity and reconciliation model:

1. `Album.id` preserves the canonical `MPRE...` browse identity whenever one is
   available. `Album.libraryTargetId` stores the distinct `OLAK...` mutation
   target.
2. Album equality for Library reconciliation accepts either identity, but model
   merges preserve the canonical browse ID and only merge `OLAK...` values into
   the mutation-target field.
3. Dedicated saved-album fetches are classified by provenance:
   - `.dedicated` for complete, recognized results, including a recognized empty
     collection;
   - `.partial` when pagination fails, repeats, or contains unreadable response
     shapes; and
   - `.landingFallback` when the dedicated endpoint fails.
4. Same-account `.partial` and `.landingFallback` snapshots cannot replace a
   stronger existing album snapshot. Partial data may enrich or append albums,
   while pending optimistic additions and removals remain applied.
5. Album mutations are serialized by canonical album identity across active
   Library models, while model-owned generations provide scoped cancellation.
   Playlist mutations use the same generation fence plus a shared per-playlist
   ordering tail because additions and removals reconcile across all active
   Library models. Account/auth services synchronously cancel every tracked
   Library mutation and reconciliation registry before session cookies or guest
   mode can change, so in-flight requests and delayed reconciliation cannot cross
   account/model boundaries. Library snapshots use `AccountService.currentAccountScopeID`,
   an opaque scope derived from the authenticated Google owner and selected
   YouTube identity (with an authentication-generation fallback until the owner
   is resolved). Promoting that provisional scope to a durable owner keeps the
   initially-issued in-memory identifier stable. A known owner conflict rotates
   the provisional scope and rotates again when an owner is resolved, preventing
   ambiguous-session data from joining either owner. Switching between primary
   Google accounts is therefore an account boundary too. A generation invalidates
   pending work at account or model replacement boundaries. Reconciliation checks
   that generation before and after every awaited refresh.
6. The UI disables duplicate mutation clicks only until the server accepts the
   mutation and the optimistic state is applied. Each click owns an operation
   token, so an older delayed reconciliation cannot clear a newer click's loading
   state. Delayed backend reconciliation continues without keeping the control
   disabled.
7. Cancellation is propagated through initial and continuation requests rather
   than converted into fallback or partial success.

WebViews remain limited to authentication and DRM playback. Album Library data
and mutations continue to use `YTMusicClient` API calls.

## Consequences

- Album tiles navigate with stable `MPRE...` IDs while mutations use the correct
  `OLAK...` targets.
- Temporary endpoint failures or incomplete pagination no longer erase a
  previously complete same-account album collection.
- A genuinely empty dedicated response still clears stale albums.
- Rapid opposite mutations converge according to the latest serialized intent.
- Account switches and view-model replacement cancel stale mutation work before
  it can update the next account.
- Parser and reconciliation code carry explicit provenance and generation state,
  increasing implementation complexity but making eventual-consistency rules
  testable and centralized.
