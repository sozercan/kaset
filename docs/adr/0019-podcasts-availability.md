# ADR-0019: Region-Aware Podcasts Tab Visibility

## Status

Implemented, amended 2026-08-29

## Context

YouTube Music does not offer the **Podcasts** discovery surface in every
region. In unsupported regions the `FEmusic_podcasts` browse endpoint
returns HTTP 404 (confirmed via
`swift run api-explorer browse FEmusic_podcasts -v` from a Turkish IP —
clean `HTTP 404` with `"status": "NOT_FOUND"`), and the YT Music web client
itself redirects `music.youtube.com/podcasts` to home in those regions.

Kaset previously rendered the Podcasts row in the sidebar unconditionally.
Users in unsupported regions saw `Server Error — Something went wrong (Error
404)` whenever they opened the tab (issue
[#100](https://github.com/sozercan/kaset/issues/100)). Region is determined
by YouTube from cookies/IP, not by the `hl` parameter, so the app cannot
override it client-side.

Other podcast surfaces are gated separately and continue to work in
unsupported regions:

- `LibraryView` *Podcasts* filter — uses `FEmusic_library_non_music_audio_list`.
- `SearchViewModel` *Podcasts* filter — search-podcasts works (commenter on
  issue #100 confirmed).
- `ArtistDetailView` podcasts section — already gated by
  `!detail.podcasts.isEmpty`.

So the fix is scoped to the discovery tab only.

## Decision

Add a `PodcastsAvailabilityService` (`@MainActor @Observable`) that probes
`FEmusic_podcasts` once per session and exposes the result to the sidebar
through the SwiftUI environment. The probe runs after the initial account is
resolved but does not gate main-window rendering. Authenticated rendering waits
up to 2 seconds for account resolution, then fails open with the primary-account
scope while the account request continues. State is **in-memory only** and every
cold launch re-probes from scratch.

### State machine

```
.unknown     --available signal----> .available
.unknown     --unavailable signal--> .unavailable
.available   --unavailable signal--> .unavailable
.unavailable --available signal----> .available
```

Where:

- **Available signal**: probe success with `≥1` section, or
  `markAvailable` from a user-initiated non-empty load.
- **Unavailable signal**: probe HTTP 404, user-initiated load HTTP 404,
  or user-initiated load returns empty.

Successful signals can therefore promote `.unavailable` back to
`.available` after an account/region change; unavailable signals can also
remove the tab from either `.unknown` or `.available`.

While availability is `.unknown`, the sidebar renders the Podcasts row. A
definitive 404 removes it. This optimistic state keeps the podcasts network
request off the startup rendering path, at the cost of a brief row removal in
unsupported regions.

### No persistence

The service's state lives only in memory. Trade-offs considered:

- **+** Region changes (e.g. enabling a VPN) are picked up by quitting
  and relaunching the app — no sign-out/in dance and no cache to
  invalidate.
- **+** No schema versioning, no TTL, no per-account cache lifecycle to
  reason about.
- **−** One extra `browse` request per cold launch. It runs in parallel with
  personalized content loads and warms `APICache`, so opening the tab after
  launch is immediate in available regions.

A persistent cache keyed by `accountId` with a TTL on `.unavailable`
was considered but rejected — see *Alternatives*.

### Detection rules

- **Authoritative**: `YTMusicError.apiError(code: 404)` from
  `client.getPodcasts()`, whether raised by the background probe or a
  user-initiated `PodcastsViewModel.load`.
- **Authoritative**: success with non-empty sections → `.available`.
- **Secondary** (lazy path only): a user-initiated load that returns zero
  sections. Empty payloads are noisy from the probe path (cold caches,
  transient YT issues), so we only trust them when the user has actively
  visited the tab. A background probe with empty sections leaves
  `availability` untouched.
- **Ignored**: 5xx, network errors, auth errors. Transient failures must
  never demote a known-good state.

### Probe lifecycle (in `MainWindow`)

- **First probe**: a task keyed to the authentication generation and resolved
  account ID fires after the account-list request restores the selected primary
  or brand account. The main window waits up to 2 seconds for that resolution,
  then renders against the primary-account scope if the request is still pending.
  After account resolution and a 200 ms cookie-settle delay, the task awaits
  `service.probe(...)`.
- **Account switch**: changing the account ID cancels and restarts the same
  SwiftUI task. `mainContent` stays visible while content refreshes, so the
  sidebar can briefly show the prior account's tab state until the probe returns
  a definitive answer. The service's generation check rejects late results from
  an older account.
- **Logout**: `service.reset()` clears `availability`. The next sign-in
  re-probes after account resolution.
- **`refreshAllContent`**: skips the podcasts viewmodel refresh when
  `availability == .unavailable` to avoid re-firing the spurious 404.

### UI integration

- **`Sidebar.swift`** renders the Podcasts `NavigationLink` only when
  `availability != .unavailable`.
- **`MainWindow.swift`** renders authenticated content after account
  resolution, or after a 2-second fail-open deadline, without waiting for the
  podcasts probe. A late account result uses the existing account-switch refresh
  path. Post-login and reauthentication refreshes observe the same deadline so
  they do not fetch primary-account content while brand restoration is pending.
  The window redirects `navigationSelection = .home` if availability flips to
  `.unavailable` while the user is on the Podcasts tab.
- **`PodcastsViewModel.load()`** on `apiError(code: 404)` calls
  `service.markUnavailable(for:)` and lands on `.loaded` with empty
  sections instead of `.error`. The sidebar row disappears within a frame,
  so a generic toast would be wrong; a clean empty state is the softer
  landing.

## Consequences

**Positive**

- Users in regions without podcasts no longer see a 404 toast and lose the
  dead tab automatically.
- Region changes via VPN are picked up on the next app launch — no
  account/session manipulation required.
- The podcasts probe no longer delays authenticated content rendering.
- A stalled account-list request can delay authenticated rendering by at most
  2 seconds. A late brand-account result refreshes content after it arrives.
- Other podcast features (library subscriptions, search, artist pages)
  remain fully functional because they're gated separately.
- No new third-party dependencies. No persistence-layer surface area.

**Negative**

- One extra `browse` request per cold launch. Mitigated by parallelism
  with the existing post-login refreshes and by `APICache` warming for
  available regions.
- Unsupported regions can briefly see the Podcasts row before the 404 probe
  removes it.

**Neutral**

- `SettingsManager.LaunchPage` already excludes `.podcasts`, so default-tab
  logic needed no changes. `lastUsedPage` is typed as `LaunchPage` and
  cannot become podcasts.
- Keyboard navigation commands (⌘1/2/3/F/K) and the command bar do not
  reference podcasts.

## Alternatives considered

- **Lazy-only (no proactive probe)**: simpler, but the Podcasts row
  would show on the first session in an unsupported region until the
  user clicked it and saw the 404. The background probe removes the row
  without requiring that failed interaction.
- **Probe via a custom HEAD/exists endpoint**: not worth a separate
  code path; reusing `getPodcasts()` warms `APICache` on success.
- **Persisted cache keyed by `accountId` with a TTL on `.unavailable`**:
  would avoid the per-launch probe cost, but the cache key is
  fundamentally wrong for this signal. Region (`gl`) — not account — is
  what gates the endpoint, and YouTube derives `gl` from cookies. A
  user can change region without changing account (e.g. by toggling a
  VPN), and there's no client-visible signal we could use to invalidate
  the cache when that happens. The result would be that
  *connect-VPN-then-relaunch* becomes *connect-VPN, sign out, sign in*
  — strictly worse UX than re-probing on launch. The per-launch probe
  is also nearly free thanks to `APICache` warming and parallelism with
  the existing post-login refreshes, so the cache would buy us very
  little even when correct.
- **Persisted cache keyed by `(accountId, languageCode)`**: same
  fundamental problem as the per-account cache — language is a poor
  proxy for region (YT derives `gl` from cookies). Worse, it would
  force unnecessary re-probes on every locale toggle while still
  missing the VPN case.
- **Use `gl` from `Locale.current`**: same problem — the user's macOS
  region setting is independent of YouTube's account region.
