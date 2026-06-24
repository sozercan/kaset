# ADR-0020: Native YouTube Client Behind a Source Toggle

## Status

Accepted

## Context

Kaset is a native YouTube Music client. On managed-browser setups,
youtube.com is blocked at the browser-policy layer (not network/DNS), so a
native app can reach it while browsers cannot. We wanted the same
native-client treatment for regular YouTube: browse, search, subscriptions,
and playback in native SwiftUI over YouTube's InnerTube API — switchable
via a source toggle, with the music experience untouched and default.

Two architectural questions dominated:

1. **One client or two?** YouTube and YouTube Music share the InnerTube
   protocol but differ in origin, client identity, content model, and
   response renderers.
2. **One playback WebView or two?** The music `SingletonPlayerWebView`'s
   observer script, controls, and queue sync are saturated with
   `ytmusic-*` DOM selectors.

## Decision

**Parallel everything; share only what is provably origin-neutral.**

- A separate `YouTubeClient`/`YouTubeClientProtocol` with ~120 lines of
  request scaffolding deliberately duplicated from `YTMusicClient` rather
  than refactoring the music client onto a shared base. The SAPISIDHASH
  origin difference (`https://www.youtube.com` vs
  `https://music.youtube.com`) means a shared client would need origin
  parameterization through every request path — wrong-origin bugs are
  silent 401s. Only the pure hash helper (`InnerTubeSupport`) is shared,
  pinned by fixed-vector tests for both origins.
- Separate models (`YouTubeVideo`/`YouTubeChannel`/…): YouTube's content
  model has no album/artist concept and serves display-ready strings.
- A second playback singleton (`YouTubeWatchWebView`) with its own
  observer script for the watch-page DOM, rather than parameterizing the
  music WebView. A small `PlaybackArbiter` enforces one audio source.
- Cross-cutting infrastructure is reused as-is: `WebKitManager` cookies
  (one Google login covers both hosts), `AuthService`, `APICache` with
  `yt:`-prefixed keys, `RetryPolicy`, `YTMusicError`, image caching, and
  the shared view components.
- The toggle persists via `SettingsManager.appSource`; `MainWindow`
  branches sidebar and detail on it. YouTube view models live in
  `YouTubeViewModelStore` so both experiences stay warm across toggles.

## Consequences

- The music path's risk surface is limited to one guarded, additive change
  (`NowPlayingManager` media-key routing) plus pure UI branching.
- ~120 lines of duplicated request scaffolding must be kept in sync
  manually. A follow-up could migrate `YTMusicClient` onto
  `InnerTubeSupport` once the YouTube side has soaked.
- Parsers must track YouTube's renderer migration (legacy renderers vs
  `lockupViewModel`); the recursive collector and captured fixtures
  (`Tests/KasetTests/Fixtures/YouTube/`) make breakage visible and
  fixable. `api-explorer --youtube` is the discovery tool.
- YouTube ads play (no blocking); Premium accounts see none.

## Follow-ups

- The origin-neutral playback primitives (generic `<video>` volume/commands,
  WebView reparenting, crash recovery) duplicated between the two playback
  WebViews were later consolidated into `WebPlayerScripts` — see
  [ADR-0024](0024-shared-web-player-scripts.md). The observers, `setVolume`,
  and video-extraction scripts remain parallel by design.

See [docs/youtube.md](../youtube.md) for the full architecture.
