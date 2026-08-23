# ADR-0012: Synced Lyrics Provider Architecture

## Status

Accepted

## Context

Kaset previously exposed lyrics primarily through `YTMusicClient.getLyrics(videoId:)`, which returns plain text from the YouTube Music lyrics browse endpoint. To deliver Apple Music-style line-by-line lyrics, the app needed a timed lyrics source and a UI that could stay synchronized with hidden WebView playback.

Adding synced lyrics introduced a few constraints:

1. **Separate data sources** — YouTube Music plain lyrics already exist inside the authenticated API client, but synced lyrics are not consistently available there. An external provider can supply LRC payloads without changing the playback stack.
2. **Track-switch races** — Lyrics lookups are asynchronous and can overlap when the user skips tracks quickly. Older searches must not overwrite newer results.
3. **Graceful fallback** — Plain lyrics remain better than no lyrics. The synced lyrics path must upgrade plain lyrics when possible without causing flicker or regressions.
4. **Polling cost** — Line-by-line highlighting needs higher-frequency playback time updates than the normal once-per-second progress UI. That extra polling should only run while synced lyrics are active.
5. **Extensibility** — Additional providers or future YouTube Music timed lyric parsing should fit into the same model without rewriting the UI.

## Decision

### Service Boundary

Introduce `SyncedLyricsService` as an `@MainActor @Observable` environment service responsible for lyric resolution and display state. It owns:

- The current `LyricResult` (`.synced`, `.plain`, or `.unavailable`)
- The currently active provider/source label
- In-memory caching by `videoId`
- Stale-request protection via a monotonic `fetchGeneration`

This keeps multi-source lyric resolution out of `LyricsView` and avoids expanding `YTMusicClient` beyond authenticated YouTube Music API responsibilities.

### Provider Layer

Introduce a `LyricsProvider` protocol that accepts `LyricsSearchInfo` and returns a `LyricResult`. `LRCLibProvider` is the initial implementation.

`SyncedLyricsService` queries all registered providers concurrently and chooses the best result with the following priority:

1. Synced lyrics
2. Plain lyrics
3. Unavailable

When multiple plain lyric providers exist, `YTMusic` is biased ahead of other plain-text sources. The protocol keeps room for future providers, including a provider backed by `LyricsParser.extractTimedLyrics(from:)`.

### Fallback Strategy

`LyricsView` asks `SyncedLyricsService` for synced lyrics first when `SettingsManager.syncedLyricsEnabled` is enabled. If providers return `.unavailable`, the view falls back to the existing `YTMusicClient.getLyrics(videoId:)` flow and stores that result through `fallbackToPlainLyrics(_:, videoId:)`.

The fallback behavior must preserve these invariants:

- Plain lyrics should appear quickly when synced lyrics are unavailable
- A cached plain result may later be upgraded to synced lyrics for the same `videoId`
- A plain fallback must never overwrite an already resolved synced result
- Stale provider results from an older track must never replace the current track's lyrics

### Playback Synchronization

Keep playback inside the existing hidden `WKWebView`, but add a dedicated high-frequency `LYRICS_TIME` message path for synced lyrics. `LyricsView` starts and stops WebView lyrics polling based on whether the current result is `.synced`, and `PlayerService.currentTimeMs` drives `SyncedLyricsDisplayView` for highlighting, auto-scrolling, and tap-to-seek.

### User Control

Add `SettingsManager.syncedLyricsEnabled` and expose it in General Settings so users can disable synced lyrics lookups and the associated extra playback polling.

## Consequences

### Positive

- **Clear separation of concerns** — `YTMusicClient` remains focused on authenticated YouTube Music API calls, while synced lyric resolution lives in a dedicated service.
- **Extensible provider model** — Additional lyric providers can be added without redesigning the lyrics UI.
- **Safer async behavior** — Generation-based stale-result protection prevents quick track changes from showing the wrong lyrics.
- **Better UX** — The app can upgrade from plain lyrics to synced lyrics for the same track and only pays the polling cost when synced lyrics are active.
- **Testability** — `LyricsProvider` can be mocked directly, which keeps provider scoring, fallback behavior, and race handling easy to cover in unit tests.

### Negative

- **External dependency** — Synced lyric quality and availability now depend on LRCLib response quality and uptime.
- **More moving parts** — Lyrics now span a service, provider protocol, parser, settings toggle, and a WebView polling path.
- **Cache scope** — The current lyric cache is in-memory only, so synced provider results are recomputed after app relaunch.

### Neutral

- Plain YouTube Music lyrics remain the fallback source for availability and AI explanation.
- The lyrics UI continues to be a persistent sidebar outside `NavigationSplitView`; synced lyrics change its data flow, not its placement.
- Future adoption of YouTube Music timed lyrics can fit behind the existing provider/service model rather than requiring another UI rewrite.
