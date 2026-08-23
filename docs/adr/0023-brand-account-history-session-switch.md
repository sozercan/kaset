# ADR-0023: Brand-Account History via WebView Session-Identity Switch

## Status

Accepted

## Context

Listening/watch history did not record on Brand accounts (GitHub issue
#277), for both music and video. A live, read-only investigation on a
real brand account established the mechanism precisely:

- **History is recorded by the playback WebView, not by Kaset.** A repo
  grep for `watchtime|videostats|/api/stats|playbackTracking` over
  `Sources/Kaset` returns zero hits. Real-world history is created by the
  watch page's own `videostats` pings (`/api/stats/playback`,
  `/api/stats/watchtime`), which attribute to the identity baked into the
  served document's `ytcfg.DATASYNC_ID`
  (`"<delegatedSessionId>||<userSessionId>"` for a brand,
  `"<userSessionId>||"` for the primary).
- **Brand support was wired only into the native API clients.**
  `YTMusicClient`/`YouTubeClient` inject `context.user.onBehalfOfUser`
  for *data fetches* (so the History *view* correctly queries the brand,
  which returns a genuinely empty container). The *playback* WebView
  always loaded a bare `…/watch?v=<id>` under the single shared
  `WKWebsiteDataStore.default()` — i.e. always the primary identity — so
  every play recorded to the primary's history.
- **Per-request brand override cannot fix playback.** Verified live: a
  brand `onBehalfOfUser` body field makes music `/player` return 401; an
  `X-Goog-PageId` header still yields no `streamingData`; video `/player`
  returns `UNPLAYABLE`. Music `/player` is `UNPLAYABLE` even as the
  primary for a non-browser client (YouTube bot detection — the reason
  Kaset plays in a WebView at all). So recording **must** stay in the
  WebView, and identity must be a property of the **session**, not the
  request.

The deferred TODO in `AccountService.switchAccount` ("selectActiveIdentity
not implemented yet") was exactly this gap: the switch only updated local
state and never re-pointed the WebView session.

## Decision

**Switch the WebView session's active delegated identity on account
switch, by navigating to the server-issued `accountSigninToken.signinUrl`,
and gate the switch on a verified `ytcfg.DATASYNC_ID` read.**

- `accounts_list` already exposes, per account,
  `selectActiveIdentityEndpoint.supportedTokens[].accountSigninToken.signinUrl`
  — a `…/signin?…&pageid=<brandId>&authuser=N&next=…` endpoint (the
  primary's omits `pageid`). `AccountsListParser` now captures it into
  `UserAccount.signinURL` (credential-bearing; never logged).
- `WebKitManager.switchSessionIdentity(to:expectedBrandId:)` navigates a
  transient WebView (on the shared data store) to that URL, then reads
  `ytcfg.DATASYNC_ID` and verifies the delegated half matches the expected
  brand pageId (or is absent, for the primary). It throws on mismatch,
  navigation failure, or a 20s timeout.
- `AccountService.switchAccount` performs and awaits the verified switch
  **before** committing `currentAccount`. A failed/unverified switch
  throws into the existing revert path, so the app never silently records
  to the wrong account — a strictly safer state than the previous
  local-only switch.
- Because the data store is shared, the switch re-points identity for
  both playback WebViews and cookie-derived API calls at once.
  `MainWindow` re-points the in-flight track
  (`PlayerService.reloadCurrentTrackForIdentitySwitch`,
  `forceFullPageWhenSameVideoId` + restored-session resume) so continued
  listening records to the new account.

## Consequences

- The fix is shared across music and video (single shared cause → single
  shared fix), matching the reported symptom.
- The single shared `WKWebsiteDataStore` is global: a switch affects every
  cookie-derived surface. The verification gate plus fail-safe revert
  bound the risk; the API-layer `onBehalfOfUser` override and the
  cookie-level pin must be kept reconciled (no split-brain).
- The `signinURL` is credential-bearing and may be single-use/short-lived;
  on failure we re-fetch `accounts_list` for a fresh URL.
- **Cold-launch window (known limitation).** A restored brand account is
  exposed as `currentAccount` immediately on launch, while its session pin
  verifies in the background (deliberately off the launch path so a ≤20s
  navigation never stalls startup). If the user starts playback in that
  brief window, the first stats pings can attribute to the primary account
  until the pin lands; the `verifiedIdentitySequence` reload then re-points
  the in-flight track so subsequent listening records to the brand. We
  accept this small residual rather than block all playback on launch for
  up to 20s (which would be a worse, universal UX regression). The window
  is bounded by the pin's verification, and the common case (switching
  accounts in an already-running app) is fully gated.
- DRM/EME is keyed by origin+data store (identity-independent), so
  decryption is unaffected; the forced reload tears down and rebuilds the
  media element, with position/play-state resumed via the existing
  restoration machinery.
- The mechanism's linchpin — that a real WebView's `signin?pageid`
  navigation flips `DATASYNC_ID` and lands the play in brand history — is
  confirmable only at runtime (a bare `URLSession` follow lands on
  `/oops`; it cannot run the page JS the switch relies on). **Validated**
  on a real account: after switching to a brand account, the player
  WebView's `DATASYNC_ID` went from `<user>||` (primary) to
  `<brandId>||<user>` (brand) on the first read, and a subsequent play
  grew the previously-empty brand `FEmusic_history` by one track while the
  primary's was unaffected. `api-explorer` gained read-only `ytcfg`,
  `signin-probe`, and `X-Goog-PageId` probes to support this.
