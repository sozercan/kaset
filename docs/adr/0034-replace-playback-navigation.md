# ADR-0034: Replace Playback Documents Without Growing History

## Status

Accepted

## Context

Kaset plays DRM-protected music and video in persistent `WKWebView` instances.
Each track change previously called `WKWebView.load`, which added another full
YouTube watch document to WebKit's navigation history. WebKit retained a large
amount of page and media state across those navigations even when the current
document had only one video element and one set of Kaset observers.

A packaged no-extension run reproduced the problem. Repeated music track
changes grew the WebContent process rapidly while Kaset's own process and live
DOM stayed nearly flat. Recreating the WebView was worse: WebKit cached one old
high-water WebContent process while starting a new one, increasing total memory.

## Decision

1. Use `WKWebView.load` for the first playback document and for explicit
   continuation or recovery loads.
2. When a committed playback document already exists, navigate with
   `window.location.replace`. This destroys the outgoing document without
   adding another back-forward-list entry.
3. Keep the existing document-generation, response, host, and video-ID checks
   around the JavaScript-initiated navigation. Delegate callbacks promote only
   the generation encoded in the requested playback URL.
4. On teardown, remove script message handlers and navigation delegates, and
   close the matching WebExtension tab before releasing the WebView.

## Consequences

- In a packaged run with zero extensions loaded, 16 legacy track loads grew the
  back-forward list from 0 to 15. Replacement navigation kept it at 0. Every
  requested document committed, and the live YouTube player matched the native
  track after each change.
- A separate 10-minute no-extension playback run included one natural track
  transition. Kaset remained near 190–214 MB RSS. WebContent finished at a
  351 MB physical footprint with a 521 MB peak, and the GPU process finished at
  30 MB with a 40 MB peak. Raw WebContent RSS reached about 623 MB because
  WebKit retained reclaimable allocator pages.
- Kaset has no user-facing WebView back navigation, so replacing the current
  history entry removes no product behavior.
- Replacing the visible URL with `history.replaceState` and then calling
  `WKWebView.reload` was rejected. Runtime instrumentation showed that WebKit
  reloaded the old player while displaying the new URL, leaving the new native
  document generation uncommitted.
- A controlled extension-enabled A/B used uBlock Origin Lite for Safari
  2026.825.1619 in its default Optimal mode and the same 17-track sequence.
  The legacy build's WebContent physical-footprint peak was 851 MB; replacement
  navigation reduced it to 516 MB. The sampled aggregate peak fell from 855 MB
  to 476 MB, and the settled single-process footprint fell from 391 MB to
  346 MB.
- The uBlock A/B did not reproduce the reported 1.4 GB GPU spike. GPU physical
  footprint peaked at 42 MB in the legacy build and 41 MB in the patched build.
  A separate 15-minute patched run with uBlock peaked at 40 MB GPU and 433 MB
  WebContent while completing three track replacements. This validates the
  Kaset-side WebContent fix, but not the reporter's GPU-specific symptom on
  macOS 26; the local run used a newer WebKit build.
