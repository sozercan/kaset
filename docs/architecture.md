# Architecture & Services

This document provides detailed information about Kaset's architecture, services, and design patterns.

## Core Structure

The codebase follows a clean architecture pattern:

```
App/                → App entry point, AppDelegate
Core/               → Shared logic (platform-independent)
  ├── Models/       → Data types (Song, Playlist, Album, Artist, etc.)
  ├── Services/     → Business logic
  │   ├── API/      → YTMusicClient, Parsers/
  │   ├── Auth/     → AuthService (login state machine)
  │   ├── Player/   → PlayerService, NowPlayingManager (media keys)
  │   ├── WebKit/   → WebKitManager (cookie persistence)
  │   └── HapticService.swift → Force Touch trackpad haptic feedback
  ├── ViewModels/   → State management (HomeViewModel, etc.)
  └── Utilities/    → Helpers (DiagnosticsLogger, extensions)
Views/
  └── macOS/        → SwiftUI views (MainWindow, Sidebar, PlayerBar, etc.)
Tests/              → Unit tests (KasetTests/)
docs/               → Documentation
  └── adr/          → Architecture Decision Records
```

## Service Protocols

All major services have protocol definitions for testability:

```swift
// Core/Services/Protocols.swift
protocol YTMusicClientProtocol: Sendable { ... }
protocol AuthServiceProtocol { ... }
protocol PlayerServiceProtocol { ... }
```

ViewModels accept protocols via dependency injection with default implementations:

```swift
@MainActor @Observable
final class HomeViewModel {
    private let client: YTMusicClientProtocol

    init(client: YTMusicClientProtocol = YTMusicClient.shared) {
        self.client = client
    }
}
```

## State Management

- **Source of Truth**: Services are `@MainActor @Observable` singletons
- **Environment Injection**: Views access services via `@Environment`
- **Cookie Persistence**: `WKWebsiteDataStore` with persistent identifier

## Key Services

### WebKitManager

**File**: `Core/Services/WebKit/WebKitManager.swift`

Manages WebKit infrastructure for the app:

- Owns a persistent `WKWebsiteDataStore` for cookie storage
- Provides cookie access via `getAllCookies()`
- Observes cookie changes via `WKHTTPCookieStoreObserver`
- Creates WebView configurations with shared data store

```swift
@MainActor @Observable
final class WebKitManager {
    static let shared = WebKitManager()

    func getAllCookies() async -> [HTTPCookie]
    func createWebViewConfiguration() -> WKWebViewConfiguration
}
```

### AuthService

**File**: `Core/Services/Auth/AuthService.swift`

Manages authentication state:

| State | Description |
|-------|-------------|
| `.loggedOut` | No valid session |
| `.loggingIn` | Login sheet presented |
| `.loggedIn` | Valid `__Secure-3PAPISID` cookie found |

**Key Methods**:
- `checkLoginStatus()` — Checks cookies for valid session
- `startLogin()` — Presents login sheet
- `sessionExpired()` — Handles 401/403 from API

### YTMusicClient

**File**: `Core/Services/API/YTMusicClient.swift`

Makes authenticated requests to YouTube Music's internal API:

- Computes `SAPISIDHASH` authorization per request
- Uses browser-style headers to avoid bot detection
- Throws `YTMusicError.authExpired` on 401/403
- Delegates response parsing to modular parsers

**Endpoints**:
- `getHome()` → Home page sections
- `getExplore()` → Explore page (new releases, charts, moods)
- `search(query:)` → Search results
- `getLibraryPlaylists()` → User's playlists
- `getLikedSongs()` → User's liked songs
- `getPlaylist(id:)` → Playlist details
- `getArtist(id:)` → Artist details with songs and albums
- `getLyrics(videoId:)` → Lyrics for a track (two-step: next → browse)
- `rateSong(videoId:rating:)` → Like/dislike a song
- `subscribeToArtist(channelId:)` → Subscribe to an artist
- `unsubscribeFromArtist(channelId:)` → Unsubscribe from an artist
- `subscribeToPlaylist(playlistId:)` → Add playlist to library
- `unsubscribeFromPlaylist(playlistId:)` → Remove playlist from library

