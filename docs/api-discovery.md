# YouTube Music API Reference

> **Complete documentation of YouTube Music API endpoints for Kaset development.**
>
> This document catalogs all known YouTube Music API endpoints, their authentication requirements, implementation status, and usage patterns. Use the [APIExplorer](../Core/Services/API/APIExplorer.swift) tool for live endpoint testing.

## Table of Contents

- [Overview](#overview)
- [Authentication](#authentication)
- [Browse Endpoints](#browse-endpoints)
  - [Implemented](#implemented-browse-endpoints)
  - [Available (Not Implemented)](#available-browse-endpoints)
- [Action Endpoints](#action-endpoints)
  - [Implemented](#implemented-action-endpoints)
  - [Available (Not Implemented)](#available-action-endpoints)
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
| `FEmusic_liked_videos` | Liked Songs | 🔐 | Songs user has liked | `PlaylistParser` |
| `VL{playlistId}` | Playlist Detail | 🌐 | Playlist tracks and metadata | `PlaylistParser` |
| `UC{channelId}` | Artist Detail | 🌐 | Artist page with songs, albums | `ArtistParser` |
| `MPLYt{id}` | Lyrics | 🌐 | Song lyrics text | Custom parser |

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

#### Liked Songs (`FEmusic_liked_videos`)

```swift
let body = ["browseId": "FEmusic_liked_videos"]
// Requires authentication
```

**Returns**: Playlist-format response with all liked songs

---

### Available Browse Endpoints

These endpoints are functional but not yet implemented in Kaset.

| Browse ID | Name | Auth | Priority | Notes |
|-----------|------|------|----------|-------|
| `FEmusic_charts` | Charts | 🌐 | **High** | Top songs, albums by country/genre |
| `FEmusic_moods_and_genres` | Moods & Genres | 🌐 | **High** | Browse by mood/genre grids |
| `FEmusic_new_releases` | New Releases | 🌐 | **Medium** | Recent albums, singles, videos |
| `FEmusic_history` | History | 🔐 | **High** | Recently played tracks |
| `FEmusic_podcasts` | Podcasts | 🌐 | Low | Podcast discovery |
| `FEmusic_library_landing` | Library Landing | 🔐 | Medium | Library overview |
| `FEmusic_library_albums` | Library Albums | 🔐 | Medium | Requires auth + params* |
| `FEmusic_library_artists` | Library Artists | 🔐 | Medium | Requires auth + params* |
| `FEmusic_library_songs` | Library Songs | 🔐 | Low | Requires auth + params* |
| `FEmusic_recently_played` | Recently Played | 🔐 | Medium | Requires auth |
| `FEmusic_library_privately_owned_landing` | Uploads | 🔐 | Low | User-uploaded content |
| `FEmusic_library_privately_owned_tracks` | Uploaded Tracks | 🔐 | Low | Uploaded songs |
| `FEmusic_library_privately_owned_albums` | Uploaded Albums | 🔐 | Low | Uploaded albums |

> \* Library Albums/Artists/Songs return HTTP 400 without authentication. With authentication, they also require specific `params` values for sorting. The exact param encoding needs to be captured from web client requests.

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

**Response**: Mixed results with songs, albums, artists, playlists in `musicShelfRenderer` sections.

**Parser**: `SearchResponseParser`

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

**Used for**:
- `getLyrics(videoId:)` - Extracts lyrics browse ID
- `getSong(videoId:)` - Gets full song metadata with tokens
- `getRadioQueue(videoId:)` - Gets radio mix (with `playlistId: "RDAMVM{videoId}"`)

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

```swift
let body = ["channelIds": ["UCuAXFkgsw1L7xaCfnd5JJOw"]]
_ = try await request("subscription/subscribe", body: body)
```

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
let body = ["videoIds": ["dQw4w9WgXcQ", "fJ9rUzIMcZQ"]]
```

**Response** (works WITHOUT auth! - verified):
```json
{
  "responseContext": {...},
  "queueDatas": [{
    "content": {
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
  }],
  "queueContextParams": "..."
}
```

**playlistPanelVideoRenderer keys** (verified):
- `title`, `longBylineText`, `thumbnail`, `lengthText`
- `selected`, `navigationEndpoint`, `videoId`, `shortBylineText`
- `trackingParams`, `menu`

**Use case**: Get metadata for multiple videos in one call (essential for queue display).

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
| `gridRenderer` | Grid of items |
| `musicShelfRenderer` | Vertical list (search results) |
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

The [APIExplorer](../Core/Services/API/APIExplorer.swift) tool provides structured exploration of API endpoints.

### Basic Usage

```swift
// Create explorer instance
let explorer = APIExplorer(webKitManager: .shared)

// Explore a browse endpoint
let result = await explorer.exploreBrowseEndpoint("FEmusic_charts")
DiagnosticsLogger.api.info("\(result.summary)")
// Output: ✅ FEmusic_charts: 4 keys, 5 sections [musicCarouselShelfRenderer, gridRenderer]

// Explore an action endpoint
let actionResult = await explorer.exploreActionEndpoint("player", body: ["videoId": "dQw4w9WgXcQ"])
DiagnosticsLogger.api.info("\(actionResult.summary)")
// Output: ✅ player: 8 keys, ~42KB response
```

### Exploring All Endpoints

```swift
// Explore all unimplemented browse endpoints
let results = await explorer.exploreAllBrowseEndpoints(includeImplemented: false)
for result in results {
    DiagnosticsLogger.api.info("\(result.summary)")
}

// Generate markdown report
let report = await explorer.generateEndpointReport()
DiagnosticsLogger.api.info(report)
```

### Endpoint Registry

The explorer maintains registries of all known endpoints:

```swift
// Browse endpoints
APIExplorer.browseEndpoints  // [EndpointConfig]

// Action endpoints  
APIExplorer.actionEndpoints  // [EndpointConfig]
```

Each `EndpointConfig` contains:
- `id`: The endpoint identifier
- `name`: Human-readable name
- `description`: What it does
- `requiresAuth`: Whether auth is needed
- `isImplemented`: Current implementation status
- `notes`: Additional context

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
| 2024-12-21 | Initial comprehensive documentation |
| 2024-12-21 | Added APIExplorer tool documentation |
| 2024-12-21 | Verified Player and Queue endpoints with detailed response structures |
| 2024-12-21 | Confirmed Library Albums/Artists/Songs require auth + params |
| 2024-12-21 | Documented playlist management auth requirements |

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
