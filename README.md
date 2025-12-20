# Kaset

A native macOS YouTube Music client built with Swift and SwiftUI.

<img src="docs/screenshot.png" alt="Kaset Screenshot" width="800">

## Features

- 🎵 **Native macOS Experience** — Apple Music-style UI with Liquid Glass player bar and clean sidebar navigation
- 🎧 **YouTube Music Premium Support** — Full playback of DRM-protected content via your existing subscription
- 🎛️ **System Integration** — Now Playing in Control Center, media key support, Dock menu controls
- 🔊 **Background Audio** — Music continues playing when the window is closed; stops on quit
- 🧭 **Explore** — Discover new releases, charts, and moods & genres
- 📚 **Library Access** — Browse your playlists, liked songs, albums, and artists
- 🔍 **Search** — Find songs, albums, artists, and playlists

## Requirements

- macOS 26.0 or later
- [YouTube Music Premium](https://www.youtube.com/musicpremium) subscription

## Installation

### Download

Download the latest release from the [Releases](https://github.com/sozercan/kaset/releases) page.

### Homebrew

```bash
brew tap sozercan/kaset
brew install --cask --no-quarantine kaset
```

> **Note:** The `--no-quarantine` flag is required because the app is not signed.
> If you downloaded the app manually, you can remove the quarantine attribute with:
> ```bash
> xattr -d com.apple.quarantine /Applications/Kaset.app
> ```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, architecture, and coding guidelines.
