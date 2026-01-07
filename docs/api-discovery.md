# YouTube Music API Reference

> **Complete documentation of YouTube Music API endpoints for Kaset development.**
>
> This document catalogs all known YouTube Music API endpoints, their authentication requirements, implementation status, and usage patterns. Use the standalone [API Explorer](../Tools/api-explorer.swift) tool for live endpoint testing.

## Table of Contents

- [Overview](#overview)
- [Authentication](#authentication)
- [Browse Endpoints](#browse-endpoints)
  - [Implemented](#implemented-browse-endpoints)
  - [Available (Not Implemented)](#available-browse-endpoints)
- [Action Endpoints](#action-endpoints)
  - [Implemented](#implemented-action-endpoints)
  - [Available (Not Implemented)](#available-action-endpoints)
- [Undocumented Endpoints](#undocumented-endpoints)
- [Request Patterns](#request-patterns)
- [Response Parsing](#response-parsing)
- [Implementation Priorities](#implementation-priorities)
- [Using the API Explorer](#using-the-api-explorer)

---

## Overview

The YouTube Music API (`youtubei/v1`) is an internal API used by the YouTube Music web client. Key characteristics:

| Property | Value |
|----------|-------|
| Base URL | `https://music.youtube.com/youtubei/v1` |
| API Key | `AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30` |
| Client Name | `WEB_REMIX` |
| Client Version | `1.20231204.01.00` |
| Protocol | HTTPS POST with JSON body |

### Endpoint Types

1. **Browse Endpoints** - Load content pages (Home, Explore, Library, etc.)
2. **Action Endpoints** - Perform operations (Search, Like, Subscribe, etc.)

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

### Required Cookies

| Cookie | Purpose |
|--------|---------|
| `SAPISID` | Used in SAPISIDHASH calculation |
| `__Secure-3PAPISID` | Fallback for SAPISID |
| `SID`, `HSID`, `SSID` | Session cookies |
| `LOGIN_INFO` | Login state |

---

## Browse Endpoints

Browse endpoints use `POST /browse` with a `browseId` parameter.

### Implemented Browse Endpoints

| Browse ID | Name | Auth | Description | Parser |
|-----------|------|------|-------------|--------|
| `FEmusic_home` | Home | 🌐 | Personalized recommendations, mixes, quick picks | `HomeResponseParser` |
| `FEmusic_explore` | Explore | 🌐 | New releases, charts, moods shortcuts | `HomeResponseParser` |
| `FEmusic_liked_playlists` | Library Playlists | 🔐 | User's saved/created playlists | `PlaylistParser` |
| `VLLM` | Liked Songs | 🔐 | All songs user has liked (with pagination) | `PlaylistParser` |
| `VL{playlistId}` | Playlist Detail | 🌐 | Playlist tracks and metadata | `PlaylistParser` |
| `UC{channelId}` | Artist Detail | 🌐 | Artist page with songs, albums | `ArtistParser` |
| `MPLYt{id}` | Lyrics | 🌐 | Song lyrics text | Custom parser |
| `FEmusic_podcasts` | Podcasts Discovery | 🌐 | Podcast shows and episodes carousel | `PodcastParser` |
| `MPSPP{id}` | Podcast Show Detail | 🌐 | Podcast episodes with playback progress | `PodcastParser` |

> **Note**: `VLLM` is a special case of `VL{playlistId}` where `LM` is the Liked Music playlist ID. Do NOT use `FEmusic_liked_videos` — it returns only ~13 songs without pagination.

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

### Available Browse Endpoints

These endpoints are functional but not yet implemented in Kaset.

| Browse ID | Name | Auth | Priority | Notes |
|-----------|------|------|----------|-------|
| `FEmusic_charts` | Charts | 🌐 | **High** | Top songs, albums by country/genre |
| `FEmusic_moods_and_genres` | Moods & Genres | 🌐 | **High** | Browse by mood/genre grids |
| `FEmusic_new_releases` | New Releases | 🌐 | **Medium** | Recent albums, singles, videos |
| `FEmusic_history` | History | 🔐 | **High** | Recently played tracks |
| `FEmusic_library_landing` | Library Landing | 🔐 | **High** | All library content (playlists, podcasts, artists, etc.) |
| `FEmusic_library_non_music_audio_list` | Subscribed Podcasts | 🔐 | Medium | User's subscribed podcast shows |
| `FEmusic_library_albums` | Library Albums | 🔐 | Medium | Requires auth + params* |
| `FEmusic_library_artists` | Library Artists | 🔐 | Medium | Requires auth + params* |
| `FEmusic_library_songs` | Library Songs | 🔐 | Low | Requires auth + params* |
| `FEmusic_recently_played` | Recently Played | 🔐 | Medium | Requires auth |
| `FEmusic_library_privately_owned_landing` | Uploads | 🔐 | Low | User-uploaded content |
| `FEmusic_library_privately_owned_tracks` | Uploaded Tracks | 🔐 | Low | Uploaded songs |
| `FEmusic_library_privately_owned_albums` | Uploaded Albums | 🔐 | Low | Uploaded albums |

> \* Library Albums/Artists/Songs return HTTP 400 without authentication. With authentication, they also require specific `params` values for sorting. The exact param encoding needs to be captured from web client requests.

---

#### Library Landing (`FEmusic_library_landing`)

```swift
let body = ["browseId": "FEmusic_library_landing"]
// Requires authentication
```

**Response structure**:
- Returns all library content in a single `gridRenderer`
- Includes: Playlists (`VL*`), Podcasts (`MPSPP*`), Artists (`UC*`), Profiles, Auto playlists
- Contains filter chips for: Playlists, Podcasts, Songs, Albums, Artists, Profiles
- Each chip's `browseEndpoint.browseId` provides the filtered endpoint

**Filter chip endpoints discovered**:
| Chip | browseId |
|------|----------|
| Playlists | `FEmusic_liked_playlists` |
| Podcasts | `FEmusic_library_non_music_audio_list` |
| Songs | `FEmusic_liked_videos` |
| Albums | `FEmusic_liked_albums` |
| Artists | `FEmusic_library_corpus_track_artists` |
| Profiles | `FEmusic_library_user_profile_channels_list` (with params) |

**Item identification by browseId prefix**:
- `VL*`, `PL*`, `RDCLAK*` — Playlists
- `MPSPP*` — Podcast shows
- `UC*` — Artists or Profiles
- `VLLM` — Liked Music auto playlist
- `VLRDPN` — New Episodes auto playlist
- `VLSE` — Episodes for Later auto playlist

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
- Country-specific charts (via params)

**Implementation suggestion**:
```swift
func getCharts(country: String? = nil) async throws -> ChartsResponse
```

---

#### Moods & Genres (`FEmusic_moods_and_genres`)

```swift
let body = ["browseId": "FEmusic_moods_and_genres"]
```

**Response structure**:
- Grid of moods (Chill, Focus, Workout, Party, etc.)
- Grid of genres (Pop, Rock, Hip-Hop, R&B, etc.)

Each item links to a playlist or browse endpoint for that mood/genre.

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
| `search` | Search | 🌐 | Search songs, albums, artists, playlists |
| `music/get_search_suggestions` | Suggestions | 🌐 | Autocomplete for search |
| `next` | Now Playing | 🌐 | Track info, lyrics ID, radio queue |
| `like/like` | Like | 🔐 | Like a song/album/playlist |
| `like/dislike` | Dislike | 🔐 | Dislike a song |
| `like/removelike` | Remove Like | 🔐 | Remove like/dislike rating |
| `feedback` | Feedback | 🔐 | Add/remove from library via tokens |
| `subscription/subscribe` | Subscribe | 🔐 | Subscribe to artist |
| `subscription/unsubscribe` | Unsubscribe | 🔐 | Unsubscribe from artist |

---

#### Search (`search`)

```swift
let body = ["query": "never gonna give you up"]
```

**Response Structure**:
- `musicCardShelfRenderer` — **Top Result** section (single prominent result: song, album, artist, or playlist)
- `musicShelfRenderer` — Regular results (mixed songs, albums, artists, playlists)

> ⚠️ **Important**: The Top Result (most relevant match) is returned in `musicCardShelfRenderer`, not `musicShelfRenderer`. This is often the artist/album the user is looking for. Always parse both renderer types.

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

**Parser**: `SearchResponseParser` (handles both `musicCardShelfRenderer` and `musicShelfRenderer`)

**Filter Params** (base64-encoded filter values for `params` field):

| Filter | Param Value | Description |
|--------|-------------|-------------|
| Songs | `EgWKAQIIAWoQEBAQCRAEEAMQBRAKEBUQEQ%3D%3D` | Filter to songs only |
| Albums | `EgWKAQIYAWoQEBAQCRAEEAMQBRAKEBUQEQ%3D%3D` | Filter to albums only |
| Artists | `EgWKAQIgAWoQEBAQCRAEEAMQBRAKEBUQEQ%3D%3D` | Filter to artists only |
| Playlists | `EgeKAQQoAEABahAQEBAJEAQQAxAFEAoQFRAR` | Filter to playlists only |
| Podcasts | `EgWKAQJQAWoQEBAQCRAEEAMQBRAKEBUQEQ%3D%3D` | Filter to podcast shows only |

**Usage Example** (podcasts):
```swift
let body: [String: Any] = [
    "query": "crime weekly",
    "params": "EgWKAQJQAWoQEBAQCRAEEAMQBRAKEBUQEQ%3D%3D"
]
```

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

Tokens come from `getSong(videoId:)` response.

---

#### Subscribe/Unsubscribe

**Artist Subscription** (uses channel ID):
```swift
let body = ["channelIds": ["UCuAXFkgsw1L7xaCfnd5JJOw"]]
_ = try await request("subscription/subscribe", body: body)
```

**Podcast Subscription** (uses show browse ID with `MPSPP` prefix):
```swift
// Subscribe to podcast
let body = ["playlistIds": ["MPSPP2t8s..."]] // Full MPSPP{id} from show
_ = try await request("subscription/subscribe", body: body)

// Unsubscribe from podcast  
let body = ["playlistIds": ["MPSPP2t8s..."]]
_ = try await request("subscription/unsubscribe", body: body)
```

> ⚠️ **Note**: Podcast subscription uses `playlistIds`, not `channelIds`. The value is the full `MPSPP{id}` browse ID from the podcast show.

---

### Available Action Endpoints

| Endpoint | Name | Auth | Priority | Notes |
|----------|------|------|----------|-------|
| `player` | Player | 🌐 | Medium | Video metadata, streaming URLs |
| `music/get_queue` | Get Queue | 🌐 | **High** | Queue data for video IDs |
| `playlist/get_add_to_playlist` | Add to Playlist | 🔐 | Medium | Get playlists for "Add to" menu |
| `browse/edit_playlist` | Edit Playlist | 🔐 | Medium | Add/remove playlist tracks |
| `playlist/create` | Create Playlist | 🔐 | Medium | Create new playlist |
| `playlist/delete` | Delete Playlist | 🔐 | Low | Delete a playlist |
| `guide` | Guide | 🌐 | Low | Sidebar structure |
| `account/account_menu` | Account Menu | 🔐 | Low | Account settings |

---

#### Player (`player`)

```swift
let body = ["videoId": "dQw4w9WgXcQ"]
```

**Response** (works WITHOUT auth!):
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

> ⚠️ **Note**: The response uses a **wrapper structure** (`playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer`) 
> rather than a direct `playlistPanelVideoRenderer`. Parsers must handle this wrapper.

**playlistPanelVideoRenderer keys** (verified):
- `title`, `longBylineText`, `thumbnail`, `lengthText`
- `selected`, `navigationEndpoint`, `videoId`, `shortBylineText`
- `trackingParams`, `menu`

**Use cases**:
- Get metadata for multiple videos in one call (queue display)
- **Fetch ALL tracks for radio playlists** (RDCLAK prefix) where browse pagination is broken

---

#### Playlist Management

All playlist management endpoints require authentication (HTTP 401 without auth):

```swift
// Get playlists for "Add to Playlist" menu
let body = ["videoIds": ["dQw4w9WgXcQ"]]
let response = try await request("playlist/get_add_to_playlist", body: body)
// Returns HTTP 401 without auth

// Add to playlist
let body = [
    "playlistId": "PLxyz...",
    "actions": [["addedVideoId": "dQw4w9WgXcQ", "action": "ACTION_ADD_VIDEO"]]
]
try await request("browse/edit_playlist", body: body)
// Returns HTTP 401 without auth

// Create playlist
let body = [
    "title": "My Playlist",
    "description": "",
    "privacyStatus": "PRIVATE",
    "videoIds": []
]
try await request("playlist/create", body: body)
// Returns HTTP 401 without auth
```

---

## Undocumented Endpoints

These endpoints were discovered through API exploration (2024-12-22) but are not part of the documented API surface. Some may be useful for app functionality.

### Potentially Useful Undocumented Endpoints

| Endpoint | Type | Auth | Parameters | Description |
|----------|------|------|------------|-------------|
| `FEmusic_radio_builder` | Browse | 🌐 | - | Radio station builder UI data (form fields, artist selection) |
| `FEmusic_liked_videos` | Browse | 🔐 | - | User's liked videos (alternative to `FEmusic_liked_videos`) |

### Infrastructure/Internal Endpoints

These endpoints exist but are primarily for YouTube's internal use:

| Endpoint | Type | Auth | Parameters | Notes |
|----------|------|------|------------|-------|
| `account/account_menu` | Action | 🌐/🔐 | `{}` | Returns account menu structure (settings, premium promo) |
| `reel/reel_item_watch` | Action | 🌐 | `{}` | Returns status tracking params (YouTube Shorts related) |
| `log_event` | Action | 🌐 | `{}` | Analytics/telemetry logging endpoint |
| `att/get` | Action | 🌐 | `{}` | Anti-bot/botguard challenge data |
| `FEmusic_listening_review` | Browse | 🌐 | - | Returns only responseContext (Year in Review?) |

### Endpoints Requiring Parameters

These endpoints exist but return HTTP 400 without proper parameters:

| Endpoint | Type | Auth | Status | Notes |
|----------|------|------|--------|-------|
| `comment/create_comment` | Action | 🔐 | 400 | Needs `videoId`, `commentText` |
| `comment/perform_comment_action` | Action | 🔐 | 400 | Needs action params |
| `share/get_share_panel` | Action | 🌐 | 400 | Needs `videoId` |
| `get_transcript` | Action | 🌐 | 400 | Needs `videoId`, `params` |
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

## Implementation Priorities

### Phase 1: High-Impact Features

| Feature | Endpoint | Effort | Impact |
|---------|----------|--------|--------|
| History | `FEmusic_history` | Medium | High |
| Charts | `FEmusic_charts` | Low | High |
| Moods & Genres | `FEmusic_moods_and_genres` | Low | High |
| Queue Display | `music/get_queue` | Low | High |

### Phase 2: Library Enhancements

| Feature | Endpoint | Effort | Impact |
|---------|----------|--------|--------|
| Library Albums | `FEmusic_library_albums` | Medium | Medium |
| Library Artists | `FEmusic_library_artists` | Medium | Medium |
| Add to Playlist | `playlist/get_add_to_playlist` | Medium | Medium |

### Phase 3: Discovery

| Feature | Endpoint | Effort | Impact |
|---------|----------|--------|--------|
| New Releases | `FEmusic_new_releases` | Low | Medium |
| Create Playlist | `playlist/create` | Medium | Medium |

---

## Using the API Explorer

The standalone [api-explorer.swift](../Tools/api-explorer.swift) tool provides comprehensive exploration of both public and authenticated API endpoints.

### Setup

```bash
# Make executable (one time)
chmod +x Tools/api-explorer.swift
```

### Basic Usage

```bash
# Check authentication status
./Tools/api-explorer.swift auth

# List all known endpoints
./Tools/api-explorer.swift list

# Explore a public browse endpoint
./Tools/api-explorer.swift browse FEmusic_charts
# Output: ✅ HTTP 200
#         📋 Top-level keys (5): contents, frameworkUpdates, header...

# Explore with verbose output (shows full raw JSON, no truncation)
./Tools/api-explorer.swift browse FEmusic_home -v

# Save raw JSON to a file for analysis
./Tools/api-explorer.swift action search '{"query":"manifest"}' -o /tmp/search.json

# Explore action endpoints
./Tools/api-explorer.swift action search '{"query":"never gonna give you up"}'
./Tools/api-explorer.swift action player '{"videoId":"dQw4w9WgXcQ"}'
```

### Authenticated Endpoints

For authenticated endpoints (🔐), sign in to the Kaset app first:

```bash
# Check if cookies are available
./Tools/api-explorer.swift auth

# If authenticated, explore library endpoints
./Tools/api-explorer.swift browse FEmusic_liked_playlists
./Tools/api-explorer.swift browse FEmusic_history
./Tools/api-explorer.swift browse FEmusic_library_albums ggMGKgQIARAA
```

The tool reads cookies from `~/Library/Application Support/Kaset/cookies.dat`.

### Commands Reference

| Command | Description |
|---------|-------------|
| `browse <id> [params]` | Explore a browse endpoint |
| `action <endpoint> <json>` | Explore an action endpoint |
| `list` | List all known endpoints |
| `auth` | Check authentication status |
| `help` | Show help message |
| `-v, --verbose` | Show raw JSON response |

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

| Video Type | Constant | Description | Has Video Content |
|------------|----------|-------------|-------------------|
| Official Music Video | `MUSIC_VIDEO_TYPE_OMV` | Full video from artist/label | ✅ Yes |
| Audio Track Video | `MUSIC_VIDEO_TYPE_ATV` | Static image or visualizer | ❌ No |
| User Generated Content | `MUSIC_VIDEO_TYPE_UGC` | Fan-made or unofficial | ⚠️ Varies |
| Podcast Episode | `MUSIC_VIDEO_TYPE_PODCAST_EPISODE` | Audio podcast | ❌ No |

**Implementation**: The `MusicVideoType` enum and parsing are implemented in:
- [Core/Models/MusicVideoType.swift](../Core/Models/MusicVideoType.swift) - Enum definition
- [Core/Models/Song.swift](../Core/Models/Song.swift) - `musicVideoType` property
- [Core/Services/API/Parsers/SongMetadataParser.swift](../Core/Services/API/Parsers/SongMetadataParser.swift) - Parsing logic

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

### Video Quality Options (Future Enhancement)

The `player` endpoint returns video streaming data in `streamingData.adaptiveFormats`. This could enable a video quality selector feature.

> ⚠️ **Not Implemented**: Due to DRM requirements, Kaset uses WebView for playback. Direct URL streaming would bypass DRM protection. Quality selection would need to be implemented via WebView JavaScript.

**Available Qualities** (from `adaptiveFormats`):

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

**Future Implementation Path**:
1. Inject JavaScript into WebView to access player API
2. Use `player.setPlaybackQuality()` or similar YouTube player methods
3. Or: Parse available qualities and let WebView auto-select

---

### Related Content / Video Alternatives (Future Enhancement)

The `next` endpoint returns a Related tab that can find song/video counterparts.

> ⚠️ **Not Implemented**: Could be used to find video version of audio-only tracks or vice versa.

**Related Tab browseId Pattern**: `MPTRt_{trackId}`

**Example**: For song `DyDfgMOUjCI`, the Related tab browseId is `MPTRt_5OAD9vk2OaS`

**Page Type**: `MUSIC_PAGE_TYPE_TRACK_RELATED`

**Use Cases**:
- "Watch Video" button for ATV tracks that have an OMV version
- "Listen to Audio" for users who prefer audio-only playback
- Finding alternative versions (live, remix, etc.)

---

## Verification Summary

The following endpoints were tested without authentication on 2024-12-21:

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
| `FEmusic_library_corpus_artists` | HTTP 200 | Returns login prompt (no content) |
| `player` | HTTP 200 | Full metadata + streaming info |
| `music/get_queue` | HTTP 200 | Full queue data |
| `search` | HTTP 200 | Full results |

### ⚠️ Works with Session Cookies (from visiting music.youtube.com)

| Endpoint | Status | Notes |
|----------|--------|-------|
| `FEmusic_liked_playlists` | HTTP 200 | Works with session cookies |
| `FEmusic_liked_videos` | HTTP 200 | Works with session cookies |
| `FEmusic_history` | HTTP 200 | Returns login prompt without full auth |

### 🔐 Requires Full Authentication (SAPISIDHASH)

| Endpoint | Status | Notes |
|----------|--------|-------|
| `FEmusic_history` | HTTP 200* | Returns content with full auth, login prompt without |
| `FEmusic_library_albums` | HTTP 400 | Needs auth + specific `params` value |
| `FEmusic_library_artists` | HTTP 400 | Needs auth + specific `params` value |
| `FEmusic_library_songs` | HTTP 400 | Needs auth + specific `params` value |
| `FEmusic_recently_played` | HTTP 400 | Needs auth |
| `playlist/get_add_to_playlist` | HTTP 401 | Needs full auth |
| `playlist/create` | HTTP 401 | Needs full auth |
| `browse/edit_playlist` | HTTP 401 | Needs full auth |

> **Note on Library Albums/Artists/Songs**: These endpoints return HTTP 400 even with session cookies. They require both full SAPISIDHASH authentication AND a specific `params` value (protobuf-encoded sorting options). The exact params need to be captured from the web client's network requests.
