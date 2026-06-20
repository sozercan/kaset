# YouTube Mode (Source Toggle)

Kaset can present two parallel experiences over the same Google login: the
YouTube Music client (default) and a native client for regular YouTube.
The source toggle at the bottom of the sidebar — above the profile
switcher — flips between them. This document covers the YouTube side's
architecture; the music side is documented in [architecture.md](architecture.md)
and [playback.md](playback.md).

## Design Rules

- **The music experience is untouched.** Everything YouTube-side is
  parallel: its own client, models, parsers, player service, and WebView.
  The only shared player file modified is `NowPlayingManager` (guarded,
  additive media-key routing).
- **One audio source at a time.** `PlaybackArbiter` pauses music when a
  video starts and pauses video when music starts. Media keys route to
  whichever source played last.
- **Source switches preserve state.** Toggling to Music pauses a docked
  video in place and keeps the YouTube navigation intact for restore;
  music keeps playing while browsing YouTube until a video starts.

## Layer Map

| Layer | Music | YouTube |
|-------|-------|---------|
| API client | `YTMusicClient` (WEB_REMIX, music.youtube.com) | `YouTubeClient` (WEB, www.youtube.com) |
| Protocol | `YTMusicClientProtocol` | `YouTubeClientProtocol` |
| Models | Song/Album/Artist/Playlist | `YouTubeVideo`/`YouTubeChannel`/`YouTubePlaylist` |
| Parsers | `Services/API/Parsers/` | `Services/API/Parsers/YouTube/` |
| Playback WebView | `SingletonPlayerWebView` | `YouTubeWatchWebView` |
| Player service | `PlayerService` | `YouTubePlayerService` |
| Floating window | `VideoWindowController` | `YouTubeVideoWindowController` |
| Navigation | `NavigationItem` + `Sidebar` | `YouTubeNavigationItem` + `YouTubeSidebar` |
| View models | MainWindow `@State` caches | `YouTubeViewModelStore` |

Shared/reused: `WebKitManager` (cookies/auth), `AuthService` + LoginSheet,
`APICache` (keys prefixed `yt:`), `RetryPolicy`, `YTMusicError`,
`ImageCache`/`CachedAsyncImage`, `SettingsManager`, `PlayerBar` (still
controls music while browsing YouTube), shared view components, and
`InnerTubeSupport` (pure SAPISIDHASH helper).

## API Client

`YouTubeClient` mirrors `YTMusicClient`'s request scaffolding by design
(deliberate duplication — see the ADR). The critical differences:

- **Origin**: SAPISIDHASH input and `Origin`/`Referer`/`X-Origin` headers
  must all be `https://www.youtube.com`. A music-origin hash silently 401s.
- **Context**: `clientName: "WEB"` (not `WEB_REMIX`).
- **No API key**: the `key=` query parameter is no longer required by
  InnerTube (confirmed June 2026).

### Endpoints

| Surface | Request |
|---------|---------|
| Home feed | `browse` `FEwhat_to_watch` |
| Explore | `browse` `FE{gaming,news,sports,live,fashion,learning}_destination` |
| Subscriptions feed | `browse` `FEsubscriptions` |
| Subscribed channels | `guide` (scoped to `guideSubscriptionsSectionRenderer`) |
| History | `browse` `FEhistory` |
| Watch Later / Liked | `browse` `VLWL` / `VLLL` (playlist page) |
| User playlists | `browse` `FEplaylist_aggregation` |
| Search | `search` (+`params` filters: videos `EgIQAQ==`, channels `EgIQAg==`, playlists `EgIQAw==`) |
| Watch metadata + related | `next` |
| Like / unlike | `like/like`, `like/dislike`, `like/removelike` |
| Subscribe | `subscription/subscribe` / `subscription/unsubscribe` |
| Watch Later edit | `browse/edit_playlist` (playlistId `WL`) |

Note: YouTube retired the Trending feed (`FEtrending` → HTTP 400); the
Explore surface uses the destination feeds that replaced it.

### Renderer Generations

YouTube is mid-migration between renderer generations (June 2026):

- Search videos/channels: legacy `videoRenderer` / `channelRenderer`
- Watch-next, channel pages, playlists, playlist search: `lockupViewModel`
- Destination feeds: `videoCardRenderer` / `gridVideoRenderer`

`YouTubeItemParser` handles all of them; `YouTubeFeedParser.collect`
walks responses recursively so container reshuffles don't break feeds.
Use `swift run api-explorer --youtube browse <id>` to inspect live
responses — the renderer histogram in its output shows what a surface
currently serves.

## Player Bar

The bottom Liquid Glass bar adapts to the active source. In YouTube mode
(`YouTubePlayerBar`, visually identical to the music `PlayerBar`):

- Previous/next skip between videos: back through session history,
  forward through the watch page's related list (fetched lazily when
  popped out). Skips while docked open the new video's watch view.
- The center shows the video thumbnail, title, and channel · views, with
  the same hover-to-seek behavior.
- Actions: like/dislike, Watch Later, AirPlay (video picker), closed
  captions menu (player tracks + Off), quality menu, full view, and
  picture in picture (pop out / pop in; hidden in fullscreen).
- No shuffle/repeat/lyrics/queue — those are music concepts.

