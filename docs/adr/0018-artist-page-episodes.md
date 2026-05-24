# ADR 0018: Artist Page — Episodes, Singles, Playlists, Podcasts, Related Artists

**Date:** 2026-04-19
**Status:** Accepted

## Context

`ArtistParser.parseArtistDetail` previously extracted only two shelves from an
artist page:

- **Top songs** from `musicShelfRenderer`
- **Albums** from `musicCarouselShelfRenderer` items whose `browseEndpoint`
  started with `MPRE…` / `OLAK…`

Every other carousel shelf that YouTube Music returns was silently dropped.
For channel-style artists — Lofi Girl, ChilledCow, College Music, Chillhop —
the most-used content (live radio streams) lives under the **Latest episodes**
shelf, which is a `musicCarouselShelfRenderer` of `musicMultiRowListItemRenderer`
items whose `videoId` hides under `onTap.watchEndpoint`, not
`navigationEndpoint`. Users could browse Lofi Girl's page in Kaset but had no
way to reach the live streams that the channel is known for.

A fixture capture for `UCSJ4gkVC6NrvII8umztf0Ow` showed the artist page
returns nine sections on a single-column response:

| # | Shelf title | Renderer | Item nav shape |
|---|---|---|---|
| 0 | Top songs | `musicShelfRenderer` | — |
| 1 | Albums | `musicTwoRowItemRenderer` | `browseEndpoint` → `MPRE…`/`OLAK…` |
| 2 | Singles & EPs | `musicTwoRowItemRenderer` | `browseEndpoint` → `MPRE…`/`OLAK…` |
| 3 | Videos | `musicTwoRowItemRenderer` | `watchEndpoint` → `videoId` |
| 4 | Latest episodes | `musicMultiRowListItemRenderer` | `onTap.watchEndpoint.videoId` + optional `liveBadgeRenderer` |
| 5 | Podcasts | `musicTwoRowItemRenderer` | `browseEndpoint` → `MPSPP…` |
| 6 | Playlists by \<artist\> | `musicTwoRowItemRenderer` | `browseEndpoint` → `VL…`/`PL…` |
| 7 | Fans might also like | `musicTwoRowItemRenderer` | `browseEndpoint` → `UC…` |
| 8 | About | `musicDescriptionShelfRenderer` | — |

## Decision

Extend the artist page to surface **five additional shelves** and introduce a
dedicated playback path for live / channel-video items.

### 1. New `ArtistEpisode` model

Episodes (channel uploads, including live radio streams) are distinct from
`Song` and from `PodcastEpisode`:

- `Song` assumes a fixed duration, album context, and artist list. Live
  streams have none of these.
- `PodcastEpisode` carries `showBrowseId`, `playbackProgress`, `isPlayed`,
  `durationSeconds` — fields specific to formal podcast shows
  (`MPSPP…`). Artist-page episodes are channel videos, not podcast episodes;
  conflating them would corrupt the podcast feature's invariants.

`ArtistEpisode` carries only what the shelf actually provides:
`videoId`, `title`, `subtitle` (e.g. `"5d ago"`), `description`,
`thumbnailURL`, `isLive`.

### 2. Shelf classification by renderer + browseId prefix

`ArtistParser.parseArtistDetail` now routes each carousel item by renderer
shape, with the shelf title as a tiebreaker for `Album` vs `Single`:

- `musicMultiRowListItemRenderer` → `episodes` (live detected via
  `badges[].liveBadgeRenderer`)
- `musicTwoRowItemRenderer` classified by `browseEndpoint.browseId` prefix:
  - `MPRE…` / `OLAK…` → `albums` (or `singles` when the shelf title contains
    "single" or "ep")
  - `MPSPP…` → `podcasts` (reuses existing `PodcastShow` model)
  - `UC…` → `relatedArtists` (reuses existing `Artist` model)
  - `VL…` / `PL…` → `playlistsByArtist` (reuses existing `Playlist` model)

The `Videos` shelf (`watchEndpoint` with `videoId` on a `musicTwoRowItemRenderer`)
is intentionally deferred — it raises a separate UX decision about playing a
music video vs its audio track.

