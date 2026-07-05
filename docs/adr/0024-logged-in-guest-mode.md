# ADR-0024: Logged-In Guest Mode

## Status

Accepted

## Context

Kaset originally treated authentication as a single binary state: logged out
or logged in. That was enough for signed-in account features, but it did not
support the YouTube-style experience where a user can browse public content
without using personalization while still keeping their signed-in session
available.

Unauthenticated playback/data fetching introduced a third practical state:
**signed in, but intentionally browsing as Guest Mode**. This state has a few
important constraints:

- The app must preserve cookies and account data so the user can switch back
  without signing in again.
- Public music and video surfaces should behave as unauthenticated requests:
  no auth headers, no cookies, and no delegated brand-account context.
- Account-backed UI and mutations such as likes, library, subscriptions,
  history, watch-later, playlists, and comments must be hidden or disabled.
- Switching between personal/brand accounts from Guest Mode must still be able
  to perform the authenticated account switch.
- Cached personalized API responses must not leak into Guest Mode after the UI
  says the user is browsing as guest.

## Decision

Represent Guest Mode as a temporary overlay on top of an existing logged-in
session, rather than as logout.

- `AuthService` owns `isGuestModeEnabled` and exposes `hasPersonalAccount` as
  the single gate for account-backed UI, mutations, and authenticated API
  requests.
- `YTMusicClient` and `YouTubeClient` use `hasPersonalAccount` when deciding
  whether to build authenticated headers. Logged-in Guest Mode therefore uses
  the same public request path as signed-out browsing.
- `AuthService.enterGuestMode()` and `AuthService.exitGuestMode()` invalidate
  `APICache` when crossing the personal/guest boundary. Sign-out, reauth, and
  login completion already clear guest state or cache as appropriate.
- The profile/account switcher includes a first-class **Guest Mode** row. When
  selecting another account while in Guest Mode, the switcher first completes
  `AccountService.switchAccount(to:)`, then exits Guest Mode only after the
  switch succeeds. If the switch fails, Guest Mode remains active and the
  popover stays open for retry.
- Sidebars and action surfaces use `hasPersonalAccount` instead of raw
  `state.isLoggedIn` so logged-in Guest Mode does not expose account-only
  destinations or mutations that would fail or use personalization.

## Consequences

- Users can move between personalized account browsing and public Guest Mode
  without losing their signed-in session.
- API behavior now has three meaningful modes: signed out, signed in personal,
  and signed-in guest. Code that needs account-backed behavior should use
  `hasPersonalAccount`; code that only needs to know whether cookies exist can
  still inspect `state.isLoggedIn`.
- Cache invalidation on Guest Mode transitions is intentionally broad. It avoids
  personalized-data leaks at the cost of refetching public/personal surfaces
  after mode switches.
- Account switch UX becomes explicit: Guest Mode is shown alongside real
  accounts, but account switching itself remains an authenticated operation.
- Future account-only surfaces should be reviewed for `hasPersonalAccount`
  gating, not merely `state.isLoggedIn`, to avoid exposing unavailable actions
  while the user is browsing as guest.
