# AppleScript Support

Kaset supports AppleScript for automation with tools like Raycast, Alfred, and Shortcuts.

## Available Commands

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

## Examples

### Basic Playback Control

```applescript
tell application "Kaset"
    play
    set volume 50
    toggle shuffle
end tell
```

### Get Player State

```applescript
tell application "Kaset"
    get player info
end tell
```

Returns JSON with the current player state:

```json
{
  "isPlaying": true,
  "isPaused": false,
  "position": 45.2,
  "duration": 180.0,
  "volume": 75,
  "shuffling": true,
  "repeating": "all",
  "muted": false,
  "likeStatus": "liked",
  "currentTrack": {
    "name": "Song Title",
    "artist": "Artist Name",
    "album": "Album Name",
    "duration": 180,
    "videoId": "dQw4w9WgXcQ",
    "artworkURL": "https://..."
  }
}
```

## Shell Usage

```bash
# Control playback
osascript -e 'tell application "Kaset" to play'
osascript -e 'tell application "Kaset" to pause'
osascript -e 'tell application "Kaset" to next track'

# Set volume (0-100)
osascript -e 'tell application "Kaset" to set volume 75'

# Toggle modes
osascript -e 'tell application "Kaset" to toggle shuffle'
osascript -e 'tell application "Kaset" to cycle repeat'

# Get player info as JSON
osascript -e 'tell application "Kaset" to get player info'

# Parse with jq
osascript -e 'tell application "Kaset" to get player info' | jq '.currentTrack.name'
```

## Error Handling

If the player service is not yet initialized (e.g., during app launch), commands will return AppleScript error `-1728` with the message "Player service not initialized."

```applescript
tell application "Kaset"
    try
        play
    on error errMsg number errNum
        display dialog "Error: " & errMsg
    end try
end tell
```

## Integration Examples

### Raycast Script

```bash
#!/bin/bash
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Play/Pause Kaset
# @raycast.mode silent

osascript -e 'tell application "Kaset" to playpause'
```

### Alfred Workflow

Create a keyword trigger that runs:
```bash
osascript -e 'tell application "Kaset" to play'
```

### Shortcuts

Use the "Run AppleScript" action with:
```applescript
tell application "Kaset"
    playpause
end tell
```
