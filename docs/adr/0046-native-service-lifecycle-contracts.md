# ADR-0046: Keep Native Service Ownership Explicit

## Status

Accepted

## Context

Kaset coordinates lightweight native state with asynchronous WebKit events, account changes, and platform callbacks. Event delivery is neither immediate nor confined to the currently visible window or session. The following constraints explain where the app deliberately refuses to infer ownership from timing alone.

## Decision

### Application and playback lifecycle

- Hide the primary playback window rather than closing it during ordinary user operation, preserving the document for background audio. UI tests use ordinary close and termination so they can clean up the app process. Route valid early URL playback past the startup reset gate. Reopening from an auxiliary video window must not resize the auxiliary window or accidentally apply the primary SwiftUI scene's size policy to an inferred fallback window.
- Pause for system sleep without automatically resuming on wake. Reassert native media-key handlers independently of JavaScript animation frames when the app deactivates: WebKit can suspend those frames and the page can reclaim handlers. When AppKit menu auto-enabling is disabled, each item owns its enabled state. Rating requires the API-backed like manager and has no direct-WebView fallback.
- Distinguish the active native occurrence, the currently committed playback document, and the media ID. A pending navigation, an ad, or a late snapshot from the previous document must not claim Now Playing, finish a newer load, clear an explicit pause, or persist an incorrect resume point. Keep fallback metadata until the current document can publish atomically. Replaying the same ID is a new occurrence, not a duplicate event. Repeated seeks compose against the last requested target until observations catch up, and seeking to an end must not be undone by a late progress event.
- Native music intent and queue ownership determine whether a WebKit queue event can reconcile state. An outgoing or duplicate row cannot realign the index to an earlier occurrence; paging, enrichment, and Smart Shuffle use ownership tokens before publishing asynchronous results. Keep temporary recommendations out of saved queue state. See [ADR-0025](0025-smart-shuffle.md), [ADR-0026](0026-generation-scoped-web-playback-bridge.md), [ADR-0027](0027-native-music-playback-intents-and-queue-entry-identity.md), and [ADR-0035](0035-gapless-playback-native-queue.md).
- Sample explicit ad events as well as media events; one may arrive between the other's callbacks. The observed player API identifies ad media as type `2`; its inclusive query can detect stitched segments. A DOM player element having `addEventListener` does not prove its player API is ready. Keep the known ad media ID available to completion and seek recovery, and wait for the requested content and physical media after an ad pod: a transient gap between creatives is not proof of content playback.
- Pass through only the playback origin and known redirect intermediaries for playback document establishment. A Google traffic challenge is not an allowed intermediary: permitting its URL alone would not handle an HTTP 429 main-frame response or preserve a submitted form body across a generation rebind.

### Sessions and persistence

- An active user account switch owns the shared WebKit session over a passive account-list refresh or restore. Passive work must neither advance the user-switch generation nor pin an identity during the switch. Cookie-jar mutations made during redirects cannot be undone by stopping navigation; verification and any superseding pin must establish the surviving identity. A reusable auth cookie is not enough proof of account scope. `DATASYNC_ID` has two halves: `user||` for primary or `delegated||user` for brand; missing or malformed values verify neither identity. See [ADR-0023](0023-brand-account-history-session-switch.md).
- Treat storage unavailability and a transient API error differently from confirmed session loss. Keep the archive and its invalidation state backend-scoped, compare freshness before replacing it, and retain retryable login/sign-out intent when durable writes fail. A partial Google session is not a native API archive and its absence is not permission to erase the previous archive. Rollback restores login-domain cookies only, so rollback-safe clearing must not use a wider store fallback. Passive account probes, availability checks, Library and Spotlight updates must not publish results for a superseded identity. UI-test Library data never enters the real Spotlight index. See [ADR-0037](0037-deferred-cookie-restoration.md) and [ADR-0041](0041-non-destructive-session-loss.md).
- Only the playback WebView receives the user-approved extension runtime. Auth views must not expose login material to extensions, and extension runtime permission requests cannot widen the domains approved in Settings. See [ADR-0014](0014-extensions.md).

### Audio and scrobbling

- Keep HAL render work nonblocking and allocation-free. Main-actor lifecycle operations hand parameters to render-thread-owned state; callbacks entering from the HAL queue must not inherit main-actor isolation. Tear down callbacks before freeing their buffers. Smooth gain and coefficient changes, and crossfade bypass rather than resetting filter state abruptly. The permission gate is system audio recording, not microphone access. Identify WebKit audio processes by ownership rather than a bundle-ID prefix; if ownership is inconclusive, skip the tap rather than capturing another app. Start interactive permission flows only from a user action, and treat silence after a pause differently from capture denial. See [ADR-0017](0017-equalizer.md).
- Use double-precision transposed direct-form II biquads with independent channel state to reduce cumulative error through the cascade. Read targets per buffer and smooth live coefficients per sample. Use a common stereo limiter envelope to keep transients from shifting the stereo image. Coefficient smoothing is not thread synchronization; the current handoff is tracked in [#610](https://github.com/sozercan/kaset/issues/610).
- The continuity graph keeps output open at zero gain; it does not route the DRM media or set its volume. Bound the hold across detached media, an unsuccessful load, or queue exhaustion so the app does not retain output indefinitely. See [ADR-0036](0036-music-audio-output-continuity.md).
- Track play occurrences, not only song IDs. Seeking resets eligible elapsed time without creating a new scrobble; a confirmed same-item replay starts a new occurrence. Prefer authoritative duration, but give a provisional chapter parse a short window to resolve when authoritative metadata has not arrived. A final parsed segment without a terminal timestamp stays open until an effective duration is known. Re-arm one-shot observation with a lifecycle generation and finalize before teardown, not from `deinit`. See [ADR-0011](0011-scrobbling-support.md) and [ADR-0029](0029-now-playing-tracklist-provider.md).

## Consequences

The native state is deliberately conservative until it has current ownership evidence. Changes to callback plumbing, queue synchronization, or account lifecycle need to test late events and replacement, not only the successful in-order path.
