# YouTube Music and YouTube API Reference

> **Working reference for YouTube Music and regular YouTube InnerTube endpoints used by Kaset.**
>
> This document catalogs known YouTube Music API endpoints, their authentication requirements, implementation status, and usage patterns. The same `api-explorer` tool also supports regular YouTube via `--youtube`; see [YouTube Mode](youtube.md) for the video-source architecture.

The [implementation status](#implementation-status) records what Kaset supports, what is missing, and the evidence from the latest probes. Results are dated because endpoint behavior can change.

## Table of Contents

- [Overview](#overview)
- [Authentication](#authentication)
  - [Brand Account Support](#brand-account-support)
- [Browse Endpoints](#browse-endpoints)
  - [Implemented](#implemented-browse-endpoints)
  - [Not implemented](#not-implemented-browse-endpoints)
- [Action Endpoints](#action-endpoints)
  - [Implemented](#implemented-action-endpoints)
  - [Not implemented](#not-implemented-action-endpoints)
- [Undocumented Endpoints](#undocumented-endpoints)
- [Request Patterns](#request-patterns)
- [Response Parsing](#response-parsing)
- [Parsers Reference](#parsers-reference)
- [Error Handling](#error-handling)
- [Implementation status](#implementation-status)
- [Using the API Explorer](#using-the-api-explorer)

---

## Overview

The YouTube Music API (`youtubei/v1`) is an internal API used by the YouTube Music web client. Key characteristics:

| Property | Value |
|----------|-------|
| Base URL | `https://music.youtube.com/youtubei/v1` |
| API Key | Resolved at runtime from `INNERTUBE_API_KEY` in the YouTube Music web client config |
| Client Name | `WEB_REMIX` |
| Client Version | `1.20231204.01.00` |
| Protocol | HTTPS POST with JSON body |

Regular YouTube uses the same `youtubei/v1` protocol with different request identity:

| Property | Value |
|----------|-------|
| Base URL | `https://www.youtube.com/youtubei/v1` |
| API Key | Not required for the currently used WEB InnerTube requests |
| Client Name | `WEB` |
| Origin | `https://www.youtube.com` |

Use `swift run api-explorer --youtube ...` to target regular YouTube. Use the default mode for YouTube Music.

### Endpoint Types

1. **Browse Endpoints** - Load content pages (Home, Explore, Library, etc.)
2. **Action Endpoints** - Perform operations (Search, Like, Subscribe, etc.)

---

### Guest Mode / Unauthenticated Playback (verified 2026-07-01)

Kaset can drive a signed-out public experience without user cookies. Public
endpoint requests should be sent without signed-in browser credentials when
`AuthService` is logged out, while still using the normal WebView playback URLs
for media:

- Music playback: `https://music.youtube.com/watch?v=<videoId>`
- YouTube playback: `https://www.youtube.com/watch?v=<videoId>`

Forced signed-out API Explorer probes confirmed these public surfaces:

| Surface | Endpoint | Signed-out behavior |
|---------|----------|---------------------|
| Music search | `search` | HTTP 200; song `videoId`s returned |
| Music metadata / queue | `next` | HTTP 200; current item, lyrics tab, and queue data returned |
| Music radio | `next` with `playlistId: RDAMVM<videoId>` | HTTP 200; 50-item radio queue plus continuation |
| Music queue continuation | `continuation … next` | HTTP 200; more radio items returned |
| Music bulk queue metadata | `music/get_queue` | HTTP 200; `playlistPanelVideoRenderer` metadata returned |
| Public Music browse | `FEmusic_home`, `FEmusic_explore`, `FEmusic_charts`, `FEmusic_moods_and_genres`, `FEmusic_new_releases`, `FEmusic_podcasts` | HTTP 200 public content |
| Lyrics browse | `MPLYt...` from `next` | HTTP 200 when lyrics are public |
| YouTube search/watch-next | `--youtube search`, `--youtube next` | HTTP 200 public results / related videos; chapter markers are present in `next` for videos that expose chapters |

Personal surfaces and mutations remain sign-in-only. Gate or hide UI for:

- Music: library, history, liked music, add-to-playlist, like/dislike, save/remove from library, account/brand switching.
- YouTube: subscriptions, history, playlists, liked videos, Watch Later, subscribe/rate/comment mutations.

Do **not** rely on `/player` streaming URLs for guest playback. Signed-out
`player` probes for both WEB_REMIX and WEB returned HTTP 200 but
`playabilityStatus.status = UNPLAYABLE` and no `streamingData`; the browser
player/WebView remains the correct playback surface.

---

## Authentication

### Authentication Methods

| Method | Description | Required For |
|--------|-------------|--------------|
| **API Key Only** | Append `?key=...` to URL | Public endpoints (Charts, Player) |
| **SAPISIDHASH** | Cookie-based auth header | User library, ratings, subscriptions |

### SAPISIDHASH Generation

```swift
let origin = "https://music.youtube.com"
let timestamp = Int(Date().timeIntervalSince1970)
let hashInput = "\(timestamp) \(sapisid) \(origin)"
let hash = SHA1(hashInput)
let header = "SAPISIDHASH \(timestamp)_\(hash)"
```

For regular YouTube requests, the hash input origin must be `https://www.youtube.com`; a `music.youtube.com` hash will fail authorization against the YouTube WEB client.

### Required Cookies

| Cookie | Purpose |
|--------|---------|
| `SAPISID` | Used in SAPISIDHASH calculation |
| `__Secure-3PAPISID` | Fallback for SAPISID |
| `SID`, `HSID`, `SSID` | Session cookies |
| `LOGIN_INFO` | Login state |

### Brand Account Support

Brand accounts (YouTube channels) can be accessed by setting `context.user.onBehalfOfUser` in the request body. This is separate from the `X-Goog-AuthUser` header, which only switches between multiple Google accounts.

#### Discovering Brand Accounts

Use the `account/accounts_list` endpoint to get all accounts (primary + brand) with their IDs. An unauthenticated call can still return HTTP 200, but only with a sign-in/select response; account identities require SAPISIDHASH authentication. During an explicit account switch from Guest Mode, Kaset authorizes only this account-list refresh with the preserved signed-in session while keeping guest content published until the switch commits:

```bash
swift run api-explorer brandaccounts
```

**Response Structure**:
```
📧 Google Account: user@gmail.com

📋 Found 2 account(s):

  0: Primary Account (@handle) [Primary] ← current
  1: Brand Channel (@brand-handle) [Brand Account]
     Brand ID: <BRAND_ID>
```

**API Response Path**:
```
actions[0].getMultiPageMenuAction.menu.multiPageMenuRenderer.sections[0]
  .accountSectionListRenderer.contents[0].accountItemSectionRenderer.contents[]
```

Each brand account item contains:
- `accountName.runs[0].text` — Display name
- `channelHandle.runs[0].text` — @handle
- `serviceEndpoint.selectActiveIdentityEndpoint.supportedTokens[].pageIdToken.pageId` — Brand account ID (21-digit string)

#### Using Brand Accounts

Add the brand ID to the request body context:

```swift
let body: [String: Any] = [
    "context": [
        "client": [
            "clientName": "WEB_REMIX",
            "clientVersion": "1.20231204.01.00"
        ],
        "user": [
            "onBehalfOfUser": "<BRAND_ID>"  // Brand account ID
        ]
    ],
    "browseId": "FEmusic_liked_playlists"
]
```

**API Explorer Usage**:
```bash
# List brand accounts with IDs
swift run api-explorer brandaccounts

# Access brand account library
swift run api-explorer browse FEmusic_liked_playlists --brand <BRAND_ID>
```

#### Key Differences: authuser vs brand

| Mechanism | Header/Body | Purpose | ID Format |
|-----------|-------------|---------|-----------|
| `X-Goog-AuthUser: N` | Header | Switch between multiple Google accounts logged in | Integer index (0, 1, 2...) |
| `context.user.onBehalfOfUser` | Body | Access brand account under same Google account | 21-digit string |

> **Note**: Brand accounts are YouTube channels created under a Google account. They share the same authentication cookies but have separate libraries. The brand ID can also be found at `https://myaccount.google.com/brandaccounts` after selecting the account (appears in URL as `/b/21_digit_number`).

---

## Browse Endpoints

Browse endpoints use `POST /browse` with a `browseId` parameter.

### Implemented Browse Endpoints

| Browse ID | Name | Auth | Description | Parser |
|-----------|------|------|-------------|--------|
| `FEmusic_home` | Home | 🌐 | Personalized recommendations, mixes, quick picks | `HomeResponseParser` |
| `FEmusic_explore` | Explore | 🌐 | New releases, charts, moods shortcuts | `HomeResponseParser` |
| `FEmusic_charts` | Charts | 🌐 | Chart sections; country selection is not implemented | `HomeResponseParser` |
| `FEmusic_moods_and_genres` | Moods & Genres | 🌐 | Browse by mood/genre grids | `HomeResponseParser` |
| `FEmusic_new_releases` | New Releases | 🌐 | Recent albums, singles, videos | `HomeResponseParser` |
| `FEmusic_history` | History | 🔐 | Recently played tracks, grouped by time | `HomeResponseParser` |
| `FEmusic_library_landing` | Library Landing | 🔐 | Library content previews (playlists, albums, podcasts, artists) | `PlaylistParser.parseLibraryContent` |
| `FEmusic_liked_playlists` | Library Playlists | 🔐 | User's saved/created playlists | `PlaylistParser` |
| `FEmusic_liked_albums` | Library Albums | 🔐 | User's saved albums | `PlaylistParser.parseLibraryAlbumsPage` / `parseLibraryAlbumsContinuation` |
| `FEmusic_library_corpus_artists` | Followed Artists | 🔐 | Followed artists with public channel browse IDs | `PlaylistParser.parseLibraryArtists` |
| `FEmusic_library_privately_owned_tracks` | Uploaded Songs | 🔐 | User-uploaded songs with playlist-style rows and continuation | `PlaylistParser` |
| `VLLM` | Liked Songs | 🔐 | All songs user has liked (with pagination) | `PlaylistParser` |
| `VL{playlistId}` | Playlist Detail | 🌐 | Playlist tracks and metadata | `PlaylistParser` |
| `UC{channelId}` | Artist Detail | 🌐 | Artist page with songs, albums | `ArtistParser` |
| `MPLYt{id}` | Lyrics | 🌐 | Song lyrics text | `LyricsParser` |
| `FEmusic_podcasts` | Podcasts Discovery | 🌐 | Podcast shows and episodes carousel | `PodcastParser` |
| `MPSPP{id}` | Podcast Show Detail | 🌐 | Podcast episodes with playback progress | `PodcastParser` |

> **Note**: Charts, Moods & Genres, and New Releases all use `HomeResponseParser` since they share the same section-based response structure. `VLLM` is a special case of `VL{playlistId}` where `LM` is the Liked Music playlist ID. Do NOT use `FEmusic_liked_videos` — it returns only ~13 songs without pagination.

#### Home (`FEmusic_home`)

```swift
// Request
let body = ["browseId": "FEmusic_home"]

// Response structure
{
  "contents": {
    "singleColumnBrowseResultsRenderer": {
      "tabs": [{
        "tabRenderer": {
          "content": {
            "sectionListRenderer": {
              "contents": [/* sections */],
              "continuations": [/* for pagination */]
            }
          }
        }
      }]
    }
  }
}
```

**Sections types**: `musicCarouselShelfRenderer`, `musicImmersiveCarouselShelfRenderer`, `gridRenderer`

**Continuation**: Supports progressive loading via `getHomeContinuation()`

---

#### Explore (`FEmusic_explore`)

```swift
let body = ["browseId": "FEmusic_explore"]
```

**Sections**: New releases carousel, Charts shortcut, Moods & Genres shortcut, personalized recommendations

---

#### Library Playlists (`FEmusic_liked_playlists`)

```swift
let body = ["browseId": "FEmusic_liked_playlists"]
// Requires authentication
```

**Returns**: List of user's playlists with metadata (title, track count, thumbnail)

---

#### Library Albums (`FEmusic_liked_albums`)

```swift
let body = ["browseId": "FEmusic_liked_albums"]
// Requires authentication; params are optional for the default order
```

**Returns**: A paginated grid of saved albums with album browse IDs, artwork, artist metadata, and release year. Kaset follows grid continuation tokens until the saved-album collection is exhausted.

**Parser**: Uses `PlaylistParser.parseLibraryAlbumsPage()` for the initial response and `PlaylistParser.parseLibraryAlbumsContinuation()` for subsequent grid pages, then merges any landing-page preview albums as a fallback.

**Library mutations**: Album detail navigation uses an `MPRE...` browse ID, but `like/like` and `like/removelike` must target the album's `OLAK...` playlist ID. Album browse responses expose that playlist ID through play/queue endpoints even when the personalized Save button is unavailable.

---

#### Liked Songs (`VLLM`)

> ⚠️ **Use `VLLM`, not `FEmusic_liked_videos`** — The `FEmusic_liked_videos` browse ID returns only ~13 songs with NO continuation token. To fetch all liked songs, use `VLLM` (VL prefix + LM playlist ID) which returns the full list with proper pagination.

```swift
// ✅ Correct: Use VLLM for all liked songs
let body = ["browseId": "VLLM"]
// Requires authentication

// ❌ Avoid: FEmusic_liked_videos is limited to ~13 songs
// let body = ["browseId": "FEmusic_liked_videos"]
```

**Returns**: Playlist-format response with all liked songs and continuation token for pagination

**Parser**: Uses `PlaylistParser.parsePlaylistWithContinuation()` (same as regular playlists)

---

### Not implemented browse endpoints

These browse paths have no dedicated integration in Kaset. The notes distinguish usable responses from sign-in prompts and failed probes.

| Browse ID | Name | Auth | Notes |
|-----------|------|------|-------|
| `FEmusic_library_non_music_audio_list` | Podcast library | 🔐 | Signed-in request returned nine grid items; the app uses the Library landing preview instead |
| `FEmusic_library_non_music_audio_channels_list` | Podcast Channels filter | 🔐 | Issued params returned 25 channel rows, then 21 more through continuation |
| `FEmusic_library_user_profile_channels_list` | Library Profiles filter | 🔐 | Issued params returned one user-channel row and a message; no dedicated app integration |
| `FEmusic_library_corpus_track_artists` | Library Artists | 🔐 | Returns `MPLAUC...` library artist pages; followed artists use the implemented `FEmusic_library_corpus_artists` endpoint |
| `FEmusic_library_artists` | Library Artists, legacy route | 🔐 | Returned HTTP 400 even with full authentication; no working request established |
| `FEmusic_library_songs` | Library Songs, legacy route | 🔐 | Historical probe returned HTTP 400; the current Library Songs chip issues `FEmusic_liked_videos` |
| `FEmusic_recently_played` | Recently Played | 🔐 | Historical probe returned HTTP 400; History is implemented through `FEmusic_history` |
| `FEmusic_library_privately_owned_landing` | Uploads landing | 🔐 | No dedicated landing page; Uploaded Songs is implemented separately |
| `FEmusic_library_privately_owned_releases` | Uploaded Albums | 🔐 | Server-issued Albums chip returned a signed-in empty-state response; populated album rows remain unverified |
| `FEmusic_library_privately_owned_artists` | Uploaded Artists | 🔐 | Server-issued Artists chip returned a signed-in empty-state response; populated artist rows remain unverified |
| `FEmusic_library_privately_owned_albums` | Uploaded Albums, legacy probe | 🔐 | Guest and signed-in requests returned HTTP 400; the issued Albums route uses `privately_owned_releases` |
| Server-issued `MPTC...` | Song credits | 🌐 | Four populated credit sections returned on 2026-09-04 |
| Server-issued `MPTR...` | Related Music content | 🌐 | Recommendations, playlists, and artists returned on 2026-09-04 |
| `FEmusic_radio_builder` | Radio builder | 🌐 | Form schema returned; station creation and saving were not tested |
| `FEmusic_tastebuilder` | Taste profile | 🔐 | Signed-in response contained 1,700 item renderers across 120 lists; acceptance and selection submission were not sent |
| `FEmusic_listening_review` | Recap | 🔐 | Signed-in request returned a message, without usable Recap content |

> `FEmusic_library_corpus_track_artists` is the browseId behind the Library landing Artists chip. With authentication it returns `musicResponsiveListItemRenderer` rows whose `browseId` values look like `MPLAUC...` and use `pageType = MUSIC_PAGE_TYPE_LIBRARY_ARTIST`. Without authentication it still returns HTTP 200, but only with a sign-in prompt.
>
> `FEmusic_library_albums` is a legacy browse ID that currently returns HTTP 400. Saved albums use `FEmusic_liked_albums`; optional sorting params are not required for the default order.

### Additional browse response details

#### Uploaded Songs (`FEmusic_library_privately_owned_tracks`)

```swift
let body = ["browseId": "FEmusic_library_privately_owned_tracks"]
// Requires authentication for user content
```

**Returns**: Playlist/list-style uploaded song rows with continuation for large upload libraries.

**Parser**: Uses `PlaylistParser.parsePlaylistWithContinuation()` for the detail page and `PlaylistParser.parseUploadedSongsPlaylist()` for the Library tile. Uploaded rows may include artist metadata as plain text without a browse endpoint, so `ParsingHelpers.extractArtistsFromFlexColumns()` preserves plain artist text when no linked artist run is present.

**Unauthenticated behavior verified on May 2, 2026**: HTTP 200 with a sign-in `messageRenderer` and no track rows.

---

#### Library Landing (`FEmusic_library_landing`)

```swift
let body = ["browseId": "FEmusic_library_landing"]
// Requires authentication
```

**Response structure**:
- Returns mixed library items in a paginated `gridRenderer`
- Includes: Playlists (`VL*`), Podcasts (`MPSPP*`), artist/profile tiles (`UC*`), Profiles, Auto playlists
- Contains filter chips for: Playlists, Podcasts, Songs, Albums, Artists, Profiles
- Each chip's `browseEndpoint.browseId` provides the filtered endpoint; signed-in selections can wrap it in `commandExecutorCommand.commands`
- The landing grid may expose artist tiles as `UC*`, but the filtered Artists chip returns library-artist browse IDs instead

**Filter chip endpoints discovered**:
| Chip | browseId |
|------|----------|
| Playlists | `FEmusic_liked_playlists` |
| Podcasts | `FEmusic_library_non_music_audio_list` |
| Songs | `FEmusic_liked_videos` |
| Albums | `FEmusic_liked_albums` |
| Artists | `FEmusic_library_corpus_track_artists` |
| Profiles | `FEmusic_library_user_profile_channels_list` (with params) |

**Artists chip behavior**:
- `FEmusic_library_corpus_track_artists` returns a `sectionListRenderer` of `musicResponsiveListItemRenderer` rows
- Signed-in artist rows navigate to `browseEndpoint.browseId = MPLAUC...`
- Those browse IDs use `pageType = MUSIC_PAGE_TYPE_LIBRARY_ARTIST`
- Without authentication, the same endpoint responds with HTTP 200 and a sign-in prompt instead of artist rows

**Item identification by browseId prefix**:
- `VL*`, `PL*`, `RDCLAK*` — Playlists
- `MPSPP*` — Podcast shows (see [Podcast ID Format](#podcast-id-format) below)
- `UC*` — Artists or Profiles
- `MPLAUC*` — Library artist pages returned by the Artists chip (direct browse requires auth)
- `VLLM` — Liked Music auto playlist
- `VLRDPN` — New Episodes auto playlist
- `VLSE` — Episodes for Later auto playlist

#### Podcast ID Format

Podcast show IDs follow a specific structure that requires conversion for subscription operations:

| ID Type | Format | Example |
|---------|--------|---------|
| Show Browse ID | `MPSPP` + `L` + `{base64suffix}` | `MPSPPLXz2p9abc123def` |
| Playlist ID (for API) | `PL` + `{base64suffix}` | `PLXz2p9abc123def` |

**Conversion Logic**:
```swift
// MPSPP IDs are structured as: "MPSPP" + "L" + {idSuffix}
// To convert to playlist ID: strip "MPSPP" (5 chars), prepend "P"
let suffix = String(showId.dropFirst(5))  // "LXz2p9abc123def"
let playlistId = "P" + suffix              // "PLXz2p9abc123def"
```

> ⚠️ **Critical**: The suffix already starts with `L`. Adding `"PL"` instead of `"P"` creates a double-L (`PLLXz2p9...`) which causes HTTP 404 errors. Always use `"P" + suffix`, never `"PL" + suffix`.

**Validation Requirements** (implemented in `YTMusicClient.convertPodcastShowIdToPlaylistId`):
1. ID must have `MPSPP` prefix (warns and passes through if missing)
2. Suffix after stripping `MPSPP` must not be empty (throws)
3. Suffix must start with `L` (throws)

---

#### Charts (`FEmusic_charts`)

```swift
let body = ["browseId": "FEmusic_charts"]
```

**Response structure**:
- Top songs chart (ranked list)
- Top albums chart
- Trending videos
- Genre-specific charts
- Country-specific charts via `formData.selectedValues`, revalidated 2026-09-04

The country menu exposes `musicMultiSelectMenuItemRenderer` entries backed by
`frameworkUpdates.entityBatchUpdate.mutations[].payload.musicFormBooleanChoice`.
The observed `opaqueToken` values are two-letter country codes, including `ZZ`
for Global. A Japan request returned HTTP 200 with `JP` selected:

```json
{"browseId":"FEmusic_charts","formData":{"selectedValues":["JP"]}}
```

This chart selection is separate from the client's `context.client.gl` value.
Do not generalize chart form handling to other browse IDs: tastebuilder forms
can change recommendation preferences.

**Kaset status**: Chart sections and pagination are implemented. Country choices,
selection requests, and a country picker are not implemented. See the
[country discovery details](#chart-countries) for the observed menu and response.

---

#### Moods & Genres (`FEmusic_moods_and_genres`)

```swift
let body = ["browseId": "FEmusic_moods_and_genres"]
```

**Response structure**:
- Grid of moods (Chill, Focus, Workout, Party, etc.)
- Grid of genres (Pop, Rock, Hip-Hop, R&B, etc.)

Each item links to a playlist or browse endpoint for that mood/genre.

As verified on July 13, 2026, mood and genre cards use the browse ID
`FEmusic_moods_and_genres_category` with an opaque `params` value. Keep the
browse ID and params as separate structured fields when parsing; concatenated
display IDs are not a safe source for reconstructing navigation endpoints.

---

#### History (`FEmusic_history`)

```swift
let body = ["browseId": "FEmusic_history"]
// Requires authentication
```

**Response structure**:
- Sections organized by time (Today, Yesterday, This Week, etc.)
- Each section contains recently played tracks

---

#### New Releases (`FEmusic_new_releases`)

```swift
let body = ["browseId": "FEmusic_new_releases"]
```

**Response structure**:
- New albums grid
- New singles
- New music videos

---

## Action Endpoints

Action endpoints perform operations or fetch specific data.

### Implemented Action Endpoints

| Endpoint | Name | Auth | Description |
|----------|------|------|-------------|
| `search` | Search | 🌐 | Search songs, videos, albums/audiobooks, artists/profiles, playlists, podcasts, and episodes |
| `music/get_search_suggestions` | Suggestions | 🌐 | Autocomplete for search |
| `next` | Now Playing | 🌐 | Track info, lyrics ID, radio queue |
| `music/get_queue` | Get Queue | 🌐 | Metadata for video IDs and playlist queues |
| `like/like` | Like | 🔐 | Like a song/album/playlist |
| `like/dislike` | Dislike | 🔐 | Dislike a song |
| `like/removelike` | Remove Like | 🔐 | Remove like/dislike rating |
| `feedback` | Feedback | 🔐 | Add/remove from library via tokens |
| `subscription/subscribe` | Subscribe | 🔐 | Subscribe to artist |
| `subscription/unsubscribe` | Unsubscribe | 🔐 | Unsubscribe from artist |
| `account/accounts_list` | Accounts List | 🔐 | List all accounts (primary + brand) |
| `account/account_menu` | Account Menu | 🔐 | Current account info and settings |
| `playlist/get_add_to_playlist` | Add-to-Playlist Menu | 🔐 | Playlist choices cached with library TTL |
| `browse/edit_playlist` | Edit Playlist | 🔐 | Add/remove tracks and invalidate affected caches |
| `playlist/create` | Create Playlist | 🔐 | Create a playlist, optionally with seed videos |
| `playlist/delete` | Delete Playlist | 🔐 | Delete a user-owned playlist when the response exposes that action |
| `guide` | YouTube Guide | 🔐 | Regular YouTube subscriptions; no Music sidebar integration |

---

#### Search (`search`)

```swift
let body = ["query": "never gonna give you up"]
```

**Response Structure**:
- `musicCardShelfRenderer` — **Top Result** section. Its title can navigate through either `browseEndpoint` or `watchEndpoint`, and its `contents` can include additional rows.
- `itemSectionRenderer.contents[]` — Current mixed-search rows. Each wrapper commonly contains one `musicResponsiveListItemRenderer`.
- `musicShelfRenderer` — Filtered result lists and occasional direct mixed-search sections.
- `musicResponsiveListItemRenderer` — Songs, videos, albums, audiobooks, artists, profiles, playlists, podcast shows, and podcast episodes.

> ⚠️ **Important**: Revalidated on 2026-07-19, mixed search no longer consistently returns direct `musicShelfRenderer` sections. Parse `musicCardShelfRenderer`, its nested `contents`, direct `musicShelfRenderer`, and `itemSectionRenderer.contents`. Top Results can be directly playable `watchEndpoint` videos, not only browse destinations.

**Top Result Example** (searching "manifest"):
```json
{
  "musicCardShelfRenderer": {
    "title": {
      "runs": [{
        "text": "manifest",
        "navigationEndpoint": {
          "browseEndpoint": {
            "browseId": "UCavTTSUSD6aYPeF-F3ND9Yg",
            "browseEndpointContextSupportedConfigs": {
              "browseEndpointContextMusicConfig": {
                "pageType": "MUSIC_PAGE_TYPE_ARTIST"
              }
            }
          }
        }
      }]
    },
    "subtitle": { "runs": [{ "text": "Artist • 19.1M monthly audience" }] },
    "thumbnail": { ... },
    "contents": [ /* related songs/albums */ ]
  }
}
```

**Observed mixed result types (guest session, 2026-07-19)**:

- `Song` — usually `MUSIC_VIDEO_TYPE_ATV`
- `Video` — `MUSIC_VIDEO_TYPE_OMV` or `MUSIC_VIDEO_TYPE_UGC`
- `Album`
- `Audiobook` — `MUSIC_PAGE_TYPE_AUDIOBOOK`; currently uses an album-like `MPRE...` browse destination
- `Artist`
- `Profile` — `MUSIC_PAGE_TYPE_USER_CHANNEL`
- `Playlist`
- `Podcast` — `MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE`
- `Episode` — `MUSIC_VIDEO_TYPE_PODCAST_EPISODE` with an `MPED...` title destination

Playable rows can expose the same video ID through several paths:

```text
playlistItemData.videoId
navigationEndpoint.watchEndpoint.videoId
flexColumns[0]...runs[0].navigationEndpoint.watchEndpoint.videoId
overlay...musicPlayButtonRenderer.playNavigationEndpoint.watchEndpoint.videoId
```

Browse rows commonly use `musicResponsiveListItemRenderer.navigationEndpoint.browseEndpoint`.

**Parser**: `SearchResponseParser`. The API shape audit command below reports which live rows the current parser can and cannot reach.

**Filter Params** (base64-encoded filter values for `params` field):

| Filter | Param Value | Description |
|--------|-------------|-------------|
| Songs | `EgWKAQIIAWoMEA4QChADEAQQCRAF` | Filter to songs only |
| Albums | `EgWKAQIYAWoMEA4QChADEAQQCRAF` | Filter to albums only |
| Artists | `EgWKAQIgAWoMEA4QChADEAQQCRAF` | Filter to artists only |
| Playlists | `EgWKAQIoAWoMEA4QChADEAQQCRAF` | Filter to all playlists |
| Featured Playlists | `EgeKAQQoADgBagwQDhAKEAMQBBAJEAU=` | YouTube Music curated playlists |
| Community Playlists | `EgeKAQQoAEABagwQDhAKEAMQBBAJEAU=` | User-created playlists |
| Podcasts | `EgWKAQJQAWoQEBAQCRAEEAMQBRAKEBUQEQ%3D%3D` | Filter to podcast shows only |

> **Static params vs. live chips**: The table above records Kaset's existing no-spelling-correction params. Live `chipCloudChipRenderer.navigationEndpoint.searchEndpoint.params` values are contextual: the same filter label had different complete suffixes for different queries on 2026-07-19. Do not assume one server-issued full params value is universal.

Observed filter type codes in live chips:

| Live Filter | Encoded Type Code | Current Kaset Filter |
|-------------|-------------------|----------------------|
| Songs | `II` | ✅ |
| Videos | `IQ` | ✅ |
| Albums | `IY` | ✅ |
| Artists | `Ig` | ✅ |
| Profiles | `JY` | ✅ |
| Episodes | `JI` | ✅ |
| Podcasts | `JQ` | ✅ |
| Community / Featured playlists | Specialized playlist params | ✅ |

**Usage Example** (podcasts):
```swift
let body: [String: Any] = [
    "query": "crime weekly",
    "params": "EgWKAQJQAWoQEBAQCRAEEAMQBRAKEBUQEQ%3D%3D"
]
```

**Filtered Search Continuation** (revalidated 2026-07-19):

The first-page token is carried by the shelf, not the enclosing section list:

```text
contents.tabbedSearchResultsRenderer.tabs[0].tabRenderer.content
  .sectionListRenderer.contents[].musicShelfRenderer
  .continuations[0].nextContinuationData.continuation
```

Send that token back to the `search` endpoint:

```swift
let body = ["continuation": token]
// POST /youtubei/v1/search
```

The common response uses:

```text
continuationContents.musicShelfContinuation.contents[]
continuationContents.musicShelfContinuation.continuations[]
```

Search continuations can also use action envelopes. Preserve action order and parse both append and reload commands:

```text
onResponseReceivedActions[] | onResponseReceivedCommands[] | onResponseReceivedEndpoints[]
  .appendContinuationItemsAction.continuationItems[]
  .reloadContinuationItemsCommand.continuationItems[]
```

The `continuationItems` array can mix result renderers with a trailing `continuationItemRenderer` carrying the next token. `SearchResponseParser.parseContinuation` supports both the shelf envelope and these action envelopes.

Sending the captured search token to `browse` returned unrelated browse/home sections in the same guest session, not the next search page.

**Deep audit command**:

```bash
swift run api-explorer --guest search-audit "ambient electronic mix"
```

This probes the unfiltered response, every live filter chip, and one `/search` continuation page per filter when offered. It reports renderer wrappers, destination paths, content/page types, token carrier locations, and current mixed-parser coverage without printing continuation values.

To compare a response against Kaset's currently configured WEB_REMIX version instead of the live web version resolved by API Explorer:

```bash
swift run api-explorer --guest --client-version 1.20231204.01.00 \
  search-audit "ambient electronic mix"
```

`search-audit` labels the client-version source as `live`, `override`, or `fallback`. When it reports `fallback`, use `--client-version` before drawing a version-comparison conclusion. API Explorer also resolves the live version independently when the API key comes from its environment override.

For this query, the live version `1.20260715.04.00` and Kaset's configured `1.20231204.01.00` showed no structural difference in section wrappers, result-type counts, filter chips, or continuation carriers. This does not prove that every result identity was identical or fully rule out version-specific behavior; it does show that the observed parser gaps reproduce with Kaset's configured version.

A July 19, 2026 guest audit matrix covering the reported query, `Taylor Swift`, `The Daily podcast`, and `lofi hip hop` found no unhandled result rows after the parser update. It also exposed `MUSIC_PAGE_TYPE_AUDIOBOOK` inside mixed and Albums-filter results; Kaset now keeps those results semantically distinct as audiobooks while reusing the existing album payload and playlist-style detail navigation.

`search-audit` labels the version source as `live`, `override`, or `fallback`. The audit performs a bounded live-version lookup even when `KASET_YTMUSIC_API_KEY` supplies the API key; unrelated API Explorer commands keep the environment override's immediate behavior. If web configuration discovery fails, the report explicitly identifies the configured fallback instead of presenting it as live.

---

#### Search Suggestions (`music/get_search_suggestions`)

```swift
let body = ["input": "never gon"]
```

**Response**: Array of suggestion strings and search history.

**Parser**: `SearchSuggestionsParser`

---

#### Next / Now Playing (`next`)

```swift
let body: [String: Any] = [
    "videoId": "dQw4w9WgXcQ",
    "enablePersistentPlaylistPanel": true,
    "isAudioOnly": true,
    "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"
]
```

**Response contains**:
- Current track metadata
- Lyrics browse ID (in tabs)
- Related tracks / autoplay queue
- Feedback tokens for library actions
- Continuation token for infinite mix (in `playlistPanelRenderer.continuations`)

**Used for**:
- `getLyrics(videoId:)` - Extracts lyrics browse ID
- `getSong(videoId:)` - Gets full song metadata with tokens
- `getRadioQueue(videoId:)` - Gets radio mix (with `playlistId: "RDAMVM{videoId}"`)
- `getMixQueue(playlistId:)` - Gets artist mix (with `playlistId: "RDEM..."`)

**Continuation (Infinite Mix)**:

For mix playlists, the response includes a continuation token at:
```
playlistPanelRenderer.continuations[0].nextRadioContinuationData.continuation
```

To fetch more songs:
```swift
let body: [String: Any] = [
    "continuation": token,
    "enablePersistentPlaylistPanel": true,
    "isAudioOnly": true
]
_ = try await request("next", body: body)
```

Response structure: `continuationContents.playlistPanelContinuation.contents`

---

#### Like/Dislike (`like/*`)

```swift
// Like a song
let body = ["target": ["videoId": "dQw4w9WgXcQ"]]
_ = try await request("like/like", body: body)

// Like a playlist
let body = ["target": ["playlistId": "PLxyz..."]]
_ = try await request("like/like", body: body)

// Remove like
_ = try await request("like/removelike", body: body)
```

---

#### Feedback (Library Management)

```swift
// Add to library using token from song metadata
let body = ["feedbackTokens": [addToken]]
_ = try await request("feedback", body: body)
```

Tokens come from `getSong(videoId:)` response. `FeedbackTokens.add` and
`FeedbackTokens.remove` are action-specific: select the add token when the
target state is in-library and the remove token when the target state is
out-of-library. Keep the known pair stable across optimistic UI updates; do not
swap the fields. A later authoritative metadata response may replace or rotate
the pair.

`api-explorer` reports library feedback action structure without printing token
values. It can also inspect a saved response safely:

```bash
swift run api-explorer analyze-file path/to/response.json
```

---

#### Subscribe/Unsubscribe

**Artist Subscription** (uses channel ID):
```swift
let body = ["channelIds": ["UCuAXFkgsw1L7xaCfnd5JJOw"]]
_ = try await request("subscription/subscribe", body: body)
```

**Podcast Subscription** (uses like/like endpoint with converted playlist ID):
```swift
// Podcast show IDs have MPSPP prefix (e.g., "MPSPPLXz2p9...")
// The suffix after MPSPP already starts with "L", so:
// - Strip "MPSPP" (5 chars) to get "LXz2p9..."  
// - Prepend "P" to get "PLXz2p9..."
//
// ⚠️ IMPORTANT: Do NOT add "PL" prefix - that would create "PLLXz2p9..." which returns 404!

// Subscribe to podcast (add to library)
let suffix = String(showId.dropFirst(5)) // Drop "MPSPP"
let playlistId = "P" + suffix            // Prepend "P" only
let body = ["target": ["playlistId": playlistId]]
_ = try await request("like/like", body: body)

// Unsubscribe from podcast (remove from library)
let body = ["target": ["playlistId": playlistId]]
_ = try await request("like/removelike", body: body)
```

> ⚠️ **Note**: Podcast subscription uses `like/like` and `like/removelike` endpoints, NOT `subscription/*`. The MPSPP browse ID must be converted to a PL playlist ID by stripping "MPSPP" and prepending "P" (not "PL").

---

### Not implemented action endpoints

| Endpoint | Name | Auth | Notes |
|----------|------|------|-------|
| `player` | Player | 🌐 | No direct native-client integration; playback uses WebView. Guest responses can be `UNPLAYABLE` without streaming data |
| `get_transcript` | YouTube Transcript | Unverified | Server-issued commands found, but both guest replays returned HTTP 400 on 2026-09-04. Captions are implemented separately |

---

### Additional action response details

#### Player (`player`)

```swift
let body = ["videoId": "dQw4w9WgXcQ"]
```

**Historical response example**: The 2024 probe included streaming data. On
2026-07-01, guest Music and YouTube requests instead returned `UNPLAYABLE`
without `streamingData`. HTTP 200 alone does not establish playability.
```json
{
  "playabilityStatus": { "status": "OK" },
  "streamingData": {
    "formats": [...],
    "adaptiveFormats": [...]
  },
  "videoDetails": {
    "videoId": "dQw4w9WgXcQ",
    "title": "Rick Astley - Never Gonna Give You Up",
    "lengthSeconds": "213",
    "author": "Rick Astley",
    "channelId": "UCuAXFkgsw1L7xaCfnd5JJOw",
    "thumbnail": { "thumbnails": [...] },
    "viewCount": "1500000000",
    "isLiveContent": false,
    "musicVideoType": "MUSIC_VIDEO_TYPE_ATV"
  },
  "captions": { ... },
  "storyboards": { ... },
  "microformat": { ... }
}
```

**Full response keys** (verified):
- `responseContext`, `playabilityStatus`, `streamingData`, `playerAds`
- `playbackTracking`, `captions`, `videoDetails`, `annotations`
- `playerConfig`, `storyboards`, `microformat`, `cards`
- `trackingParams`, `messages`, `endscreen`, `adPlacements`, `adSlots`

**videoDetails keys**:
- `videoId`, `title`, `lengthSeconds`, `channelId`, `author`
- `thumbnail`, `viewCount`, `isPrivate`, `musicVideoType`, `isLiveContent`

**streamingData** (26 adaptive formats available):
- `expiresInSeconds`, `formats`, `adaptiveFormats`, `serverAbrStreamingUrl`
- Audio formats include: `audio/mp4; codecs="mp4a.40.2"` at ~130kbps

**Use cases**:
- Quick metadata lookup (title, duration, author)
- Get video duration without `next` call
- Check playability status before attempting playback
- Get thumbnail URLs

---

#### Get Queue (`music/get_queue`)

```swift
// Get metadata for specific videos
let body = ["videoIds": ["dQw4w9WgXcQ", "fJ9rUzIMcZQ"]]

// OR get ALL tracks for a playlist (bypasses pagination!)
let body = ["playlistId": "RDCLAK5uy_l2pHac-aawJYLcesgTf67gaKU-B9ekk1o"]
```

**Response** (works WITHOUT auth! - verified):
```json
{
  "responseContext": {...},
  "queueDatas": [{
    "content": {
      "playlistPanelVideoWrapperRenderer": {
        "primaryRenderer": {
          "playlistPanelVideoRenderer": {
            "title": {"runs": [{"text": "Never Gonna Give You Up"}]},
            "longBylineText": {...},
            "thumbnail": {...},
            "lengthText": {...},
            "videoId": "dQw4w9WgXcQ",
            "shortBylineText": {...},
            "menu": {...},
            "navigationEndpoint": {...}
          }
        }
      }
    }
  }],
  "queueContextParams": "..."
}
```

> ⚠️ **Note**: Responses can contain either a direct `playlistPanelVideoRenderer` or a **wrapper structure** (`playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer`). Parsers must handle both.

**playlistPanelVideoRenderer keys** (verified):
- `title`, `longBylineText`, `thumbnail`, `lengthText`
- `selected`, `navigationEndpoint`, `videoId`, `shortBylineText`
- `trackingParams`, `menu`

Artist navigation, verified with guest requests for **Chill R&B** and **Country Summer** on 2026-09-04:

- `shortBylineText` contains a single display-only run, such as `COLORS & Tems`, without artist browse endpoints.
- `longBylineText` contains separate artist runs with `UC...` browse endpoints. Ampersands or commas separate co-artists; a bullet separates the artists from view and like counts.
- Parse artists from the long byline, stopping before trailing metadata. Use the short byline as a fallback when the long byline has no artists.

**Use cases**:
- Get metadata for multiple videos in one call (queue display)
- **Fetch ALL tracks for radio playlists** (RDCLAK prefix) where browse pagination is broken

---

#### Playlist Management

All playlist management endpoints require authentication (HTTP 401 without auth). The app exposes these through `YTMusicClientProtocol` so context menus and view models can be tested with mocks.

##### Add-to-Playlist Menu (`playlist/get_add_to_playlist`)

```swift
let body: [String: Any] = [
    "videoIds": ["dQw4w9WgXcQ"],
]
let response = try await request("playlist/get_add_to_playlist", body: body, ttl: APICache.TTL.library)
let menu = PlaylistParser.parseAddToPlaylistMenu(response)
```

Parser notes:
- The useful payload is usually under `addToPlaylistRenderer`; parser falls back to the root dictionary if that wrapper is absent.
- Playlist options are only read from known option renderer wrappers: `playlistAddToOptionRenderer`, `addToPlaylistItemRenderer`, `musicResponsiveListItemRenderer`, and `musicTwoRowItemRenderer`. Do not treat arbitrary parent containers as options just because they contain a nested `playlistId`.
- Options are deduplicated by `playlistId` and expose title, subtitle, thumbnail, selected/checked state, and optional privacy status.
- `canCreatePlaylist` is true only when the renderer contains `createPlaylistEndpoint`; do not infer create support from display text containing "Create".
- The submenu disables already-selected playlists and only shows "Create Playlist…" when `canCreatePlaylist` is true.

Representative shape:

```json
{
  "addToPlaylistRenderer": {
    "title": { "runs": [{ "text": "Add to playlist" }] },
    "contents": [
      {
        "playlistAddToOptionRenderer": {
          "title": { "runs": [{ "text": "Road Trip" }] },
          "subtitle": { "runs": [{ "text": "Private" }] },
          "selected": true,
          "serviceEndpoint": {
            "playlistEditEndpoint": { "playlistId": "PLROADTRIP" }
          }
        }
      }
    ],
    "createPlaylistEndpoint": {}
  }
}
```

##### Add Song to Playlist (`browse/edit_playlist`)

```swift
let cleanPlaylistId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
let body: [String: Any] = [
    "playlistId": cleanPlaylistId,
    "actions": [[
        "action": "ACTION_ADD_VIDEO",
        "addedVideoId": "dQw4w9WgXcQ",
    ]],
]
try await request("browse/edit_playlist", body: body)
```

Implementation notes:
- Strip a leading `VL` from playlist browse IDs before sending mutation requests.
- The `allowDuplicate` client parameter is reserved for future UI; YouTube Music currently handles duplicate behavior server-side.
- Successful mutations call `APICache.invalidateMutationCaches()`, which clears `browse:`, `next:`, `like:`, and `playlist/get_add_to_playlist:` entries so library views, metadata, and add-to-playlist menus refresh.

##### Create Playlist (`playlist/create`)

```swift
var body: [String: Any] = [
    "title": "My Playlist",
    "privacyStatus": PlaylistPrivacyStatus.private.rawValue, // PRIVATE, UNLISTED, PUBLIC
]
body["description"] = "Optional description" // omit when blank
body["videoIds"] = ["dQw4w9WgXcQ"]        // omit when empty

let response = try await request("playlist/create", body: body)
let playlistId = PlaylistParser.parseCreatedPlaylistId(response)
```

Parser notes:
- Prefer a non-empty top-level `playlistId`.
- Fall back to known nested response shapes such as toast `notificationTextRenderer.navigationEndpoint.browseEndpoint.playlistId`, action navigation endpoints, or `command.browseEndpoint.playlistId`.
- If no playlist ID can be found, throw a parse error rather than assuming creation succeeded.

Representative response shapes observed by tests:

```json
{ "playlistId": "PLCREATED123", "status": "STATUS_SUCCEEDED" }
```

```json
{
  "actions": [
    {
      "addToToastAction": {
        "item": {
          "notificationTextRenderer": {
            "responseText": { "runs": [{ "text": "Playlist created" }] },
            "navigationEndpoint": {
              "browseEndpoint": { "playlistId": "PLNESTED456" }
            }
          }
        }
      }
    }
  ]
}
```

##### Delete Playlist (`playlist/delete`)

```swift
let cleanPlaylistId = playlistId.hasPrefix("VL") ? String(playlistId.dropFirst(2)) : playlistId
try await request("playlist/delete", body: ["playlistId": cleanPlaylistId])
```

Implementation notes:
- Only expose destructive delete UI when parsed playlist data indicates the signed-in user can delete it.
- `Playlist.canDelete` / `PlaylistDetail.canDelete` is derived from payload affordances such as `deletePlaylistEndpoint`, `musicEditablePlaylistDetailHeaderRenderer`, or `playlist/delete` command text; unknown ownership defaults to false.
- Delete mutations also invalidate mutation-affected app caches.

---

## Undocumented Endpoints

These endpoints were discovered through API exploration (2024-12-22) but are not part of the documented API surface. Some may be useful for app functionality.

### Potentially Useful Undocumented Endpoints

| Endpoint | Type | Auth | Parameters | Description |
|----------|------|------|------------|-------------|
| `FEmusic_radio_builder` | Browse | 🌐 | - | Form dialog and chips verified on 2026-09-04; station creation/saving not tested or implemented |
| `FEmusic_liked_videos` | Browse | 🔐 | - | Limited liked-song list; Kaset uses `VLLM` for pagination |

### Infrastructure/Internal Endpoints

These endpoints exist but are primarily for YouTube's internal use:

| Endpoint | Type | Auth | Parameters | Notes |
|----------|------|------|------------|-------|
| `account/account_menu` | Action | 🌐/🔐 | `{}` | Returns account menu structure (settings, premium promo) |
| `reel/reel_item_watch` | Action | 🌐 | `{}` | Returns status tracking params (YouTube Shorts related) |
| `log_event` | Action | 🌐 | `{}` | Analytics/telemetry logging endpoint |
| `att/get` | Action | 🌐 | `{}` | Anti-bot/botguard challenge data |
| `FEmusic_listening_review` | Browse | 🔐 | - | Signed-in sample returned a message; usable Recap content remains unverified |

### Endpoints Requiring Parameters

These endpoints exist but return HTTP 400 without proper parameters:

| Endpoint | Type | Auth | Status | Notes |
|----------|------|------|--------|-------|
| `comment/create_comment` | Action | 🔐 | 400 | Needs `videoId`, `commentText` |
| `comment/perform_comment_action` | Action | 🔐 | 400 | Needs action params |
| `share/get_share_panel` | Action | 🌐 | 400 | Needs `videoId` |
| `get_transcript` | Action | Unverified | 400 | Server-issued WEB `next` params also returned HTTP 400 on 2026-09-04; a working request context remains unverified |
| `live_chat/send_message` | Action | 🔐 | 400 | Needs chat params |
| `notification/get_unseen_count` | Action | 🔐 | 400 | Needs user context |

### Endpoints Requiring Authentication

| Endpoint | Type | Status | Notes |
|----------|------|--------|-------|
| `playlist/delete` | Action | 401 | Requires SAPISIDHASH |
| `flag/get_form` | Action | 401 | Content flagging (needs auth) |
| `notification/modify_channel_preference` | Action | 401 | Notification settings |

---

## Request Patterns

### Standard Request Structure

```swift
// URL
POST https://music.youtube.com/youtubei/v1/{endpoint}?key={apiKey}&prettyPrint=false

// Headers
Content-Type: application/json
Cookie: {cookies}
Authorization: SAPISIDHASH {timestamp}_{hash}
Origin: https://music.youtube.com
X-Goog-AuthUser: 0

// Body
{
  "context": {
    "client": {
      "clientName": "WEB_REMIX",
      "clientVersion": "1.20231204.01.00",
      "hl": "en",
      "gl": "US"
    }
  },
  // ... endpoint-specific params
}
```

### Continuation Pattern

For paginated content:

```swift
// First request
let body = ["browseId": "FEmusic_home"]
let response = try await request("browse", body: body)
let token = extractContinuationToken(response)

// Continuation request
let body = ["continuation": token]
let more = try await request("browse", body: body)
```

---

## Response Parsing

### Common Renderer Types

| Renderer | Purpose |
|----------|---------|
| `musicCarouselShelfRenderer` | Horizontal scrolling shelf |
| `musicImmersiveCarouselShelfRenderer` | Hero carousel |
| `musicCardShelfRenderer` | **Top Result** in search (single prominent item with related content) |
| `gridRenderer` | Grid of items |
| `musicShelfRenderer` | Vertical list (search results, artist songs) |
| `musicTwoRowItemRenderer` | Album/playlist card |
| `musicResponsiveListItemRenderer` | Song row |
| `playlistPanelVideoRenderer` | Queue/playlist item |

### Navigation Extraction

```swift
// Extract browse ID from item
if let navEndpoint = item["navigationEndpoint"] as? [String: Any],
   let browseEndpoint = navEndpoint["browseEndpoint"] as? [String: Any],
   let browseId = browseEndpoint["browseId"] as? String {
    // Use browseId
}

// Extract video ID
if let watchEndpoint = navEndpoint["watchEndpoint"] as? [String: Any],
   let videoId = watchEndpoint["videoId"] as? String {
    // Use videoId
}
```

---

## Parsers Reference

All parsers are located in `Sources/Kaset/Services/API/Parsers/`. Each parser is responsible for extracting structured data from raw API JSON responses.

| Parser | File | Input | Output | Used By |
|--------|------|-------|--------|--------|
| `HomeResponseParser` | `HomeResponseParser.swift` | Home/Explore browse response | `HomeResponse` with `[HomeSection]` | `FEmusic_home`, `FEmusic_explore` |
| `SearchResponseParser` | `SearchResponseParser.swift` | Search response | `SearchResponse` with songs, albums, artists, playlists | `search` endpoint |
| `SearchSuggestionsParser` | `SearchSuggestionsParser.swift` | Suggestions response | `[SearchSuggestion]` | `music/get_search_suggestions` |
| `PlaylistParser` | `PlaylistParser.swift` | Playlist/library response | `[Playlist]`, `[Album]`, `LibraryContent` | `VL{id}`, `VLLM`, `FEmusic_liked_playlists`, `FEmusic_liked_albums`, `FEmusic_library_landing` |
| `ArtistParser` | `ArtistParser.swift` | Artist browse response | `ArtistDetail` with songs, albums | `UC{channelId}` |
| `LyricsParser` | `LyricsParser.swift` | Next/lyrics response | `Lyrics` or lyrics browse ID | `next`, `MPLYt{id}` |
| `PodcastParser` | `PodcastParser.swift` | Podcast browse response | `[PodcastSection]`, `PodcastShowDetail` | `FEmusic_podcasts`, `MPSPP{id}` |
| `AccountsListParser` | `AccountsListParser.swift` | Accounts list response | `AccountsListResponse` with `[UserAccount]` | `account/accounts_list` |
| `SongMetadataParser` | `SongMetadataParser.swift` | Next endpoint response | `Song` with full metadata | `next` endpoint |
| `RadioQueueParser` | `RadioQueueParser.swift` | Next endpoint response | `RadioQueueResult` with songs + continuation | Radio/mix playback |
| `ParsingHelpers` | `ParsingHelpers.swift` | Various | Utility functions (stable IDs, text extraction) | All parsers |

### Parser Patterns

**Common extraction helpers** (from `ParsingHelpers`):

```swift
// Extract text from runs array
ParsingHelpers.extractText(from: titleRuns)  // -> "Song Title"

// Generate stable ID for SwiftUI
ParsingHelpers.stableId(title: "Section", components: "item1")  // -> deterministic hash

// Extract thumbnail URL with size preference
ParsingHelpers.extractThumbnailURL(from: thumbnails, preferredSize: 226)
```

**Common response structure**:
```
contents
  -> singleColumnBrowseResultsRenderer
    -> tabs[0]
      -> tabRenderer
        -> content
          -> sectionListRenderer
            -> contents[]  <- iterate here for sections
```

---

## Error Handling

Kaset uses a unified `YTMusicError` enum for all API-related errors. This enables consistent error handling, user-friendly messages, and retry logic.

### Error Types

| Error | When Thrown | Retryable | User Action |
|-------|-------------|-----------|-------------|
| `authExpired` | HTTP 401/403, invalid SAPISIDHASH | ❌ | Sign in again |
| `notAuthenticated` | No cookies available for auth-required endpoint | ❌ | Sign in |
| `networkError(underlying:)` | Connection failed, timeout, DNS failure | ✅ | Check connection |
| `parseError(message:)` | Unexpected JSON structure, missing required fields | ❌ | Report bug |
| `apiError(message:, code:)` | API returned error response | ✅ (5xx only) | Try again |
| `playbackError(message:)` | WebView playback failed, DRM error | ✅ | Try different track |
| `invalidInput(message:)` | Invalid video ID, empty query | ❌ | Fix input |
| `unknown(message:)` | Catch-all for unexpected errors | ✅ | Try again |

### Error Properties

```swift
let error: YTMusicError = .networkError(underlying: urlError)

error.errorDescription     // "Network error: The Internet connection appears to be offline."
error.recoverySuggestion   // "Check your internet connection and try again."
error.userFriendlyTitle    // "Connection Error"
error.userFriendlyMessage  // "Unable to connect. Please check your internet connection."
error.requiresReauth       // false
error.isRetryable          // true
```

### Handling in Views

```swift
// In ViewModel
func load() async {
    do {
        self.data = try await client.fetchData()
    } catch let error as YTMusicError {
        if error.requiresReauth {
            self.showLoginSheet = true
        } else if error.isRetryable {
            self.errorMessage = error.userFriendlyMessage
            self.showRetryButton = true
        } else {
            self.errorMessage = error.userFriendlyMessage
        }
    }
}
```

### Retry Logic

Use `RetryPolicy` for automatic retries with exponential backoff:

```swift
let result = try await RetryPolicy.execute(
    maxAttempts: 3,
    initialDelay: .seconds(1),
    shouldRetry: { error in
        (error as? YTMusicError)?.isRetryable ?? false
    }
) {
    try await client.fetchData()
}
```

---

## Implementation status

Checked against the app source on 2026-09-04. Status refers to Kaset integration,
not API Explorer support. Partial means the existing behavior and missing parts
are listed separately in the same row.

| Capability | Kaset status | Implemented and missing behavior |
|------------|--------------|----------------------------------|
| Home, Explore, Moods & Genres, New Releases | Implemented | Browse pages and section parsing exist; Home activity chips are listed separately below |
| Listening history | Implemented | Recently played tracks grouped by time |
| Saved albums | Implemented | Album collection with grid pagination |
| Library content-type filtering | Partial | Local filters cover the existing collections; the server's Songs, Profiles, and podcast Channels filters are not integrated |
| Library playlists and followed artists | Partial | Dedicated loads display the initial page; complete collection pagination and sorting are not implemented |
| Library sorting | Not implemented | Signed-in Library and playlist sort reloads are verified; no native sorting controls or sort-specific continuation state |
| Library Profiles | Not implemented | The server-issued Profiles route works; no dedicated profile collection or Library filter |
| Uploaded Songs | Implemented | Library tile, playlist-style track rows, and track pagination |
| Playlist creation, track editing, and deletion | Implemented | Add/remove tracks, create playlists, and delete playlists with ownership checks |
| Podcasts | Partial | Discovery, show pages, episode progress, and played-state display exist; dedicated Library/Channels requests and explicit Resume and Start Over controls are not implemented |
| Captions | Implemented | Playback captions exist; a native transcript panel is separate |
| Music video type parsing | Implemented | Includes `MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC` |
| Video quality selection | Partial | Regular YouTube has a WebView-backed quality picker; a Music video resolution picker is not implemented |
| Charts | Partial | Chart sections and pagination exist; country selection is not implemented |
| Radio and mix queues | Partial | Song/artist radio, mixes, queue display, and continuation exist; radio filter chips are not implemented |
| Song credits | Not implemented | No credits parser or sheet |
| Home activity chips | Not implemented | No chip model, selection requests, or filter row |
| Mobile Speed dial | Not implemented | Known `IOS_MUSIC` Home model; web-cookie authentication returned HTTP 400 on mobile clients. Requires a verified mobile OAuth session before replacing Favorites |
| Related content for the current Music track | Not implemented | No Music Related view |
| Full radio builder | Not implemented | No form-driven station creation or saving |
| Native YouTube transcript | Not implemented | No working transcript request or native panel |
| Recommendation dismissal | Not implemented | Dislike and library add/remove feedback exist; Not interested for recommendations does not |
| Taste profile onboarding | Not implemented | No artist-selection onboarding |
| Uploaded albums/artists | Not implemented | Their issued browse routes return signed-in empty states; Uploaded Songs is implemented separately |
| Recap | Not implemented | No Recap page or parser |
| Audio/video counterpart switch | Not implemented | The existing video button changes presentation, not the recording |

The initial probes ran on 2026-09-04 in guest mode before an authentication
export was available. Later Speed dial and account discovery used the saved web
login. Each result below identifies its authentication mode. Counts describe
renderers in individual responses, not unique records or fixed limits. No account
mutations or playback behavior were tested.

### Authenticated Library and account discovery

Verified on 2026-09-04 with saved Kaset cookies and the `WEB_REMIX` client.
Home, Library, and the successful account-specific requests explicitly reported
a signed-in server session. Credentials and personalized response values stayed
out of reports. These probes used the web session; they do not establish mobile
OAuth authentication.

| Read | Verified response |
|------|-------------------|
| Library landing | HTTP 200, 25 grid items, six content chips, and three sort choices. Its next-page request returned eight more items. |
| Library sorting | Following the issued Recently saved reload returned HTTP 200, 25 grid items, and a sort-menu title of Recently saved. |
| Playlist sorting | The dedicated playlist page offered Recently saved, A to Z, and Z to A. Following A to Z returned HTTP 200, 20 grid items, and a matching sort-menu title. |
| Playlist pagination | Following the default playlist page's next continuation returned HTTP 200 with no additional item renderers or next-page navigation. |
| Podcast library | Following Podcasts returned HTTP 200 and nine grid items through `FEmusic_library_non_music_audio_list`. |
| Podcast Channels | The Channels chip issued `FEmusic_library_non_music_audio_channels_list` with params. It returned 25 user-channel rows and selected both Podcasts and Channels. The next continuation returned 21 more channel rows. |
| Profiles | The Profiles chip issued `FEmusic_library_user_profile_channels_list` with params. It returned HTTP 200, one user-channel row, a message, and three sort choices. |
| Upload Albums and Artists | Their issued routes returned HTTP 200 with selected filter chips and a message, without album or artist rows. The Albums route is `FEmusic_library_privately_owned_releases`; the older `privately_owned_albums` probe still returned HTTP 400 while signed in. |
| Listening history | HTTP 200 with 199 track rows across four shelves. Removal commands were observed but not sent. |
| Taste profile | HTTP 200 with `tastebuilderRenderer`, 120 item lists, and 1,700 item renderers containing selection and impression form fields. No acceptance or selection submission was sent. |
| Recap | HTTP 200 with a signed-in session and a `messageRenderer`, without Recap data. |
| YouTube transcript | Signed-in WEB `next` issued `getTranscriptEndpoint` for `jNQXAC9IVRw`; replaying its exact params returned HTTP 400 `FAILED_PRECONDITION`. Authentication alone did not make this request work. |

The six Library chips target Playlists, Podcasts, Songs, Albums, Artists, and
Profiles. Songs currently issues `FEmusic_liked_videos`. The issued Profiles and
podcast Channels requests include params; this investigation did not establish
an equivalent params-free request.

Library selection commands differ from the direct browse navigation seen in
guest Home. A chip's read is under
`chipCloudChipRenderer.navigationEndpoint.commandExecutorCommand.commands[].browseEndpoint`.
The batch also contains `musicLibraryPersistLaunchNavigationCommand`.
Sort options use
`musicMultiSelectMenuItemRenderer.selectedCommand.commandExecutorCommand.commands[]`
with a `browseSectionListReloadEndpoint.continuation.reloadContinuationData`
read and checkbox-update siblings. Explorer extracts the browse read, retains
the current filter context for reloads, and does not execute the other commands.
Returned sort-menu titles confirm the selected sort. Sorting across every page
and native UI ordering remain untested.

The taste builder's `acceptButton` is inspected as schema only. Its browse-like
shape does not make acceptance an ordinary discovery route. Selection values
remain private, and discovery does not expose an acceptance navigation entry.

Kaset's [Library view](../Sources/Kaset/Views/LibraryView.swift) filters already
loaded collections locally. Its
[Library loader](../Sources/Kaset/Services/API/YTMusicClient.swift) reads podcast
shows from the landing preview and has no dedicated podcast Channels or Profiles
load. Library sorting, full collection pagination, and those dedicated reads
are concrete additions supported by these responses. Uploaded album/artist
parsers still need a populated account fixture before implementation.

**Explorer status: Implemented.** Bundled chip reads, sort reloads, redacted
sort-menu titles, and non-replayable taste acceptance are covered by tests.
**App status:** The missing integrations remain as listed in the table above.

```bash
swift run api-explorer auth
swift run api-explorer discover browse '{"browseId":"FEmusic_library_landing"}' --limit 20

# Inspect current indices before following these sampled selections.
swift run api-explorer discover browse '{"browseId":"FEmusic_library_landing"}' --follow 7
swift run api-explorer discover browse '{"browseId":"FEmusic_liked_playlists"}' --follow 3
swift run api-explorer discover browse '{"browseId":"FEmusic_library_landing"}' --follow 1 --follow 2 --follow 6
swift run api-explorer discover browse '{"browseId":"FEmusic_library_landing"}' --follow 5
swift run api-explorer discover browse '{"browseId":"FEmusic_library_privately_owned_landing"}' --follow 2
swift run api-explorer discover browse '{"browseId":"FEmusic_tastebuilder"}'
swift run api-explorer discover browse '{"browseId":"FEmusic_listening_review"}'
```

### Song credits

Searching for `Daft Punk Get Lucky` exposed a server-issued `MPTC...` browse ID
in a row menu. Following it returned HTTP 200 with page type
`MUSIC_PAGE_TYPE_TRACK_CREDITS`. A `dismissableDialogRenderer` contained four
populated `dismissableDialogContentSectionRenderer` sections. Each had a title
and nonempty subtitle runs. The roles were Performed by, Written by, Produced
by, and Music metadata provided by.

Kaset's [Song model](../Sources/Kaset/Models/Song.swift),
[SongMetadataParser](../Sources/Kaset/Services/API/Parsers/SongMetadataParser.swift),
and [song context menus](../Sources/Kaset/Views/SharedViews/SongContextMenus.swift)
do not expose credits. The browse ID comes from navigation and cannot be
constructed from the video ID. Credit titles can be localized or unfamiliar;
the observed four roles are not an exhaustive schema. Credits require a
separate detail request, which can be deferred until the user opens them.

### Home activity chips

Guest Home returned 11 chips: Podcasts, Energize, Relax, Workout, Feel good,
Commute, Sleep, Romance, Party, Focus, and Sad. Following Focus with its issued
`FEmusic_home` browse params returned HTTP 200, `isSelected=true` for Focus,
and three shelves instead of two. These chips are distinct from the existing
Moods & Genres destination pages.

[HomeResponse](../Sources/Kaset/Models/HomeResponse.swift) stores sections but
no chips, and [HomeResponseParser](../Sources/Kaset/Services/API/Parsers/HomeResponseParser.swift)
does not parse the filter bar. [YTMusicClient](../Sources/Kaset/Services/API/YTMusicClient.swift)
owns continuation state by page type; it has no separate Home filter cache or
continuation identity. Selecting a chip changes the request params and the
content to which subsequent continuations belong.

### Mobile Speed dial

Speed dial is exposed by an existing client through the Home browse request,
using `clientName: IOS_MUSIC`. It is not a separate known browse ID. The
[client's Home parser](https://github.com/itsnebulalol/resonance-addons/blob/a9a6ac6d1adfd7c36da83d086bfad6840296eff9/packages/youtubemusic-addon/src/routes/catalog.ts)
reads this path:

```text
contents.singleColumnBrowseResultsRenderer.tabs[].tabRenderer.content
  .sectionListRenderer.contents[].itemSectionRenderer.contents[]
  .elementRenderer.newElement.type.componentType.model
  .musicSpeedDialShelfModel.data.items[]
```

The associated [request implementation](https://github.com/itsnebulalol/resonance-addons/blob/a9a6ac6d1adfd7c36da83d086bfad6840296eff9/packages/youtubemusic-addon/src/auth.ts)
sends `POST https://music.youtube.com/youtubei/v1/browse?prettyPrint=false` with
`browseId: FEmusic_home`. Its profile uses version `9.06.4`, platform `MOBILE`,
iOS `26.2.1`, and device `iPhone18,4`. It authenticates with mobile OAuth.

Verified locally on 2026-09-04:

| Probe | Result |
|-------|--------|
| Guest `WEB_REMIX` Home | HTTP 200 with two `musicCarouselShelfRenderer` sections; no Speed dial model |
| Guest `IOS_MUSIC` Home | HTTP 200 with mobile `elementRenderer` models. One response contained `musicGridItemCarouselModel`, `musicListItemCarouselModel`, and Quick picks; no Speed dial model |
| Signed-in `WEB_REMIX` Home | HTTP 200; `logged_in=1` and `yt_li=1`. Returned Listen again with 20 items, but no Speed dial model |
| `IOS_MUSIC` with web cookies and SAPISIDHASH | HTTP 400 `INVALID_ARGUMENT`. Repeated with matching client headers and with the resolved web API key; same rejection |
| `IOS_MUSIC` with cookies but no Authorization header | HTTP 200, explicitly guest in service metadata; no Speed dial model. Adding the web API key did not authenticate it |
| `ANDROID_MUSIC` with SAPISIDHASH | Versions `5.34.51` and `7.21.50` returned HTTP 400 `INVALID_ARGUMENT` |
| Guest `ANDROID_MUSIC` Home | Both tested versions returned HTTP 200 with a `messageRenderer`, not a populated Home feed |
| Mobile OAuth Home | Not tested; Kaset has no mobile OAuth session or token export |

The Home request and guest iOS response format are verified. The current Kaset
login authenticates the web client, but did not authenticate any tested mobile
profile. A response body or HTTP 200 alone is insufficient: the cookie-only
mobile response explicitly reported a guest session. The linked client's
[authentication configuration](https://github.com/itsnebulalol/resonance-addons/blob/a9a6ac6d1adfd7c36da83d086bfad6840296eff9/packages/youtubemusic-addon/src/index.ts)
requires a Google OAuth refresh token, which its request implementation exchanges
for a mobile access token. Kaset currently has no such exchange or login flow.

The Speed dial item shape below comes from that client implementation, not a
locally captured signed-in response:

| Item field | Purpose in the linked parser |
|------------|------------------------------|
| `title`, `thumbnail.image.sources` | Tile label and artwork |
| `navigationCommand.innertubeCommand.browseEndpoint` | Playlist, album, or artist navigation |
| `startPlaybackCommand.innertubeCommand.watchEndpoint` | Playback seed and playlist context |
| `startPlaybackCommand.serialCommand.commands[].innertubeCommand.watchEndpoint` | Playback seed inside a command sequence |
| `onLongPress.innertubeCommand.menuEndpoint.menu.menuRenderer.title.musicMenuTitleRenderer.secondaryText` | Additional metadata in the long-press menu |
| `isShortcut` | Marks a shortcut tile; it does not establish ordinary song semantics |

An artist tile can carry both browse navigation and a radio playback command.
Those are distinct actions. Preserve issued commands rather than reducing every
tile to a song or synthesizing a Speed dial browse ID.

**App status: Not implemented.** Favorites remains unchanged. Listen again is
not used as a substitute for the requested mobile Speed dial section. The next
step is to establish mobile OAuth authentication and capture a populated
`musicSpeedDialShelfModel` before implementing its parser and interface.

Kaset currently requests `WEB_REMIX`, and
[HomeResponseParser](../Sources/Kaset/Services/API/Parsers/HomeResponseParser.swift)
does not parse `elementRenderer` mobile models. Speed dial has no dedicated app
model or interface. API Explorer reports mobile model names, Speed dial item
and shortcut counts, redacted read navigation, fixed API error categories, and
server login flags from `responseContext.serviceTrackingParams`. It also reports
web shelf labels and item counts separately, so Listen again cannot be mistaken
for a mobile Speed dial model.

**Explorer status: Implemented.** iOS and Android request profiles, web-cookie
comparison options, and private-file OAuth input are available:

```bash
swift run api-explorer discover browse '{"browseId":"FEmusic_home"}' --ios-music --guest
swift run api-explorer discover browse '{"browseId":"FEmusic_home"}' --ios-music -v -o /tmp/mobile-home.txt
swift run api-explorer discover browse '{"browseId":"FEmusic_home"}' --ios-music --mobile-cookie-only
swift run api-explorer discover browse '{"browseId":"FEmusic_home"}' --android-music --client-version 7.21.50 --guest
swift run api-explorer discover browse '{"browseId":"FEmusic_home"}' --ios-music --mobile-token-file /path/to/private-access-token -o /tmp/mobile-oauth-home.txt
```

Without `--mobile-token-file`, mobile discovery uses saved web cookies if
available, or guest mode when `--guest` is supplied. `--mobile-cookie-only`
retains cookies but removes SAPISIDHASH for comparison. `--mobile-web-key` adds
the resolved web API key; it did not fix the iOS authentication rejection.

The token-file option reads an existing OAuth **access token**, not a refresh
token. The file must be owned by the current user, have mode 0600 and no extended
ACL, and be a regular file rather than a symlink. Its value stays in memory and
is sent only to mobile discovery requests as Bearer authorization; web cookies
and account-selection headers are omitted. It cannot be combined with guest
mode, cookie-only mode, or web account selection. Do not put credentials in
command arguments, documentation, fixtures, or chat. This option does not obtain,
refresh, or validate a mobile credential by itself; a populated signed-in
response still needs live verification.

Both mobile profiles are restricted to `discover`, cannot be combined with
`--youtube` or each other, and stay active on every followed request. They omit
the web API-key lookup by default and send matching client headers and user
agents. `--client-version` overrides the configured version. The Android default
`5.34.51` comes from the
[YouTube.js client definitions](https://github.com/LuanRT/YouTube.js/blob/a480854c501406cf55c9eb7ad5b540ab36a65b56/src/utils/Constants.ts)
and is a diagnostic baseline, not a verified Home feed profile. The model and
item counts distinguish an absent shelf from an empty one without exposing
listening history.

### Chart countries

Charts exposed 69 distinct country choices across 70 menu items, including one
duplicate. The menu uses `musicMultiSelectMenuItemRenderer` and
`musicBrowseFormBinderCommand`. Its choices are backed by
`frameworkUpdates.entityBatchUpdate.mutations[].payload.musicFormBooleanChoice`.
The observed `opaqueToken` values were public two-letter country codes,
including `ZZ` for Global.

The [Japan request](#charts-femusic_charts) returned HTTP 200, explicitly
selected `JP`, 40 list rows, and two carousels. Country selection is separate
from `context.client.gl`, which the app currently sets to US.
[ChartsViewModel](../Sources/Kaset/ViewModels/ChartsViewModel.swift) and
[ChartsView](../Sources/Kaset/Views/ChartsView.swift) have no country selection;
`getCharts` has no country argument or country-specific state.

The read-only form handling verified here applies only to Charts. Home and
tastebuilder forms can update recommendation preferences.

### Related Music content

For `dQw4w9WgXcQ`, `next` returned a Related tab with an `MPTR...` browse ID
alongside the `MPLY...` Lyrics tab. Following the issued Related navigation
returned HTTP 200, five carousels, 28 track rows, and an artist description.
Recognized sections included You might also like, Recommended playlists,
Similar artists, and About the artist. The page type is
`MUSIC_PAGE_TYPE_TRACK_RELATED`. The page uses the shelf structure
already handled by [HomeResponseParser](../Sources/Kaset/Services/API/Parsers/HomeResponseParser.swift),
but Kaset does not load or display this tab. Preserve the issued browse ID.

A recommendation is not evidence of an audio/video counterpart. None of the
sampled queues exposed explicit counterpart fields. A recording switch remains
unverified even though Related browsing works.

### Radio queue filters

A `next` request with a video seed, its `RDAMVM...` playlist, `isAudioOnly=true`,
and `enablePersistentPlaylistPanel=true` returned 50 queue entries and eight
chips. Recognized labels included All, Popular, Discover, Deep cuts, and Party.
Following the issued Popular command returned HTTP 200 and 24 queue entries.
That response did not repeat the full filter bar.

[RadioQueueResult](../Sources/Kaset/Services/API/Parsers/RadioQueueParser.swift)
stores songs and a continuation, but no filter commands. The commands carry
server-issued playlist IDs and params. API Explorer retains the seed's audio
and persistent-panel flags when following them.

An unfiltered `nextRadioContinuationData` replay also returned HTTP 200 and 49
entries. These probes establish queue reads, not filtered or infinite
pagination, selected-chip persistence, or in-app playback behavior. The app's
continuation request sends fewer fields than Explorer; comparing different
request contexts does not establish a parser defect.

### Other discovery results and limits

| Area | API evidence and remaining limits |
|------|-----------------------------------|
| Full radio builder | `FEmusic_radio_builder` returned HTTP 200, a dialog, two chip groups, five choices, `musicWatchFormBinderCommand`, and form entities. Familiar, Popular, and Discover controls were present. Multiple artist seeds and station creation/saving were not verified. |
| Native YouTube transcript | WEB `next` exposed `getTranscriptEndpoint` for `aircAruvnKk` and `jNQXAC9IVRw`. Guest exact-params replays returned HTTP 400. The signed-in replay for `jNQXAC9IVRw` also returned HTTP 400 `FAILED_PRECONDITION`. A working request remains unverified; existing captions do not establish transcript support. |
| Recommendation dismissal | Guest and signed-in Home cards exposed Not interested and `feedbackEndpoint`; signed-in Home also exposed Don't recommend channel. No mutation was sent, so action semantics and responses remain unverified. Library add/remove feedback is a separate implemented use of the same endpoint. |
| Taste profile | Signed-in content is verified in [account discovery](#authenticated-library-and-account-discovery). Artist choices exist; acceptance and submission remain untested. |
| Uploaded albums/artists and library sorting | [Account discovery](#authenticated-library-and-account-discovery) verified the issued upload routes with empty states, populated sort reloads, and collection continuations. Populated upload records and sorting across all pages remain unverified. |
| Recap | Guest `FEmusic_listening_review` returned context/tracking only; the signed-in request returned a message. Neither response established usable Recap data. |
| Podcast resume | Source inspection only: episode models and UI carry progress, but conversion to `Song` drops it. WebView may already restore progress, so runtime instrumentation is needed before calling this a playback bug. `PodcastParser` currently accepts integer percentages, marks progress of at least 95% as played, and recognizes the literal English word `played`. |

The [probe commands](#repeat-the-discovery-probes) reproduce the read requests.
Upstream source helped identify candidates: ytmusicapi's
[credits and Related methods](https://github.com/sigma67/ytmusicapi/blob/master/ytmusicapi/mixins/browsing.py),
[country form request](https://github.com/sigma67/ytmusicapi/blob/master/ytmusicapi/mixins/charts.py),
and [watch queue parameters](https://github.com/sigma67/ytmusicapi/blob/master/ytmusicapi/mixins/watch.py).
These are independent client implementations, not an official API contract;
the response claims above come from the live probes.

---

## Using the API Explorer

The SwiftPM `api-explorer` executable (`Sources/APIExplorer/main.swift`) provides comprehensive exploration of both public and authenticated API endpoints.

### Basic Usage

```bash
# Check authentication status
swift run api-explorer auth

# List all known endpoints
swift run api-explorer list

# Explore a public browse endpoint
swift run api-explorer browse FEmusic_charts
# Output: ✅ HTTP 200
#         📋 Top-level keys (5): contents, frameworkUpdates, header...

# Explore with verbose output (shows full raw JSON, no truncation)
swift run api-explorer browse FEmusic_home -v

# Save raw JSON to a file for analysis
swift run api-explorer action search '{"query":"manifest"}' -o /tmp/search.json

# Explore action endpoints
swift run api-explorer action search '{"query":"never gonna give you up"}'
swift run api-explorer action player '{"videoId":"dQw4w9WgXcQ"}'
```

### Read-only discovery

`discover` inventories renderer and mobile model types, recognized UI labels, command kinds,
and replayable navigation. It keeps opaque request parameters in memory and
prints browse-ID families instead of content or account identifiers. Unknown
labels and all free-form response text remain hidden. `-v` adds schema paths
and value types, never raw response values.

#### Repeat the discovery probes

Start with `swift run api-explorer auth` and `swift run api-explorer list`.
These commands reproduce the September discoveries:

```bash
swift run api-explorer discover help

# Credits. Inspect the current MPTC entry before choosing its index.
swift run api-explorer discover search '{"query":"Daft Punk Get Lucky"}' --guest
swift run api-explorer discover search '{"query":"Daft Punk Get Lucky"}' --guest --follow 0

# Home. Inspect the Focus entry, then select it with --follow N.
swift run api-explorer discover browse '{"browseId":"FEmusic_home"}' --guest

# Mobile Home. Speed dial requires a populated shelf to confirm availability.
swift run api-explorer discover browse '{"browseId":"FEmusic_home"}' --ios-music --guest

# Chart menu and a country selection, saved as a redacted report.
swift run api-explorer discover browse '{"browseId":"FEmusic_charts"}' --guest --limit 100
swift run api-explorer discover browse '{"browseId":"FEmusic_charts","formData":{"selectedValues":["JP"]}}' --guest -o /tmp/charts-discovery.txt

# Related. Entry 0 was the Related tab in the sampled response.
swift run api-explorer discover next '{"videoId":"dQw4w9WgXcQ"}' --guest --follow 0

# Radio queue with filter commands and continuation options.
swift run api-explorer discover next '{"videoId":"dQw4w9WgXcQ","playlistId":"RDAMVMdQw4w9WgXcQ","isAudioOnly":true,"enablePersistentPlaylistPanel":true}' --guest

# Radio form schema, without submission or station creation.
swift run api-explorer discover browse '{"browseId":"FEmusic_radio_builder"}' --guest -v

# Transcript commands. Entry 0 was get_transcript in both samples.
swift run api-explorer discover next '{"videoId":"aircAruvnKk"}' --youtube --guest --follow 0
swift run api-explorer discover next '{"videoId":"jNQXAC9IVRw"}' --youtube --guest --follow 0
```

Indices can change when YouTube reorders content. Check each printed hop before
using it as evidence. Repeat `--follow` for up to five hops; each index selects
from the preceding response. Explorer reports the selected route even when its
index is beyond the displayed `--limit`. A `get_transcript` entry is an observed read
command, not a promise that its replay works. The September probes returned
HTTP 400. Discovery returns a nonzero exit status on a failed request, and `-o`
saves a redacted report even for failed HTTP responses.

The allowlist includes `browse`, `search`, `next`, `player`, `music/get_queue`,
`music/get_search_suggestions`, and `get_transcript`. Discovery refuses mutation
endpoints and request fields. The only form exception is a single two-letter
country selection for `FEmusic_charts`. It extracts direct browse reads from
Library chip and sort-selection batches, without executing persistence or
checkbox-update siblings. Other service commands remain schema-only, except
explicit transcript reads. Taste-profile acceptance is not replayable.

Authentication stays consistent across hops. Cookies are used when available;
`--guest` suppresses them. The report distinguishes the requested auth mode from
the server's explicit session marker. Music responses often omit that marker.
HTTP 200 and a content envelope alone do not establish authenticated content.
Use `--body-file` for private request IDs or opaque parameters. Reports use
owner-only file permissions and never contain raw payloads.

### Regular YouTube Mode

Pass `--youtube` (or `--yt`) to target `www.youtube.com` with the WEB client instead of `music.youtube.com` with WEB_REMIX:

```bash
# Regular YouTube home recommendations
swift run api-explorer --youtube browse FEwhat_to_watch

# YouTube subscriptions and history (auth used automatically when cookies exist)
swift run api-explorer --youtube browse FEsubscriptions
swift run api-explorer --youtube browse FEhistory

# Search and watch-next metadata
swift run api-explorer --youtube action search '{"query":"swift concurrency"}'
swift run api-explorer --youtube action next '{"videoId":"VIDEO_ID"}'
```

#### YouTube chapter markers (verified 2026-07-07)

Regular YouTube chapter data is exposed by the WEB `next` watch-page response,
not by the `player` endpoint. `api-explorer` now summarizes both known chapter
shapes when they appear:

```bash
swift run api-explorer --youtube --guest action next '{"videoId":"u2rYp8AMuSg"}'
```

Observed chapter paths:

```text
playerOverlays.playerOverlayRenderer.decoratedPlayerBarRenderer
  .decoratedPlayerBarRenderer.playerBar.multiMarkersPlayerBarRenderer
  .markersMap[].value.chapters[].chapterRenderer

engagementPanels[].engagementPanelSectionListRenderer.content
  .macroMarkersListRenderer.contents[].macroMarkersListItemRenderer

engagementPanels[].engagementPanelSectionListRenderer.content
  .structuredDescriptionContentRenderer.items[]
  .horizontalCardListRenderer.cards[].macroMarkersListItemRenderer
```

Field notes:

- `chapterRenderer` is the best watch-page source for navigation markers.
  It includes `timeRangeStartMillis`, `title.simpleText`, and chapter
  thumbnails.
- `macroMarkersListItemRenderer` appears in the chapters panel and may be
  duplicated in the structured description or search result metadata. It adds
  `onTap.watchEndpoint.startTimeSeconds`, `timeDescription`, and repeat-chapter
  commands whose `startTimeMs` / `endTimeMs` can provide chapter bounds.
- Videos without chapters may still expose heatmap markers through
  `macroMarkersListEntity.markersList`; do not treat heatmap markers as
  chapters.
- Auth was not required for the verified chapter response: both `--guest` and
  signed-in `--youtube action next` returned the same chapter marker counts for
  the test video.
- `--youtube action player '{"videoId":"..."}'` returned metadata/captions and
  streaming/player state, but no `chapterRenderer` or
  `macroMarkersListItemRenderer` chapter data in the verified probes.

Prefer the destination feeds documented in [youtube.md](youtube.md) for Explore; YouTube's old `FEtrending` feed is no longer a reliable target.

#### YouTube Ask Gemini / YouChat investigation (2026-07-27)

YouTube's **Ask Gemini** watch-page experience is an undocumented, internal
YouChat engagement-panel surface. It is not a public API, and its availability,
request schemas, and frontend identifiers are subject to account eligibility,
server rollout, client version, and video-specific changes.

Start with the redacted read-only audit. Use the separate live command only when
an explicit request to contact the live AI service has been approved:

```bash
# Read-only: audits watch responses and frontend capability markers
swift run api-explorer ask-video-audit <VIDEO_ID>

# Read-only: compares the ordered production/request-compatibility profiles
swift run api-explorer ask-video-parity <VIDEO_ID>

# Live: replays only the server-issued summary suggestion
swift run api-explorer ask-video-live-test <VIDEO_ID> --confirm-live-ai

# Live: summary plus the first server-issued follow-up suggestion
swift run api-explorer ask-video-live-test <VIDEO_ID> --confirm-live-ai --follow-up

# Live: two independent watch/panel bootstraps, capped at three
swift run api-explorer ask-video-live-test <VIDEO_ID> --confirm-live-ai --fresh-chats 2

# Live: one guarded free-text request from a private prompt source
swift run api-explorer ask-video-free-text-test <VIDEO_ID> --confirm-live-ai --prompt-file <MODE_0600_PATH_OR_->

# Manual structural probe for object, array, streaming, or opaque responses
swift run api-explorer --youtube wire-action <ENDPOINT> '<JSON_OBJECT>'
```

`ask-video-audit` redacts opaque values, does not save raw payloads, and never
submits a query. `ask-video-live-test` requires `--confirm-live-ai`, keeps all
opaque continuations and message state in memory, rejects raw output files, and
accepts no arbitrary prompt text. Its generated answer display strips control
and bidirectional formatting characters, hides links and high-entropy opaque
strings, and is bounded to 16,000 characters per answer.

`ask-video-free-text-test` is a separate, one-shot validation command. It
captures one immutable authenticated runtime-WEB request snapshot, fetches a
fresh `next` response, and selects the first complete eligible `PAyouchat`
panel, matching the browser's mirrored-panel behavior without merging opaque
commands from responsive duplicates. If `next` contains the validated
`sendUserQueryCommand`, the loader uses it directly. Otherwise, when the same
bootstrap has one safe panel continuation, the loader sends its prompt-free
initial `get_panel` body through that same snapshot and accepts only the strict
parser's confirmed materialized `freeTextCommand`. The accepted command schema
is intentionally narrow and may originate in either response. The August 2
watch response placed it at
`engagementPanelSectionListRenderer.footer.chatInputViewModel.sendUserQueryCommand`;
confirmed materialized panel items may expose the same command under
`youChatItemViewModel.sendUserQueryCommand`:

```text
sendUserQueryCommand
└── innertubeCommand
    ├── clickTrackingParams: nonempty string
    └── continuationCommand
        ├── request: CONTINUATION_REQUEST_TYPE_GET_PANEL
        └── opaque continuation token is present
```

Initial materialization contains only the exact panel continuation plus the
snapshot's request context; it has no `formData`, message ID, prompt, or click-
tracking injection and cannot generate an answer. The resolved command then
sends one generated `get_panel` request, without retry, using the exact server
continuation and click-tracking context plus:

```text
formData.inputComposerFormData.clientMessageId: youchat-<Unix epoch milliseconds>
formData.inputComposerFormData.playerOffsetMs: decimal millisecond string
formData.inputComposerFormData.userInputText: private prompt contents
```

The runtime WEB `context` is added by the authenticated request transport.
The same immutable context, headers, API identifier, cookie/account snapshot,
and origin are used for `next`, optional initial materialization, and prompt
submission; the backing identity is revalidated before either `get_panel`.
Prompts must come from stdin or a regular file owned by the current user with
exact mode `0600`, no extended ACL, valid UTF-8, at most 16,000 characters, and
at most 64 KiB of UTF-8. The command rejects guest, `--authuser`, brand-account,
client-version override, verbose, output, raw-body, follow-up, and multi-chat
options. Responses use the bounded `YouTubeAskCore` decoder and strict confirmed
YouChat parser; only sanitized assistant text and redacted structural metrics are
printed. Raw prompts, commands, responses, and conversation values are never
displayed or saved.

**Live validation on August 2, 2026:**

- The first guarded API candidate used `streaming_panel` and returned HTTP 400
  before generation, confirming the earlier transport interpretation was stale.
- A user-approved browser capture then submitted one 25-character prompt. The
  frontend posted to `get_panel`, not `streaming_panel`, with top-level
  `context`, `continuation`, and `formData` only.
- `inputComposerFormData` contained exactly `clientMessageId`, string
  `playerOffsetMs`, and `userInputText`; click tracking was nested in
  `context.clickTracking`.
- The response returned HTTP 200 as a JSON object with the confirmed singular
  `onResponseReceivedCommand.listMutationCommand` shape. The existing bounded
  decoder and strict conversation parser accept that response container.
- No second arbitrary-text turn was sent in this browser capture, so multi-turn
  behavior remained unvalidated at that point.

**Read-only production-parity matrix (added July 28, 2026):**

`ask-video-parity` tests the credential-free profiles defined by
`YouTubeAskRequestProfile` in this order:

1. Fixed production client version, no API key, no visitor data, and one SID proof.
2. The same fixed production configuration with all available SID proof schemes.
3. The runtime WEB client-version/API-key/visitor-data bundle with all available
   SID proof schemes.

For each profile, the command makes an authenticated `next` request and, only
when strict parsing finds one unambiguous panel bootstrap, materializes the
initial `get_panel`. It never submits a suggestion chip, free text, or any other
generation request. Both responses use the bounded `YouTubeAskCore` wire decoder
and strict parser. Terminal output is limited to the profile name, HTTP status,
response size, wire format, eligibility, chip counts, whether a validated
free-text capability was present in `next` and initial `get_panel`, and a
redacted failure category. It never prints command continuations or click-
tracking values. The command stops at the first passing profile and rejects
raw-output, private-body, client-version override, follow-up, and multi-chat
options.

The read-only run on **July 28, 2026** completed all three profiles. Every
`next` request returned HTTP 200, but each response reported the exported
session as signed out, so `get_panel` was not run and no profile passed. This is
an authentication rejection, not evidence that any request profile is valid or
invalid for an eligible signed-in session. No profile passed that historical
run. Production was later enabled through the explicitly selected fixed profile;
future compatibility checks must still confirm signed-in primary-account
eligibility and fail closed on unsupported responses.

`get_panel`, `streaming_panel`, and `get_answer` must use `wire-action` for manual
probes; the raw `action` command rejects them. Supply manual panel JSON through
`--body-file` using a mode-0600 regular file, or use `--body-file -` to read
stdin, so opaque values do not appear in argv or normal shell history. Endpoint
arguments must be plain relative API paths.

**Observed frontend identifiers**:

- `PAyouchat`
- `engagement-panel-youchat`
- `PAai_companion`

**Observed transport behavior**:

| Transport | Current interpretation |
|-----------|------------------------|
| `get_panel` | Prompt-free initial panel materialization, direct suggestion chips, materialized free-text capability discovery, and the validated free-text composer transport |
| `streaming_panel` | Frontend capability remains present, but the August 2 free-text candidate returned HTTP 400; not used by production |
| `get_watch` | Combined player/watch bootstrap; observed responses use a top-level JSON array |
| `get_answer` | Separate AI answer transport; not used by the verified watch-page suggestion flow |

A direct suggestion chip does **not** submit its visible text. The current
frontend creates a `CONTINUATION_REQUEST_TYPE_GET_PANEL` command from the exact
server-issued `chipData.continuation` and posts it to `get_panel` with:

```text
continuation: exact server-issued chip continuation
formData.inputComposerFormData.clientMessageId: youchat-<Unix epoch milliseconds>
```

The browser also supplies optional playback/page/previous-message timing context
when available. API Explorer omits unavailable optional fields rather than
inventing them. The chip's `id`, visible text, click-tracking command, and the
free-text composer's `sendUserQueryCommand` are not copied into this direct-chip
request.

**Current direct-chip response container (August 1, 2026):**

Successful `get_panel` responses used a top-level singular
`onResponseReceivedCommand.listMutationCommand`. Assistant text items and
follow-up chips were inserted under:

```text
operations.operations[].insertItemSectionContent.contents[].youChatItemViewModel
```

The confirmed insertion metadata uses `position: INSERTION_POSITION_LAST` with a
nonempty section target. Other positions or missing placement metadata fail
closed.

Text-bearing `youChatItemViewModel` objects expose `text.content` plus optional
style/action metadata. Chip-bearing objects expose `chipsData`. Kaset parses only
those two visible surfaces under the confirmed insertion path; result/link
objects such as `videoResultsData` and `webData`, plus sibling `frameworkUpdates`,
remain ignored. The older
`onResponseReceivedCommands[].appendContinuationItemsAction.continuationItems[]`
shape remains supported for previously validated responses.

**Signed-in production compatibility check on August 1, 2026**:

- The authenticated watch response exposed validated direct chips whose
  `chipData` entries could include a top-level `onClick` callback containing one
  local interaction command.
- The root `chipData.continuation` remained the only replayed capability. Kaset
  ignores the callback only when it matches the observed `listMutationCommand`
  structure, inserts the same visible label plus the allowlisted loading-animation
  placeholder, and contains no extra keys or request capability.
- The same response exposed multiple distinct panel-bootstrap continuations.
  When direct chips are already present, Kaset discards the ambiguous panel
  command instead of guessing; ambiguity still rejects bootstraps that have no
  direct chips.
- A read-only production-client probe then parsed the watch bootstrap
  successfully. No panel materialization or suggestion submission was performed.

The free-text composer uses the exact server-issued `sendUserQueryCommand`
continuation and click tracking. Strict parsing may obtain that capability from
the canonical eligible `next` panel or from the confirmed prompt-free initial
`get_panel` materialization. `next` wins when it already supplies the command;
the initial panel is queried only as a fallback, and distinct commands are never
merged. The August 2 browser capture showed that the frontend posts the resolved
command to `get_panel` with `clientMessageId`, decimal-string `playerOffsetMs`,
and `userInputText`. Production permits that exact shape once per bound
conversation revision. A successful response advances the revision and retains
the validated composer command when the response omits a replacement; no
additional multi-turn fields are invented.

**Live production validation on August 3, 2026:**

- Two free-text prompts succeeded in the same watch-scoped chat.
- The first response contained no replacement `sendUserQueryCommand`; Kaset
  retained the original validated composer command after advancing the bound
  conversation revision.
- The second request reused the validated `get_panel` shape with a fresh
  monotonic `clientMessageId`, current playback offset, and new `userInputText`.
- Each revision remained single-consumption: stale pending copies were rejected
  before network access, and there was no automatic retry.

**Live validation on July 27, 2026**:

- The refreshed cookie export was accepted as a signed-in YouTube WEB session.
- The watch bootstrap exposed `PAyouchat`, a summary chip, and a fresh panel
  continuation.
- Replaying the summary chip through `get_panel` returned HTTP 200 and a generated
  summary.
- Replaying the first follow-up chip from that response returned HTTP 200 and a
  generated follow-up answer in the same flow.
- Two independent watch/panel bootstraps both returned HTTP 200 summaries; the
  generated text was not exactly identical.
- Sending the chip continuation to `streaming_panel` without form data returned
  HTTP 400, confirming that it is not the direct-chip transport.

These results validate the current eligible-account flow, not a stable contract.
Treat the surface as rollout-fragile. Never commit or display cookies,
authorization material, account identifiers, conversation identifiers, visitor
or session values, opaque params, continuations, or server-issued commands.

### Authenticated Endpoints

For authenticated endpoints (🔐), sign in to the Kaset app first:

```bash
# Check if cookies are available
swift run api-explorer auth

# If authenticated, explore library endpoints
swift run api-explorer browse FEmusic_liked_playlists
swift run api-explorer browse FEmusic_history
swift run api-explorer browse FEmusic_liked_albums
```

Debug builds export auth cookies for the API explorer to `~/Library/Application Support/Kaset/cookies.dat`.

### Brand Account Support

```bash
# List all accounts (primary + brand) with their IDs
swift run api-explorer brandaccounts

# Access a brand account's library
swift run api-explorer browse FEmusic_liked_playlists --brand <BRAND_ID>
```

The `--brand` flag sets `context.user.onBehalfOfUser` in the request body. See [Brand Account Support](#brand-account-support) in the Authentication section for details.

### Commands Reference

| Command | Description |
|---------|-------------|
| `browse <id> [params]` | Explore a browse endpoint |
| `action <endpoint> <json>` | Explore an action endpoint that returns a top-level JSON object |
| `wire-action <endpoint> <json>` | Safely inspect object, array, streaming, or opaque wire responses without printing raw values |
| `discover <endpoint> <json>` | Inventory and follow read-only navigation; `discover help` lists the supported request fields |
| `ask-video-audit <videoId>` | Run a redacted, read-only Ask Gemini / YouChat audit without sending a prompt |
| `ask-video-parity <videoId>` | Test ordered read-only Ask request profiles using only `next` and initial `get_panel`; never submits a chip |
| `ask-video-live-test <videoId>` | With `--confirm-live-ai`, replay the server-issued summary chip; optionally add `--follow-up` or `--fresh-chats N` |
| `ask-video-free-text-test <videoId>` | With `--confirm-live-ai` and `--prompt-file`, resolve the command from `next` or a prompt-free initial `get_panel`, then validate one exact server-commanded free-text request with no retry |
| `search-audit <query>` | Audit live Music search shapes, filter chips, continuations, and parser coverage |
| `continuation <token> [ep]` | Explore a continuation (`browse`, `search`, or `next`); use the same auth mode as the originating request (`--guest` for guest search) |
| `list` | List all known endpoints |
| `auth` | Check authentication status |
| `accounts` | Discover accounts via authuser header |
| `brandaccounts` | List all brand accounts with IDs |
| `help` | Show help message |

### Options

| Option | Description |
|--------|-------------|
| `-v, --verbose` | Show full raw JSON for browse/action/continuation commands; expand audit and search samples |
| `-o, --output <file>` | Save raw output with owner-only permissions; `discover` saves only a redacted report, and `ask-video-audit` ignores this option |
| `--follow N` | Follow a numbered `discover` navigation entry; repeat for up to five hops |
| `--limit N` | Show 1-500 `discover` entries, default 40 |
| `--ios-music`, `--android-music` | Select one mobile Music profile for `discover`; web-cookie authentication was rejected in tested profiles |
| `--mobile-web-key` | Include the resolved web API key in mobile discovery for request comparison |
| `--mobile-cookie-only` | Keep web cookies but omit SAPISIDHASH in mobile discovery; tested iOS responses were guest sessions |
| `--mobile-token-file <path>` | Use an existing OAuth access token from an owner-only mode-0600 regular file; mobile discovery only, without web cookies or web account selection |
| `--authuser N` | Use Google account at index N |
| `--brand <ID>` | Use brand account (21-digit ID) |
| `--client-version <version>` | Override the resolved InnerTube client version for compatibility probes |
| `--body-file <path\|->` | Read a sensitive JSON action body from a mode-0600 regular file or stdin; required for panel/answer transports |
| `--prompt-file <path\|->` | Read the free-text validation prompt from an exact mode-0600 regular file or stdin; accepted only by `ask-video-free-text-test` |
| `--confirm-live-ai` | Required explicit acknowledgement before either guarded Ask live-test command sends an AI request |
| `--follow-up` | Replay the first follow-up chip returned by the live summary response |
| `--fresh-chats N` | Run 1-3 independent summary bootstraps (default: 1) |
| `--youtube`, `--yt` | Target regular YouTube (`www.youtube.com`, WEB client) instead of YouTube Music |

---

## Legend

| Icon | Meaning |
|------|---------|
| 🌐 | No authentication required |
| 🔐 | Authentication required |
| ✅ | Implemented in Kaset |
| ⏳ | Not yet implemented |

---

## Changelog

| Date | Changes |
|------|---------|
| 2026-09-04 | Verified signed-in Library filters, sort reloads, pagination, podcast Channels, Profiles, upload empty states, and taste-builder data. Added safe selection-read extraction and blocked taste acceptance in Explorer; recorded Recap and authenticated transcript limits |
| 2026-09-04 | Located the mobile Speed dial Home model in an existing client; verified guest `IOS_MUSIC` Home requests, added a read-only mobile profile and model/item counts to Explorer, and recorded the missing signed-in validation |
| 2026-09-04 | Confirmed the new web login works while tested mobile clients reject SAPISIDHASH; cookie-only iOS responses explicitly report guest. Added Android comparison, server login/error diagnostics, and private OAuth input to Explorer. Actual Speed dial remains blocked on mobile authentication; Favorites was not replaced with Listen again |
| 2026-09-04 | Added redacted `discover` traversal, chart form selection, transcript-command inspection, and behavioral tests; verified credits, Home chips, country charts, Related content, and radio filter reads; consolidated findings, guest-only limits, and [implementation status](#implementation-status) in this reference |
| 2026-08-03 | Live-validated two free-text prompts in one chat; retained the validated composer command across successful bound revisions, enforced one action per revision, and preserved stale-revision rejection/no-retry behavior |
| 2026-08-02 | Browser-validated the `get_panel` free-text request and response shape; added the guarded `ask-video-free-text-test`; selected the first content-equivalent mirrored YouChat panel; documented and implemented `sendUserQueryCommand` provenance from the watch footer `chatInputViewModel`, an eligible YouChat item, or prompt-free initial `get_panel`; added redacted parity capability reporting; deduplicated repeated visible suggestions; retained server-chip follow-ups |
| 2026-08-01 | Revalidated an eligible signed-in production watch response; added strict support for the observed local user-turn/loading `onClick` mutation, preserved direct chips while discarding ambiguous panel-only commands, and added one bounded read-only retry for internal identity-fence cancellation |
| 2026-07-30 | Enabled the fixed WEB Ask request profile in the production app by explicit product direction; eligibility and all strict parser, identity, and transport gates remain enforced |
| 2026-07-28 | Added redacted read-only `ask-video-parity` tooling backed by `YouTubeAskCore`; all three profiles returned HTTP 200 `next` responses but the exported session was treated as signed out, so no profile passed and production remains disabled |
| 2026-07-27 | Live-validated YouTube Ask Gemini / YouChat summary, follow-up, and two fresh chats; added guarded `ask-video-live-test`, corrected direct chips to `get_panel`, retained read-only `ask-video-audit`, and documented redaction/auth constraints |
| 2026-07-19 | Revalidated Music search: `itemSectionRenderer` mixed rows, watch-endpoint Top Results, audiobooks, videos/profiles/episodes filters, shelf and action-envelope continuations, and `/search` routing; added `search-audit` |
| 2026-06-24 | Documented regular YouTube `--youtube` API Explorer mode alongside YouTube Music |
| 2026-01-16 | Added comprehensive Podcast ID Format section: MPSPP→PL conversion, L-prefix validation, double-L bug documentation |
| 2026-01-14 | Added Brand Account Support: `account/accounts_list` endpoint, `--brand` flag, `brandaccounts` command |
| 2026-01-06 | Added Video Feature API section: musicVideoType, streamingData quality options, related content endpoints |
| 2025-07-26 | Documented podcast implementation: `FEmusic_podcasts`, `MPSPP{id}` endpoints, podcast search filter params, podcast subscription API |
| 2024-12-22 | Added Undocumented Endpoints section with discovered endpoints |
| 2024-12-22 | Unified standalone API Explorer with full endpoint coverage |
| 2024-12-21 | Initial comprehensive documentation |
| 2024-12-21 | Verified Player and Queue endpoints with detailed response structures |
| 2024-12-21 | Confirmed Library Albums/Artists/Songs require auth + params |
| 2024-12-21 | Documented playlist management auth requirements |

---

## Video Feature API

This section documents API functionality for the floating video window feature. See [docs/video.md](video.md) for implementation details.

### Music Video Type Detection

The `musicVideoType` field distinguishes between actual music videos and audio-only tracks. This is available in both `player` and `next` endpoint responses.

| Video Type | Constant | Description | Kaset video toggle |
|------------|----------|-------------|-------------------|
| Official Music Video | `MUSIC_VIDEO_TYPE_OMV` | Full video from artist/label | ✅ Yes |
| Audio Track Video | `MUSIC_VIDEO_TYPE_ATV` | Static image or visualizer | ❌ No |
| User Generated Content | `MUSIC_VIDEO_TYPE_UGC` | Fan-made or unofficial | ❌ No |
| Official-source music | `MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC` | Official-source video search result | ❌ No |
| Podcast Episode | `MUSIC_VIDEO_TYPE_PODCAST_EPISODE` | Audio podcast | ❌ No |

All listed constants are parsed. `hasVideoContent` enables the video toggle
only for `.omv`; `isSearchVideo` also includes `.ugc` and `.officialSourceMusic`.

**Implementation**: The `MusicVideoType` enum and parsing are implemented in:

- [Sources/Kaset/Models/MusicVideoType.swift](../Sources/Kaset/Models/MusicVideoType.swift) - Enum definition
- [Sources/Kaset/Models/Song.swift](../Sources/Kaset/Models/Song.swift) - `musicVideoType` property
- [Sources/Kaset/Services/API/Parsers/SongMetadataParser.swift](../Sources/Kaset/Services/API/Parsers/SongMetadataParser.swift) - Parsing logic

**Location in `next` response**:
```
playlistPanelVideoRenderer.navigationEndpoint.watchEndpoint
  .watchEndpointMusicSupportedConfigs.watchEndpointMusicConfig.musicVideoType
```

**Location in `player` response**:
```
videoDetails.musicVideoType
```

**Usage Example**:
```swift
// Only show video toggle for actual music videos
if song.musicVideoType?.hasVideoContent == true {
    showVideoToggle()
}
```

---

### Video quality selection

Regular YouTube quality selection is implemented in
[YouTubePlayerBar](../Sources/Kaset/Views/YouTube/YouTubePlayerBar.swift) and
[YouTubeWatchWebView](../Sources/Kaset/Views/YouTube/YouTubeWatchWebView+Scripts.swift).
The picker reads the WebView player's available quality levels and requests
the chosen level through `setPlaybackQualityRange`, with a
`setPlaybackQuality` fallback. A Music video resolution picker is not implemented.

Historical `player` responses exposed formats in `streamingData.adaptiveFormats`.
Kaset uses WebView playback rather than those URLs. Guest responses may omit
streaming data, and the formats below are sample observations, not guaranteed
quality choices for every video.

**Historical format sample** from `adaptiveFormats`:

| Quality | Resolution | Codec Options |
|---------|------------|---------------|
| 1080p | 1920×1080 | H.264 (avc1.640028), VP9 |
| 720p | 1280×720 | H.264 (avc1.4d401f), VP9 |
| 480p | 854×480 | H.264 (avc1.4d401f), VP9 |
| 360p | 640×360 | H.264 (avc1.4d401e), VP9 |
| 240p | 426×240 | H.264 (avc1.4d4015), VP9 |
| 144p | 256×144 | H.264 (avc1.4d400c), VP9 |

**Response Structure**:
```json
{
  "streamingData": {
    "adaptiveFormats": [
      {
        "itag": 137,
        "mimeType": "video/mp4; codecs=\"avc1.640028\"",
        "bitrate": 2173100,
        "width": 1920,
        "height": 1080,
        "quality": "hd1080",
        "qualityLabel": "1080p",
        "fps": 30,
        "url": "https://..."
      }
    ]
  }
}
```

---

### Audio/video counterparts

A switch between paired audio and video recordings is not implemented. The
existing Music video button changes the presentation of the current recording.

[Related Music content](#related-music-content) was verified on 2026-09-04,
but its recommendations do not establish a pairing. No explicit counterpart
fields appeared in the sampled queues. Related browse IDs are server-issued
navigation values, not values to construct from a track ID.

---

## Verification Summary

The table below records historical probes from 2024-12-21, with later library
checks noted in the rows and endpoint sections. `FEmusic_library_corpus_track_artists`
was revalidated on 2026-03-24. See [implementation status](#implementation-status)
for the 2026-09-04 discoveries and their verification limits.

### ✅ Working Without Auth

| Endpoint | Status | Notes |
|----------|--------|-------|
| `FEmusic_home` | HTTP 200 | Full response |
| `FEmusic_explore` | HTTP 200 | Full response |
| `FEmusic_charts` | HTTP 200 | Full response |
| `FEmusic_moods_and_genres` | HTTP 200 | Full response |
| `FEmusic_new_releases` | HTTP 200 | Full response |
| `FEmusic_podcasts` | HTTP 200 | Full response |
| `FEmusic_library_landing` | HTTP 200 | Returns login prompt (no content) |
| `FEmusic_library_corpus_track_artists` | HTTP 200 | Returns sign-in prompt (no artist rows) |
| `player` | HTTP 200 | Streaming data appeared in the 2024 sample; 2026-07-01 guest probes returned `UNPLAYABLE` without streaming data |
| `music/get_queue` | HTTP 200 | Full queue data |
| `search` | HTTP 200 | Full results |

### ⚠️ Works with Session Cookies (from visiting music.youtube.com)

| Endpoint | Status | Notes |
|----------|--------|-------|
| `FEmusic_liked_playlists` | HTTP 200 | Works with session cookies |
| `FEmusic_liked_albums` | HTTP 200* | Returns saved album rows with current auth; stale or missing auth returns a sign-in prompt |
| `FEmusic_liked_videos` | HTTP 200 | Works with session cookies |
| `FEmusic_history` | HTTP 200 | Returns login prompt without full auth |

### 🔐 Requires Full Authentication (SAPISIDHASH)

| Endpoint | Status | Notes |
|----------|--------|-------|
| `FEmusic_history` | HTTP 200* | Returns content with full auth, login prompt without |
| `FEmusic_library_corpus_track_artists` | HTTP 200* | Returns library artist rows with full auth, sign-in prompt without |
| `FEmusic_library_albums` | HTTP 400 | Legacy saved-albums browse ID; use `FEmusic_liked_albums` |
| `FEmusic_library_artists` | HTTP 400 | Rejected as invalid argument in current authenticated sessions |
| `FEmusic_library_corpus_artists` | HTTP 200* | Returns followed artists with full auth and public `UC...` browseIds |
| `FEmusic_library_songs` | HTTP 400 | No working request established; required context remains unverified |
| `FEmusic_recently_played` | HTTP 400 | No working request established; Kaset uses `FEmusic_history` |
| `playlist/get_add_to_playlist` | HTTP 401 | Needs full auth; app caches with `APICache.TTL.library` |
| `playlist/create` | HTTP 401 | Needs full auth; response playlist ID may be top-level or nested |
| `browse/edit_playlist` | HTTP 401 | Needs full auth; app uses `ACTION_ADD_VIDEO` and `ACTION_REMOVE_VIDEO` for track edits |
| `playlist/delete` | HTTP 401 | Needs full auth and user-owned playlist |

> **Note on Library Artists endpoints**: `FEmusic_library_corpus_track_artists` is the sign-in-backed Artists chip browseId and returns `MPLAUC...` library artist pages. Those `MPLAUC...` pages also require authentication when browsed directly. In current authenticated sessions, the library chip also exposes `FEmusic_library_corpus_artists` with `params=ggMCCAU=`; that endpoint returns followed artists with public `UC...` browseIds and is a better source for navigation. By contrast, `FEmusic_library_artists` currently returns HTTP 400 invalid argument even with full SAPISIDHASH authentication.
