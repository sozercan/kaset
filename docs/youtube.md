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
- **Product data uses APIs, not the playback WebView.** The regular YouTube
  WebView remains responsible for DRM playback. Optional watch-page features
  such as Ask Gemini must use `YouTubeClient`, strict response parsing, and
  account/lifecycle fences rather than DOM automation.
- **Undocumented surfaces fail closed.** HTTP success is not enough to enable a
  rollout-fragile feature. Ask Gemini remains hidden until a redacted parity run
  proves an eligible signed-in primary-account request profile.

## Layer Map

| Layer | Music | YouTube |
|-------|-------|---------|
| API client | `YTMusicClient` (WEB_REMIX, music.youtube.com) | `YouTubeClient` (WEB, www.youtube.com) |
| Protocol | `YTMusicClientProtocol` | `YouTubeClientProtocol` |
| Models | Song/Album/Artist/Playlist | `YouTubeVideo`/`YouTubeChannel`/`YouTubePlaylist` |
| Parsers | `Services/API/Parsers/` | `Services/API/Parsers/YouTube/` |
| Ask safety core | — | `YouTubeAskCore` (Foundation-only wire decoding, strict parsing, sanitization, and request bodies) |
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

Ask Gemini is an isolated optional path rather than a change to generic YouTube
requests. `getWatchPage(videoId:)` parses normal watch data and an optional Ask
bootstrap from the same `next` response. High-level conversation operations use
an Ask-specific bounded, same-origin, no-cache, no-automatic-retry transport and
expose only sanitized text plus local IDs to UI code. Opaque server commands stay
inside memory-bound domain values. A read-only watch bootstrap may retry once
when an account-scope publication resets the client after parsing; `get_panel`
and suggestion submissions are never retried automatically. See
[ADR-0032](adr/0032-youtube-ask-gemini.md).

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
| Watch chapters | `next` (`playerOverlays…multiMarkersPlayerBarRenderer.markersMap[].value.chapters[]`) |
| Ask eligibility/bootstrap | The existing watch `next` response, parsed only from confirmed YouChat structures |
| Ask panel + server-issued chips | `get_panel` using the explicitly selected fixed WEB request profile |
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

### Ask Gemini Activation Gate

Current `get_panel` replies arrive through a singular list-mutation command.
Kaset accepts text and follow-up chips only from the confirmed inserted
`youChatItemViewModel` contents, while generated result/link objects remain
non-interactive and undisplayed.

Opening the watch-page toolbar panel may prepare an initial panel, but it
never generates an answer until the user selects a server-issued suggestion or
submits free text. Free text is exposed only when the canonical
eligible `next` panel or its prompt-free initial `get_panel` materialization
supplies the exact validated `sendUserQueryCommand`. The client uses the `next`
command when present and otherwise prepares the exact server-issued panel
continuation; it never synthesizes or merges capabilities. Submission uses
`get_panel`, not `streaming_panel`. Each conversation revision may consume one
chip or free-text action; successful responses advance the revision and keep the
validated composer available unless YouTube supplies a replacement. Follow-up
chips remain server-issued, and any uncertain failure requires New Chat. Visible labels and
answers are sanitized but not localized by Kaset. Assistant messages render
native Markdown blocks and inline emphasis; link destinations are stripped and
never become interactive.

