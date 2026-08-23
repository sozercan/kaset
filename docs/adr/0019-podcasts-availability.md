# ADR-0019: Region-Aware Podcasts Tab Visibility

## Status

Implemented

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
`FEmusic_podcasts` once per session, gates main-window rendering on the
result, and exposes the resolved state to the sidebar through the SwiftUI
environment. State is **in-memory only** — every cold launch re-probes from
scratch.

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

A second observable, `didResolveFirstProbe: Bool`, tracks whether the first
probe of the session has finished. It flips to `true` on any probe
completion (success, 404, transient error) **or** when a 2-second timeout
fires. `MainWindow.body` shows the loading spinner until this flag flips,
so the sidebar paints with the correct state on first frame — no
appear-then-disappear flicker.

### No persistence

The service's state lives only in memory. Trade-offs considered:

- **+** Region changes (e.g. enabling a VPN) are picked up by quitting
  and relaunching the app — no sign-out/in dance and no cache to
  invalidate.
- **+** No schema versioning, no TTL, no per-account cache lifecycle to
  reason about.
- **−** One extra `browse` request per cold launch. Cost is essentially
  zero: the request runs in parallel with `homeViewModel.refresh()`
  etc., warms `APICache` so opening the tab right after launch is
  instant on available regions, and is hidden behind the spinner on
  unavailable regions where it ends quickly with 404.

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
  visited the tab. Background probe with empty sections releases the gate
  but leaves `availability` untouched.
- **Ignored**: 5xx, network errors, auth errors. Transient failures must
  never demote a known-good state. They still release the gate so the UI
  doesn't hang behind a flaky network.

### Probe lifecycle (in `MainWindow`)

- **First probe**: a `.task(id: authService.state.isLoggedIn)` modifier
  fires whenever `isLoggedIn` flips to `true` — covering both cold launches
  with cached cookies (`.initializing → .loggedIn`) and explicit sign-ins
  (`.loggingIn → .loggedIn`). After a 200 ms cookie-settle delay it calls
  `service.probeForFirstResolution(...)`, which races the probe against a
  2-second timeout and flips `didResolveFirstProbe` when either completes.
  The probe always runs to completion in the background — a slow but
  definite 404 still demotes the tab when it lands, even if the gate
  released earlier via timeout.
- **Account switch**: existing `onChange(of:
  accountService.currentAccount?.id)` block fires a probe in the same
  `withTaskGroup` as the other content refreshes. The gate
  (`didResolveFirstProbe`) is deliberately *not* re-closed here, so
  `mainContent` stays visible while content refreshes; the sidebar
  briefly shows the prior account's tab state until the probe returns
  a definitive answer. We accept this small staleness window in
  exchange for not tearing down the whole UI on every switch.
- **Logout**: `service.reset()` clears both `availability` and
  `didResolveFirstProbe`. The next sign-in re-gates the UI and re-probes.
- **`refreshAllContent`**: skips the podcasts viewmodel refresh when
  `availability == .unavailable` to avoid re-firing the spurious 404.

### UI integration

- **`Sidebar.swift`** renders the Podcasts `NavigationLink` only when
  `availability != .unavailable`.
- **`MainWindow.swift`** holds `mainContent` rendering until
  `didResolveFirstProbe == true`; until then the existing
  `initializingView` (cassette icon + spinner) is shown. Also redirects
  `navigationSelection = .home` if the state flips to `.unavailable`
  while the user is on the Podcasts tab (handles the lazy-path case
  during account switches).
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
- No flicker on cold launch in either direction (US-style users see the
  tab when content paints, TR-style users never see it appear).
- Other podcast features (library subscriptions, search, artist pages)
  remain fully functional because they're gated separately.
- No new third-party dependencies. No persistence-layer surface area.

**Negative**

- One extra `browse` request per cold launch. Mitigated by parallelism
  with the existing post-login refreshes and by `APICache` warming for
  available regions.
- Cold-launch first paint is gated on the probe (or 2 s timeout). For
  available regions this is typically <500 ms and invisible behind the
  spinner that already covers the auth check.

**Neutral**

- `SettingsManager.LaunchPage` already excludes `.podcasts`, so default-tab
  logic needed no changes. `lastUsedPage` is typed as `LaunchPage` and
  cannot become podcasts.
- Keyboard navigation commands (⌘1/2/3/F/K) and the command bar do not
  reference podcasts.

## Alternatives considered

- **Lazy-only (no proactive probe)**: simpler, but the Podcasts row
  would show on the first session in an unsupported region until the
  user clicked it and saw the 404. The first-paint flicker is exactly
  what we're trying to avoid.
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