### API Parsers

**Directory**: `Core/Services/API/Parsers/`

Response parsing is extracted into specialized modules:

| Parser | Purpose |
|--------|---------|
| `ParsingHelpers.swift` | Shared utilities (thumbnails, artists, duration) |
| `HomeResponseParser.swift` | Home/Explore page sections |
| `SearchResponseParser.swift` | Search results |
| `PlaylistParser.swift` | Playlist details, library playlists |
| `ArtistParser.swift` | Artist details (songs, albums, subscription status) |

**Design**: Static enum-based parsers with pure functions for testability.

### PlayerService

**File**: `Core/Services/Player/PlayerService.swift`

Controls audio playback via singleton WebView:

| Property | Type | Description |
|----------|------|-------------|
| `currentTrack` | `Song?` | Currently playing track |
| `isPlaying` | `Bool` | Playback state |
| `progress` | `Double` | Current position (seconds) |
| `duration` | `Double` | Track length (seconds) |
| `pendingPlayVideoId` | `String?` | Video ID to play |
| `showMiniPlayer` | `Bool` | Mini player visibility |
| `showLyrics` | `Bool` | Lyrics panel visibility |

**Key Methods**:
- `play(videoId:)` — Loads and plays a video
- `play(song:)` — Plays a Song model
- `confirmPlaybackStarted()` — Dismisses mini player

### SingletonPlayerWebView

**File**: `Views/macOS/MiniPlayerWebView.swift`

Manages the singleton WebView for playback:

- Creates exactly ONE WebView for app lifetime
- Handles video loading with pause-before-load
- JavaScript bridge for playback state updates
- Survives window close for background audio

```swift
@MainActor
final class SingletonPlayerWebView {
    static let shared = SingletonPlayerWebView()

    func getWebView(webKitManager:, playerService:) -> WKWebView
    func loadVideo(videoId: String)
}
```

### NowPlayingManager

**File**: `Core/Services/Player/NowPlayingManager.swift`

Remote command center integration for media key support:

- Registers `MPRemoteCommandCenter` handlers
- Handles media keys (play/pause, next, previous, seek)
- Routes commands to `PlayerService` → `SingletonPlayerWebView`

**Note**: Now Playing display (track info, album art) is handled natively by WKWebView's Media Session API. This provides better integration with album artwork from YouTube Music.

### HapticService

**File**: `Core/Services/HapticService.swift`

Provides tactile feedback on Macs with Force Touch trackpads:

| Feedback Type | Pattern | Used For |
|---------------|---------|----------|
| `.playbackAction` | `.generic` | Play, pause, skip |
| `.toggle` | `.alignment` | Shuffle, repeat, like/dislike |
| `.sliderBoundary` | `.levelChange` | Volume/seek at 0% or 100% |
| `.navigation` | `.alignment` | Sidebar selection |
| `.success` | `.generic` | Add to library, search submit |
| `.error` | `.generic` | Action failures |

**Accessibility**: Respects user preference (Settings → General) and system "Reduce Motion" setting.

### FavoritesManager

**File**: `Core/Services/FavoritesManager.swift`

Manages user-curated Favorites section on Home view:

| Property | Type | Description |
|----------|------|-------------|
| `items` | `[FavoriteItem]` | Ordered list of pinned items |
| `isVisible` | `Bool` | `true` when items exist |

**Supported Item Types**: Song, Album, Playlist, Artist

**Key Methods**:
- `add(_:)` — Adds item to front of list (no duplicates)
- `remove(contentId:)` — Removes by videoId/browseId
- `toggle(_:)` — Adds if not pinned, removes if pinned
- `move(from:to:)` — Reorders via drag-and-drop
- `isPinned(contentId:)` — Checks if item is in Favorites