Production activation uses the fixed WEB request profile selected on July 30,
2026. Eligibility remains account- and video-scoped: signed-out, guest, brand,
identity-mismatched, malformed, and unsupported responses omit the panel. A
validated direct chip remains usable even when unrelated panel-bootstrap
continuations are ambiguous; Kaset never guesses or replays those panel commands.
The
[API discovery record](api-discovery.md#youtube-ask-gemini--youchat-investigation-2026-07-27)
is the wire-level source of truth; this document records only the product and
architecture boundary. See also [ADR-0032](adr/0032-youtube-ask-gemini.md).

## Player Bar

The bottom Liquid Glass bar adapts to the active source. In YouTube mode
(`YouTubePlayerBar`, visually identical to the music `PlayerBar`):

- The center shows the video thumbnail, title, and channel · views, with
  the same hover-to-seek behavior.
- Player bar transport buttons seek 30 seconds back/forward within the
  current video.
- Actions: like/dislike, Watch Later, AirPlay (video picker), closed
  captions menu (player tracks + Off), quality menu, full view, and picture in
  picture (pop out / pop in; hidden in fullscreen). When chapters are available,
  their break points are drawn directly into the progress bar as Liquid
  Glass-style seams with a material fallback; hovering or dragging near a break
  highlights it as a small glass bead, temporarily shows the chapter name/time
  in the player metadata title area, and release-near-chapter scrubs snap to
  that chapter.
- No shuffle/repeat/lyrics/queue — those are music concepts. Chapters use a
  horizontal scroller with chevron paging controls on the watch page.

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

### Float on Top

When enabled, the regular YouTube pop-out stays above standard windows on its
current Space. **Float on Top** is off by default and persists across pop-out
closure and app relaunch. It can be changed from any of these synchronized
controls:

- Settings → YouTube → Video Window → Float on Top.
- View → Float on Top while the pop-out is active.
- The pin control in the detached player bar.

Float on Top affects only the normal windowed pop-out. Fullscreen and pop-in
behavior remain unchanged from the user's perspective. Visibility is not
guaranteed across different Spaces or Stage Manager sets, above higher-level
windows, or over another application's fullscreen Space. The setting applies
only to the regular YouTube pop-out; YouTube Music's separate video window is
unchanged.

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
chapters/comments down the left, the related rail down the right.
Chapters come from the watch page's `next` response (see Endpoints above), show
as a horizontal scroller with chevron paging controls, and seek the active video
natively. Comments come from the watch page's `comment-item-section` continuation
(entity-payload mutations joined to comment view models, with a legacy
`commentRenderer` fallback): paged reading, posting via
`comment/create_comment`, like/dislike toggles via
`comment/perform_comment_action` (like/unlike/dislike/undislike action
tokens), expandable reply threads, and author → channel navigation.

When enabled by a validated request profile and an eligible watch response, Ask
Gemini appears as a sparkles action in the top toolbar. Activating it presents a
top-centered floating glass panel while leaving Related in place. The panel
discloses that YouTube generates the responses, prepares lazily, shows a
height-bounded selectable transcript, disables all interactions during a
single in-flight request, and offers New Chat after the first turn or when a
submission outcome is uncertain. The input row matches the Music command bar
and is enabled only for the validated first free-text turn. Outside click,
Escape, or the close control dismisses the
panel without discarding its current watch-scoped conversation. The
conversation is owned by the current watch view—not `YouTubeViewModelStore`—and
is discarded on navigation, source/account/authentication changes, cancellation,
or app termination.

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
- `YouTubeAskCoreTests` use small placeholder-only fixtures to cover bounded wire
  formats, strict YouChat parsing, decoy rejection, server order, sanitization,
  and accidental-secret detection. `YouTubeAskTransportTests`,
  `YouTubeAskClientTests`, and `YouTubeAskViewModelTests` cover redirect and
  response bounds, exact request shapes, identity fencing, direct-versus-
  materialized free-text capability provenance, single-flight behavior, New
  Chat, and command consumption without contacting YouTube.
- Ask UI tests are never part of routine verification because they launch the
  app. Run them only after explicit human approval. The read-only
  `ask-video-parity` command is a manual compatibility check, not a unit test and
  not evidence of a passing profile unless signed-in eligibility is confirmed.

## Known Limitations / Future Work

- Ask Gemini production uses the fixed WEB request profile selected explicitly
  by the app. Eligibility remains dependent on YouTube returning a supported
  YouChat bootstrap for the signed-in primary account and current video. See
  [ADR-0032](adr/0032-youtube-ask-gemini.md) and the
  [API discovery record](api-discovery.md#youtube-ask-gemini--youchat-investigation-2026-07-27).
- Ask Gemini supports repeated free-text turns with the validated `get_panel`
  shape and one consumed action per bound conversation revision. It does not
  invent additional multi-turn fields, and still omits `streaming_panel`, brand
  accounts, persisted conversations, telemetry, clickable generated links, and
  Apple Intelligence dependencies.
- No auto-advance to the next related video after `VIDEO_ENDED` (YouTube
  autonav is disabled; Kaset shows the ended state — the bar's next
  button advances manually).
- Initial like state is not parsed (actions are optimistic from
  `.none`); subscribe state is seeded from watch-next.
- Watch-page DOM selectors (`#movie_player`, autonav toggle) can shift;
  the extraction enforcement loop and `api-explorer --youtube` are the
  debugging tools of choice.
- Reply posting and comment sorting controls are intentionally minimal; the
  current watch page supports loading top-level comments, posting a top-level
  comment, and optimistic like/dislike toggles.

Chapter markers are available from the same `next` watch-page response for
videos that expose chapters. The stable watch-page path observed on
2026-07-07 is `playerOverlays…multiMarkersPlayerBarRenderer.markersMap[].value.chapters[]`
with `chapterRenderer.timeRangeStartMillis`, `title.simpleText`, and
thumbnails. The response can also contain `macroMarkersListItemRenderer` entries
in the chapters panel or structured description; those are useful fallbacks but
can be duplicated. Heatmap `macroMarkersListEntity.markersList` data is separate
and should not be treated as chapters.
