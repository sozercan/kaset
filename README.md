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
- ⌨️ **Keyboard Shortcuts** — Full keyboard control for playback, navigation, and more
- 🧭 **Explore** — Discover new releases, charts, and moods & genres
- 🎙️ **Podcasts** — Browse and listen to podcasts with episode progress tracking
- 📚 **Library Access** — Browse your playlists, liked songs, and subscribed podcasts
- 🔍 **Search** — Find songs, albums, artists, playlists, and podcasts
- ✨ **Apple Intelligence** — On-device AI for natural language commands, lyrics explanations, and playlist refinement
- 📜 **Lyrics** — View song lyrics with AI-powered explanations and mood analysis
- 📃 **Queue Management** — View, reorder, shuffle, and clear your playback queue
- 📣 **Share** — Share songs, playlists, albums, and artists via the native macOS share sheet
- 🔗 **URL Scheme** — Open songs directly with `kaset://play?v=VIDEO_ID`
- 🤖 **AppleScript Support** — Automate playback with scripts, Raycast, Alfred, and Shortcuts

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

## Keyboard Shortcuts

### Playback

| Shortcut | Action                              |
| -------- | ----------------------------------- |
| `Space`  | Play / Pause                        |
| `⌘→`     | Next track                          |
| `⌘←`     | Previous track                      |
| `⌘↑`     | Volume up                           |
| `⌘↓`     | Volume down                         |
| `⌘⇧M`    | Mute / Unmute                       |
| `⌘S`     | Toggle shuffle                      |
| `⌘R`     | Cycle repeat mode (Off → All → One) |

### Navigation

| Shortcut | Action           |
| -------- | ---------------- |
| `⌘1`     | Go to Home       |
| `⌘2`     | Go to Explore    |
| `⌘3`     | Go to Library    |
| `⌘F`     | Go to Search     |
| `⌘K`     | Open Command Bar |

## URL Scheme

Kaset supports a custom URL scheme for opening content directly:

```bash
# Play a song by video ID
open "kaset://play?v=dQw4w9WgXcQ"
```

## AppleScript

Kaset supports AppleScript for automation with tools like Raycast, Alfred, and Shortcuts.

### Available Commands

| Command | Description |
| ------- | ----------- |
| `play` | Start or resume playback |
| `pause` | Pause playback |
| `playpause` | Toggle play/pause |
| `next track` | Skip to next track |
| `previous track` | Go to previous track |
| `set volume N` | Set volume (0-100) |
| `toggle mute` | Mute/unmute |
| `toggle shuffle` | Toggle shuffle mode |
| `cycle repeat` | Cycle repeat (Off → All → One) |
| `like track` | Like current track |
| `dislike track` | Dislike current track |
| `get player info` | Get player state as JSON |

### Examples

```applescript
-- Basic playback control
tell application "Kaset"
    play
    set volume 50
    toggle shuffle
end tell

-- Get current player state (returns JSON)
tell application "Kaset"
    get player info
end tell
```

### Shell Usage

```bash
# Control playback
osascript -e 'tell application "Kaset" to play'
osascript -e 'tell application "Kaset" to set volume 75'

# Get player info as JSON
osascript -e 'tell application "Kaset" to get player info'
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, architecture, and coding guidelines.

We welcome AI-assisted contributions! You can submit traditional PRs or **prompt requests** — share the AI prompt that generates your changes, and maintainers can review the intent before running the code. See the [AI-Assisted Contributions](CONTRIBUTING.md#ai-assisted-contributions--prompt-requests) section for details.

## Disclaimer
Kaset is an unofficial application and not affiliated with YouTube or Google Inc. in any way. "YouTube", "YouTube Music" and the "YouTube Logo" are registered trademarks of Google Inc.