Every navigable YouTube view carries its own bar inset (pushed views
don't inherit `safeAreaInset` — same rule as the music side).

## Playback

Playback uses a second singleton WebView (`YouTubeWatchWebView`) that
loads `www.youtube.com/watch?v={id}`. Two user scripts run on every watch
page:

1. **Observer script** — posts to the `youtubePlayer` message handler:
   - `STATE_UPDATE` (1 Hz + media events): `isPlaying`, `progress`,
     `duration`, `videoId`, `title`, `isAd`
   - `VIDEO_ENDED` on natural completion
   It also enforces the Kaset volume target (`window.__kasetTargetVolume`)
   and disables YouTube's autonav toggle so Kaset stays in control.
2. **Extraction script** — hides all page chrome with an ancestor-chain
   visibility approach (same pattern as the music video mode, see
   [video.md](video.md)): everything is `visibility: hidden` except the
   `.kaset-visible` chain from `#movie_player video` to the root, enforced
   per-frame while active. Defines `window.__kasetExtractVideo()` so
   `didFinish` can re-run it on cached loads.

Captions and quality are driven through the `movie_player` API
(`getOption('captions','tracklist')`, `setPlaybackQualityRange`), fetched
with retries once playback starts; the caption overlay is whitelisted in
the extraction CSS and pinned to the bottom. Audio is force-unmuted
whenever Kaset's volume target is audible (YouTube persists its own mute
state). A document-start blackout stylesheet keeps loads black until the
extraction chain reveals the video.

### Surface Placement

The extracted surface lives in exactly one place at a time, tracked by
`YouTubePlayerService.surfaceLocation`:

- `.inline` — docked in `YouTubeWatchView` (the watch page); playback is
  controlled from the player bar
- `.floating` — hosted by `YouTubeVideoWindowController`
- `.none` — no playback

Handoff rules:

- Opening a watch view auto-plays (or adopts the surface if its video is
  already playing, closing the floating window).
- Navigating away within YouTube while **playing** pops the surface out
  to the floating window; while **paused**, playback stops. The
  playing-case pop-out is gated by the `popOutVideoOnNavigateAway` setting
  (Settings → YouTube, default on); when disabled, navigating away **stops**
  playback instead of opening the floating window. The setting gates only this
  automatic hand-off — the player-bar PiP / Full-view buttons and the
  `kaset://` URL scheme open the floating window regardless.
- **Toggling to Music pauses the docked video in place** — no pop-out
  appears, and toggling back restores the same watch view (the YouTube
  drill-in path lives in `YouTubeViewModelStore`, which survives source
  switches). A deliberately popped-out window keeps playing.
- Closing the floating window stops playback.

The pop-out window is aspect-locked to 16:9 (512×288 minimum), shows the
full player bar and traffic lights as hover chrome over corner-to-corner
video, and its green button enters fullscreen. Fullscreen entered from
the inline watch view docks the video back inline when fullscreen exits.

KasetApp observes `surfaceLocation` and opens/closes the floating window;
`NSView` reparenting (`ensureInHierarchy`) moves the WebView between
containers without interrupting playback.

### Shorts

The Shorts surface is a vertical snap-paging player: opening it
autoplays the first short (9:16 surface docked in the page), trackpad
scrolling pages between shorts, and each page autoplays as it settles.
A transparent overlay forwards scroll events past the WKWebView (which
would otherwise swallow them). Shorts are detected in feeds (reel
endpoints, `/shorts/` URLs, portrait lockups, shorts shelves), stripped
from the regular grids, and routed to this surface.

### Watch Page

Below the video, the layout is two-column: title/metadata/channel and
the comments section down the left, the related rail down the right.
Comments come from the watch page's `comment-item-section` continuation
(entity-payload mutations joined to comment view models, with a legacy
`commentRenderer` fallback): paged reading, posting via
`comment/create_comment`, like/dislike toggles via
`comment/perform_comment_action` (like/unlike/dislike/undislike action
tokens), expandable reply threads, and author → channel navigation.

### Ads

Kaset does not block ads. During an ad, `STATE_UPDATE.isAd` is true and
the native scrubber is disabled; YouTube Premium accounts see no ads.

## Testing

- Parser tests run against sanitized captured fixtures in
  `Tests/KasetTests/Fixtures/YouTube/` (captured via
  `api-explorer --youtube … -o`). Re-capture when YouTube ships renderer
  changes.
- `MockYouTubeClient` (unit tests) and `MockUITestYouTubeClient`
  (UI-test mode) stub `YouTubeClientProtocol`.
- `YouTubePlayerService` takes an injectable `YouTubeWatchPlaybackControlling`
  so playback state tests never create WebViews.
- `InnerTubeSupportTests` pins SAPISIDHASH vectors for both origins —
  if those fail, auth is broken app-wide.

## Known Limitations / Future Work

- No auto-advance to the next related video after `VIDEO_ENDED` (YouTube
  autonav is disabled; Kaset shows the ended state — the bar's next
  button advances manually).
- Initial like state is not parsed (actions are optimistic from
  `.none`); subscribe state is seeded from watch-next.
- Watch-page DOM selectors (`#movie_player`, autonav toggle) can shift;
  the extraction enforcement loop and `api-explorer --youtube` are the
  debugging tools of choice.
- Comments on the watch page are deferred.