**Persistence**:
- **Location**: `~/Library/Application Support/Kaset/favorites.json`
- **Format**: JSON-encoded `[FavoriteItem]`
- **Writes**: Async on background thread via `Task.detached`
- **Reads**: Synchronous at init (one-time on app launch)

**Related Files**:
- `Core/Models/FavoriteItem.swift` — Data model with `ItemType` enum
- `Views/macOS/SharedViews/FavoritesSection.swift` — Horizontal scrolling UI
- `Views/macOS/SharedViews/FavoritesContextMenu.swift` — Shared context menu items

### AppDelegate

**File**: `App/AppDelegate.swift`

Application lifecycle management:

- Implements `NSWindowDelegate` to hide window instead of close
- Keeps app running when window is closed (`applicationShouldTerminateAfterLastWindowClosed` returns `false`)
- Handles dock icon click to reopen window

## Authentication Flow

```
App Launch
    │
    ▼
┌─────────────────┐
│ Check cookies   │──── __Secure-3PAPISID exists? ────┐
│ in WebKitManager│                                    │
└─────────────────┘                                    │
    │ No                                               │ Yes
    ▼                                                  ▼
┌─────────────────┐                          ┌─────────────────┐
│ Show LoginSheet │                          │ AuthService     │
│ (WKWebView)     │                          │ .loggedIn       │
└─────────────────┘                          └─────────────────┘
    │
    │ User signs in → cookies set
    │
    ▼
┌─────────────────┐
│ Observer fires  │
│ cookiesDidChange│
└─────────────────┘
    │
    ▼
┌─────────────────┐
│ Extract SAPISID │
│ Dismiss sheet   │
└─────────────────┘
```

## API Request Flow

```
YTMusicClient.getHome()
    │
    ▼
┌─────────────────────────────────────────────────┐
│ buildAuthHeaders()                              │
│  1. Get cookies from WebKitManager              │
│  2. Extract __Secure-3PAPISID                   │
│  3. Compute SAPISIDHASH = ts_SHA1(ts+sapi+origin)│
│  4. Build Cookie, Authorization, Origin headers │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ POST https://music.youtube.com/youtubei/v1/browse│
│ Body: { context: { client: WEB_REMIX }, ... }   │
└─────────────────────────────────────────────────┘
    │
    ├── 200 OK → Parse JSON → Return HomeResponse
    │
    └── 401/403 → Throw YTMusicError.authExpired
                  → AuthService.sessionExpired()
                  → Show LoginSheet
```

## Playback Flow

```
User clicks Play
    │
    ▼
┌─────────────────────────────────────────────────┐
│ PlayerService.play(videoId:)                    │
│  → Sets pendingPlayVideoId                      │
│  → Shows mini player toast                      │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ PersistentPlayerView appears                    │
│  → Gets singleton WebView                       │
│  → Loads music.youtube.com/watch?v={videoId}    │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ WKWebView plays audio (DRM handled by WebKit)   │
│  → JS bridge sends STATE_UPDATE messages        │
│  → PlayerService updates isPlaying, progress    │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ WKWebView Media Session (native)                │
│  → Updates macOS Now Playing (with album art)   │
│ NowPlayingManager                               │
│  → Registers media key handlers → PlayerService │
└─────────────────────────────────────────────────┘
```

## Background Audio Flow

```
User closes window (⌘W or red button)
    │
    ▼
┌─────────────────────────────────────────────────┐
│ AppDelegate.windowShouldClose(_:)               │
│  → Returns false (prevents close)               │
│  → Hides window instead                         │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ WebView remains alive (in singleton)            │
│  → Audio continues playing                      │
│  → Media keys still work                        │
└─────────────────────────────────────────────────┘
    │
    │ User clicks dock icon
    ▼
┌─────────────────────────────────────────────────┐
│ AppDelegate.applicationShouldHandleReopen       │
│  → Shows hidden window                          │
│  → Same WebView still playing                   │
└─────────────────────────────────────────────────┘
    │
    │ User quits (⌘Q)
    ▼
┌─────────────────────────────────────────────────┐
│ App terminates                                  │
│  → WebView destroyed → Audio stops              │
└─────────────────────────────────────────────────┘
```

