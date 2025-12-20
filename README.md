# Kaset

A native macOS YouTube Music client built with Swift and SwiftUI.

<img src="docs/screenshot.png" alt="Kaset Screenshot" width="800">

## Features

- 🎵 **Native macOS Experience** — Apple Music-style UI with Liquid Glass player bar and clean sidebar navigation
- 🎧 **YouTube Music Premium Support** — Full playback of DRM-protected content via your existing subscription
- 🎛️ **System Integration** — Now Playing in Control Center, media key support, Dock menu controls
- 🔊 **Background Audio** — Music continues playing when the window is closed; stops on quit
- 📚 **Library Access** — Browse your playlists, liked songs, albums, and artists
- 🔍 **Search** — Find songs, albums, artists, and playlists

## Requirements

- macOS 26.0 or later
- YouTube Music Premium subscription (for playback)

## Installation

### Download

Download the latest release from the [Releases](https://github.com/sozercan/kaset/releases) page.

### Build from Source

1. Clone the repository
2. Open `Kaset.xcodeproj` in Xcode 16.0+
3. Build and run (⌘R)

## Usage

### Sign In

When you first launch Kaset, you'll be prompted to sign in to your YouTube Music account. This is done through an in-app browser that securely captures your session cookies.

### Playback

- Click any song to start playback
- Use the player bar at the bottom to control playback
- Use media keys (play/pause, next, previous) to control playback from anywhere

### Background Listening

- Close the window (⌘W) to continue listening in the background
- Click the Dock icon to bring the window back
- Quit the app (⌘Q) to stop playback

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Space | Play/Pause |
| ⌘W | Close window (audio continues) |
| ⌘Q | Quit (audio stops) |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, architecture, and coding guidelines.

## License

This project is for educational purposes only.
