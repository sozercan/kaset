# YouTube Music for macOS

A native macOS YouTube Music client built with Swift and SwiftUI.

## Features

- 🎵 **Native macOS Experience**: Built with SwiftUI for a seamless macOS experience
- 🔐 **Browser Cookie Authentication**: Auto-extracts cookies from an in-app login WebView
- 🎧 **YouTube Music Premium Support**: Hidden WebView playback supports DRM content
- 🎛️ **System Integration**: Now Playing in Control Center, media key support, Dock menu
- 📚 **Library Access**: Browse your playlists, search for music

## Requirements

- macOS 14.0 or later
- Xcode 15.0 or later
- Swift 6.0

## Building

1. Clone the repository
2. Open `YouTubeMusic.xcodeproj` in Xcode
3. Build and run (⌘R)

```bash
# Build from command line
xcodebuild -scheme YouTubeMusic -destination 'platform=macOS' build

# Run tests
xcodebuild -scheme YouTubeMusic -destination 'platform=macOS' test
```

## Project Structure

```
App/                → App entry point (YouTubeMusicApp.swift)
Core/
  ├── Models/       → Data models (Song, Playlist, Album, Artist, etc.)
  ├── Services/
  │   ├── API/      → YTMusicClient (YouTube Music API calls)
  │   ├── Auth/     → AuthService (login state machine)
  │   ├── Player/   → PlayerService, NowPlayingManager (playback control)
  │   └── WebKit/   → WebKitManager (cookie store, persistent login)
  ├── ViewModels/   → HomeViewModel, LibraryViewModel, SearchViewModel
  └── Utilities/    → DiagnosticsLogger, extensions
Views/
  └── macOS/        → SwiftUI views (MainWindow, Sidebar, PlayerBar, etc.)
Tests/              → Unit tests (YouTubeMusicTests/)
```

## Architecture

The app uses a clean architecture with:

- **Observable Pattern**: `@Observable` classes for reactive state management
- **MainActor Isolation**: All UI and service classes are `@MainActor` for thread safety
- **WebKit Integration**: Persistent `WKWebsiteDataStore` for cookie management
- **Swift Concurrency**: `async`/`await` throughout, no `DispatchQueue`

## License

This project is for educational purposes only.