## Error Handling

### YTMusicError

**File**: `Core/Models/YTMusicError.swift`

Unified error type for the app:

| Error | Description |
|-------|-------------|
| `.authExpired` | Session invalid (401/403) |
| `.notAuthenticated` | No valid session |
| `.networkError` | Connection failed |
| `.parseError` | JSON decoding failed |
| `.apiError` | API returned error with code |
| `.playbackError` | Playback-related failure |
| `.unknown` | Generic error |

### Error Flow

1. API returns 401/403 → `YTMusicClient` throws `.authExpired`
2. `AuthService.sessionExpired()` called → state becomes `.loggedOut`
3. `AuthService.needsReauth` set to `true`
4. `MainWindow` observes and presents `LoginSheet`
5. User re-authenticates → sheet dismissed, view reloads

## Logging

All services log via `DiagnosticsLogger`:

```swift
DiagnosticsLogger.player.info("Loading video: \(videoId)")
DiagnosticsLogger.auth.error("Cookie extraction failed")
```

**Categories**: `.player`, `.auth`, `.api`, `.webKit`, `.haptic`

**Levels**: `.debug`, `.info`, `.warning`, `.error`

## UI Design (macOS 26+)

The app uses Apple's **Liquid Glass** design language introduced in macOS 26.

### Glass Effect Patterns

| Component | Glass Pattern |
|-----------|---------------|
| `PlayerBar` | `.glassEffect(.regular.interactive(), in: .capsule)` |
| `Sidebar` | Wrapped in `GlassEffectContainer` |
| `QueueView` / `LyricsView` | `.glassEffectTransition(.materialize)` |
| Search field | `.glassEffect(.regular, in: .capsule)` |
| Search suggestions | `.glassEffect(.regular, in: .rect(cornerRadius: 8))` |

### Glass Effect Best Practices

1. **Use `GlassEffectContainer`** to wrap multiple glass elements
2. **Use `.glassEffectTransition(.materialize)`** for panels that appear/disappear
3. **Use `@Namespace` + `.glassEffectID()`** for morphing between states
4. **Avoid glass-on-glass** — don't apply `.buttonStyle(.glass)` to buttons already inside a glass container
5. **Reserve glass for navigation/floating controls** — not for content areas

## Foundation Models (Apple Intelligence)

Kaset integrates Apple's on-device Foundation Models framework for AI-powered features. See [ADR-0005: Foundation Models Architecture](adr/0005-foundation-models-architecture.md) for detailed design decisions.

### Architecture Overview

```
User Input (natural language)
    │
    ▼
┌─────────────────────────────────────────────────┐
│ FoundationModelsService                         │
│  → Check availability                           │
│  → Create session with tools                    │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ LanguageModelSession                            │
│  → Parse input to @Generable type               │
│  → Call tools for grounded data                 │
│  → Return structured response                   │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ Execute Action                                  │
│  → MusicIntent → PlayerService                  │
│  → QueueIntent → PlayerService queue methods    │
│  → LyricsSummary → Display in UI                │
└─────────────────────────────────────────────────┘
```

### Key Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `FoundationModelsService` | `Core/Services/AI/` | Singleton managing AI availability and sessions |
| `@Generable` Models | `Core/Models/AI/` | Type-safe structured outputs (`MusicIntent`, `LyricsSummary`, etc.) |
| Tools | `Core/Services/AI/Tools/` | Ground AI responses in real catalog data |
| `AIErrorHandler` | `Core/Services/AI/` | User-friendly error messages |
| `RequiresIntelligenceModifier` | `Core/Utilities/` | Hide AI features when unavailable |

### AI Features