### 3. Navigation reuse

`NavigationDestinationsModifier` already handles `Playlist`, `Artist`, and
`PodcastShow` as navigation values. Podcasts, playlists-by-artist, and
related-artists cards therefore use plain `NavigationLink(value:)` with zero
new destination code.

### 4. Live-aware playback path

Live streams are radio channels, not tracks. Treating them as queue items
breaks several invariants: no duration, no seek, no meaningful next/previous.
`PlayerService` gains:

- `currentEpisode: ArtistEpisode?` — set when playback originates from the
  episodes shelf, cleared at the start of `play(song:)` and `play(videoId:)`.
- `isCurrentItemLive: Bool` — computed from `currentEpisode?.isLive`.
- `playEpisode(_ episode: ArtistEpisode) async` — clears the queue,
  synthesizes a minimal `Song` so `PlayerBar` can render thumbnail and
  title, delegates to `play(song:)`, then reassigns `currentEpisode`.

`PlayerBar.centerSection` renders a red-dot **LIVE** indicator in place of the
seek bar when `isCurrentItemLive == true`. Regular (non-live) episodes still
use the normal seek bar; only live items are gated.

### 5. Scrobble safety — no change required

`ScrobblingCoordinator` already gates threshold checks on `duration > 0` and
`duration >= 30`. Live streams report `duration == 0`, so scrobbles are
naturally skipped without introducing a live-specific branch.

## Architecture

```
ArtistParser.parseArtistDetail
  ├── classifyCarouselItem(shelfTitle:)
  │     ├── musicMultiRowListItemRenderer → parseEpisodeFromMultiRowRenderer → ArtistEpisode
  │     └── musicTwoRowItemRenderer, dispatch on browseId prefix:
  │           ├── MPRE / OLAK                 → albums | singles (by shelf title)
  │           ├── MPSPP                       → podcasts (PodcastShow)
  │           ├── UC                          → relatedArtists (Artist)
  │           └── VL  / PL                    → playlistsByArtist (Playlist)
  └── returns ArtistDetail with seven buckets

PlayerService.playEpisode(_)
  ├── clears queue + forward-skip stack
  ├── synthesizes Song(title:, thumbnailURL:, videoId:) for PlayerBar
  ├── delegates to play(song:) (resets currentEpisode = nil)
  └── assigns self.currentEpisode = episode (after play() runs)

PlayerBar.centerSection (on hover)
  ├── isCurrentItemLive → liveIndicatorView (red dot + LIVE)
  └── otherwise         → seekBarView (existing behavior)
```

## Consequences

- **Positive**: Channel-style artists (Lofi Girl, ChilledCow, College Music,
  Chillhop, Dreamhop, etc.) are now browsable end-to-end, including their
  live radio streams — Kaset's signature missing feature for this class of
  artist.
- **Positive**: Singles & EPs no longer collapse into the Albums carousel,
  matching YouTube Music's own shelf split (meaningful for artists like
  Taylor Swift with 100+ singles).
- **Positive**: Playlists-by-artist, podcasts, and related artists all reuse
  existing detail views via `NavigationDestinationsModifier`, adding zero
  new navigation plumbing.
- **Positive**: The episode renderer (`musicMultiRowListItemRenderer`) also
  appears on other pages. The carousel-item classifier is general-purpose
  and can be reused when those pages are parsed.
- **Neutral**: `ArtistDetail` grows from four content buckets to seven. All
  new fields default to `[]`, so downstream consumers that only read
  `songs`/`albums` need no changes. Two `ArtistDetail(…)` rebuild sites
  (`YTMusicClient.getArtist` duration-enrich, `ArtistDetailViewModel` name
  fallback) were updated to forward the new fields.
- **Negative**: Live-stream `videoId`s churn (YouTube assigns a fresh one
  when a stream restarts). Favoriting or queueing a live episode is
  therefore not supported in this slice — a captured videoId can 404 after
  a stream cycle. Revisiting this requires a stream-resolve hop against the
  channel; deferred.
