# ADR-0026: Generation-Scoped Web Playback Bridge Events

## Status

Accepted

## Context

Kaset's YouTube Music and regular YouTube players both keep one persistent
`WKWebView` and translate JavaScript bridge messages into native playback
state. Full-page navigation is asynchronous: the outgoing document remains
alive while Kaset pauses it and prepares the next watch page.

The outgoing page can therefore publish late state, progress, ended, media-key,
AirPlay, lyrics, or metadata events after native state has already selected the
next item. A video ID alone is not a safe boundary:

- the old and new documents can report different IDs during one explicit load;
- same-document YouTube autoplay/SPA transitions legitimately change IDs and
  must still reach native reconciliation;
- duplicate queue entries can share an ID;
- a replaced WebView can retain a message handler long enough to deliver a late
  callback.

Tests previously exercised `PlayerService` methods directly or inspected script
strings. They did not establish that an active bridge message came from the one
WebView document currently allowed to mutate native state.

## Decision

Every full-page playback navigation receives a monotonically increasing
**document generation** managed by native Swift.

- `WebPlaybackDocumentGeneration` owns committed, pending, provisionally
  loading, and invalidated generations independently of video identity.
- Beginning a navigation reserves a generation and temporarily suppresses
  outgoing-document bridge messages.
- Immediately before `WKWebView.load`, the still-current reserved generation is
  marked provisionally loading. A superseded asynchronous callback cannot start
  an older load.
- The generation becomes committed only from `WKNavigationDelegate.didCommit`.
  If WebKit cancels or fails before commit, the previous committed document is
  not trusted as the requested video: the requested WebView identity is cleared,
  prior bridge generations are invalidated, and playback becomes explicitly
  retryable.
- A superseded request that never reaches `WKWebView.load` drops its reservation.
  Explicit user cancellation is stricter: it pauses the surviving page,
  invalidates every prior generation, clears WebView identity, and leaves the
  selected item as a deferred retry rather than re-authorizing an outgoing page
  that may represent different content.
- Main-frame document navigations not initiated by Kaset are cancelled; the
  hidden playback pages are not user-facing browser tabs. Fragment-only
  same-document navigation is left alone. While a navigation is reserved, other
  document-changing page actions are cancelled; while it is provisional, only
  requests carrying that provisional generation are allowed only across the
  expected HTTPS playback origin and an explicit allowlist of Google/YouTube
  consent or authentication origins. Trusted intermediates remain provisional;
  only the expected playback origin may commit and publish bridge messages.
  Captive-portal and unrelated error origins are cancelled into the retry path.
- Starting a newer explicit load cancels the previous provisional load before
  replacing the WebView-wide user-script list. Server redirects refresh the
  bootstrap fallback; redirect requests remain associated through the original
  generation-bearing `mainDocumentURL` even when the redirect target drops the
  query item. YouTube's one-shot resume seek is retained on that tracked
  navigation and reinstalled for each redirect hop.
- Internal `about:blank`/`data:` navigations used to blank a torn-down WebView
  are allowed; their origins cannot pass the playback bridge source gate.
- Teardown or WebView replacement invalidates every earlier generation.
- The reserved generation is encoded in a watch URL query item. A stable
  document-start bootstrap reads that navigation-bound token into
  `window.__kasetDocumentGeneration`; this avoids assigning a later token to an
  earlier provisional document through the WebView-wide user-script list.
- Every playback bridge payload includes the document generation.
- Coordinators accept a payload only when both conditions hold:
  1. It comes from the expected HTTPS YouTube main-frame origin.
  2. `message.webView` is the current singleton playback WebView.
  3. The payload generation is the active native generation and no newer
     navigation is pending.
- A WebContent-process termination invalidates the terminated document and
  starts one fresh generation-scoped navigation. Music reuses restored-session
  reconciliation to preserve seek/play intent, using the last non-ad content
  clock when an ad is active; terminal music states are not resurrected, and a
  fresh `.loading` selection never inherits the previous track's clock. YouTube
  reloads playing content at its content position and defers a paused reload
  until explicit resume.
- Music restoration ignores placeholder/no-media and ad clock samples. Its
  autoplay intent is re-synchronized at document commit and remains retryable
  across asynchronous `play()` rejection, so pause/stop intent cannot be
  overwritten by a late `canplay` callback.
- Navigation records live through `didFinish`/`didFail`, not merely `didCommit`,
  so a post-commit failure invalidates the failed document. Terminal cancellation
  (including committed-but-still-loading navigation) or failure clears the
  requested WebView identity and leaves playback in an explicit retry state
  rather than re-authorizing the outgoing page.

The gate deliberately does **not** require the observed video ID to match the
requested video ID. Same-document drift remains visible to existing queue and
YouTube SPA reconciliation.

## Consequences

- Late events from an outgoing or replaced document cannot overwrite a newer
  explicit playback intent.
- The same mechanism applies consistently to music state/ended/lyrics/AirPlay/
  audio-quality/media-key events and YouTube state/ended events.
- Core generation transitions, URL trust checks, bridge acceptance, retry plans,
  and script payload contracts have deterministic unit coverage. WebKit delegate
  sequencing is still verified through focused packaged runtime probes because
  `WKNavigation` instances cannot be constructed in a pure unit test.
- This decision does not yet separate requested/in-flight/committed video IDs,
  automatically retry ordinary navigation failures, or unify every near-end and
  ended signal into one native transition. Those reliability improvements build
  on this document boundary in later increments. Per-element duplicate/stale
  ended callbacks are rejected at the script boundary in this increment.
- Any new script that posts to a playback message handler must include the
  document generation or its messages will be rejected by design.