| Feature | Trigger | Model Used |
|---------|---------|------------|
| Command Bar | ⌘K | `MusicIntent`, `MusicQuery` |
| Lyrics Explanation | "Explain" button in lyrics view | `LyricsSummary` |
| Queue Management | Natural language in command bar | `QueueIntent` |
| Queue Refinement | Refine button in queue view | `QueueChanges` |

### Best Practices

1. **Token Limit**: 4,096 tokens per session. Chunk large playlists, truncate long lyrics.
2. **Streaming**: Use `streamResponse` for long-form content (lyrics explanation).
3. **Tools**: Always use tools to ground responses in real data—prevents hallucination.
4. **Graceful Degradation**: Use `.requiresIntelligence()` modifier to hide unavailable features.
5. **Error Handling**: Use `AIErrorHandler` for user-friendly messages.

### PlayerBar

**File**: `Views/macOS/PlayerBar.swift`

A floating capsule-shaped player bar at the bottom of the content area:

```
┌─────────────────────────────────────────────────────────────┐
│  ◀◀  ▶  ▶▶  │  🎵 [Thumbnail] Song Title - Artist  │  🔊━━━ │
└─────────────────────────────────────────────────────────────┘
         ↑                      ↑                        ↑
    Playback              Now Playing              Volume
    Controls               Info                   Control
```

**Implementation**:
```swift
GlassEffectContainer(spacing: 0) {
    HStack {
        playbackControls
        Spacer()
        centerSection  // thumbnail + track info
        Spacer()
        volumeControl
    }
    .glassEffect(.regular.interactive(), in: .capsule)
}
```

**Key Points**:
- Uses `GlassEffectContainer` to wrap glass elements
- `.glassEffect(.regular.interactive(), in: .capsule)` for the liquid glass look
- Only shows functional buttons (no placeholder buttons)
- Thumbnail and track info in center section

### PlayerBar Integration

The `PlayerBar` must be added to **every navigable view** via `safeAreaInset`:

```swift
// In HomeView, LibraryView, SearchView, PlaylistDetailView
.safeAreaInset(edge: .bottom, spacing: 0) {
    PlayerBar()
}
```

**Why not in MainWindow?**
- `NavigationSplitView` detail views have their own navigation stacks
- Views pushed onto a `NavigationStack` don't inherit parent's `safeAreaInset`
- Each view must explicitly include the `PlayerBar`

### Sidebar

**File**: `Views/macOS/Sidebar.swift`

Clean, minimal sidebar with only functional navigation:

```
┌──────────────────┐
│ 🔍 Search        │  ← Main navigation
│ 🏠 Home          │
├──────────────────┤
│ Library          │  ← Section header
│ 🎵 Playlists     │  ← Functional items only
└──────────────────┘
```

**Design Principles**:
- Only show items that have implemented functionality
- Remove placeholder items (Artists, Albums, Songs, Liked Songs, etc.)
- Use standard SwiftUI `List` with `.listStyle(.sidebar)`

### Persistent UI Elements

UI elements that must remain visible across all navigation states (like the lyrics sidebar) should be placed **outside** the `NavigationSplitView` hierarchy in `MainWindow`:

```swift
// MainWindow.swift
var mainContent: some View {
    HStack(spacing: 0) {
        NavigationSplitView { ... }  // Sidebar + detail navigation
        
        // Lyrics sidebar OUTSIDE navigation - persists across all pushed views
        LyricsView(...)
            .frame(width: playerService.showLyrics ? 280 : 0)
    }
}
```

**Why?**
- Views pushed onto a `NavigationStack` replace content *inside* the stack
- If a sidebar is inside the stack, pushed views won't see it
- Placing persistent elements outside the navigation hierarchy ensures they remain visible regardless of navigation state

**Pattern**: Global overlays/sidebars → `MainWindow` level, outside `NavigationSplitView`

### @available Attributes

All UI components require macOS 26.0+ for Liquid Glass:

```swift
@available(macOS 26.0, *)
struct PlayerBar: View { ... }

@available(macOS 26.0, *)
struct MainWindow: View { ... }
```
