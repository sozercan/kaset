# Kaset

A native macOS YouTube Music client built with Swift and SwiftUI.

<img src="docs/screenshot.png" alt="Kaset Screenshot">

## Features

- 🎵 **Native macOS Experience** — Apple Music-style UI with Liquid Glass player bar and clean sidebar navigation
- 🎧 **YouTube Music Premium Support** — Full playback of DRM-protected content via your existing subscription
- 🎛️ **System Integration** — Now Playing in Control Center, media key support, Dock menu controls
- 📳 **Haptic Feedback** — Tactile feedback on Force Touch trackpads for player controls and navigation
- 🎶 **Track Notifications** — Get notified when a new track starts playing
- 🔊 **Background Audio** — Music continues playing when the window is closed; stops on quit
- ⌨️ **[Keyboard Shortcuts](docs/keyboard-shortcuts.md)** — Full keyboard control for playback, navigation, and more
- 🧭 **Explore** — Discover new releases, charts, and moods & genres
- 🎙️ **Podcasts** — Browse and listen to podcasts with episode progress tracking
- 📚 **Library Access** — Browse your playlists, liked songs, and subscribed podcasts
- 🔍 **Search** — Find songs, albums, artists, playlists, and podcasts
- ✨ **Apple Intelligence** — On-device AI for natural language commands, lyrics explanations, and playlist refinement
- 📜 **Lyrics** — View song lyrics with AI-powered explanations and mood analysis
- 📃 **Queue Management** — View, reorder, shuffle, and clear your playback queue
- 📣 **Share** — Share songs, playlists, albums, and artists via the native macOS share sheet
- 🔗 **[URL Scheme](docs/url-scheme.md)** — Open songs directly with `kaset://play?v=VIDEO_ID`
- 🤖 **[AppleScript Support](docs/applescript.md)** — Automate playback with scripts, Raycast, Alfred, and Shortcuts

## Requirements

- macOS 26.0 or later
- [Google](https://accounts.google.com) account

## Installation

### Download

Download the latest release from the [Releases](https://github.com/sozercan/kaset/releases) page.

### Homebrew

```bash
brew install sozercan/repo/kaset
```

> **Note:** The app is not signed.
> If you downloaded the app manually, you can clear extended attributes (including quarantine) with:
> ```bash
> xattr -cr /Applications/Kaset.app
> ```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, architecture, and coding guidelines.

We welcome AI-assisted contributions! You can submit traditional PRs or **prompt requests** — share the AI prompt that generates your changes, and maintainers can review the intent before running the code. See the [AI-Assisted Contributions](CONTRIBUTING.md#ai-assisted-contributions--prompt-requests) section for details.

## Disclaimer
Kaset is an unofficial application and not affiliated with YouTube or Google Inc. in any way. "YouTube", "YouTube Music" and the "YouTube Logo" are registered trademarks of Google Inc.