- **Negative**: The `Videos` shelf is still dropped. It behaves the same way
  structurally (`musicTwoRowItemRenderer` → `watchEndpoint.videoId`) but
  the UX question — play music video vs audio-only — is out of scope.

## Alternatives considered

### Reuse `Song` or `PodcastEpisode` for artist-page episodes
Rejected. `Song` assumes a duration and an album; neither holds for live
streams. `PodcastEpisode` carries show-scoped fields (`showBrowseId`,
`playbackProgress`, `isPlayed`) that don't apply to channel videos, and
polluting it risks breaking the podcast detail flow.

### Derive live-ness from observed `duration == 0` at runtime
Rejected. The parser already has authoritative `liveBadgeRenderer`
information. Deriving from duration would: (a) flicker the PlayerBar on
track load before the WebView reports a duration, (b) misclassify regular
uploads whose metadata hasn't landed yet. Carrying `isLive` explicitly on
`ArtistEpisode` is both simpler and correct.

### Add live streams to the queue as one-item queues
Rejected. Previous / next buttons on a one-item queue silently no-op, which
is worse than not offering them. Live items play standalone; the queue
remains untouched (and is restored when the user plays a regular song
next).

## See-all / More button

Each carousel shelf optionally carries a `moreContentButton` in its header
pointing at a browse endpoint. Three `pageType` destinations are observed in
practice across artists:

| pageType | Example | Response shape |
|---|---|---|
| `MUSIC_PAGE_TYPE_PLAYLIST` | Top songs (`bottomEndpoint`), Videos shelf (`VLOLAK…`) | Standard playlist page — reuses existing `Playlist` / `PlaylistDetailView` route. No new code. |
| `MUSIC_PAGE_TYPE_ARTIST_DISCOGRAPHY` | Nirvana Albums (`MPAD…`) | `gridRenderer` of `musicTwoRowItemRenderer` album cards. New parser (`parseArtistDiscography`) + view (`ArtistDiscographyView`). |
| `MUSIC_PAGE_TYPE_ARTIST` | Lofi Girl Latest episodes (`UC…` + 304-char `params`) | Single `gridRenderer` of `musicMultiRowListItemRenderer` items (authenticated only). New parser (`parseArtistEpisodesGrid`) + view (`ArtistEpisodesListView`). |

The parser captures these into `ArtistDetail.moreEndpoints: [ArtistShelfKind: ShelfMoreEndpoint]`
while classifying each shelf. `ArtistDetailView` renders a **See all** link
next to any section header whose `moreEndpoints[kind]` is populated — zero
links appear on shelves without a More button, which is most of them for
most artists. Dispatch:

- `.playlist` — `NavigationLink(value: Playlist)` constructed from the
  endpoint's `browseId`. Routes through the existing `Playlist` destination.
- `.discography` / `.artist` — wrapped in `ArtistSeeAllDestination` so
  `NavigationDestinationsModifier` can switch on `endpoint.pageType` and
  pick the right view.

Anonymous requests against the `MUSIC_PAGE_TYPE_ARTIST` endpoint return the
page skeleton but no items — the filter-params aren't honored without
authentication. The parser was therefore designed against an authenticated
HAR capture of the Latest-episodes More response, preserved as
`artist_lofi_girl_episodes_more.json` (`visitorData` redacted).

Unknown `pageType` values are dropped at parse time — we never surface a
See-all link to a destination we don't know how to render.

## Follow-ups

- **Videos shelf**: separate slice — depends on an explicit UX decision for
  audio-only vs video playback of music videos.
- **Live stream stability**: resolve channel → current live `videoId` on
  open, so Favorites / deep links survive stream restarts.
- **Fixture-backed regression tests for other shelves**: the
  `parseArtistDetailFromLofiGirlFixture` test covers the carousel capture;
  `parseArtistEpisodesGridExtractsEpisodes` covers the See-all grid. Similar
  captures for a conventional recording artist (e.g. Taylor Swift) would
  catch regressions when YouTube changes the Singles & EPs layout.
