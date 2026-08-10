# AppleScript Support

Kaset supports AppleScript for automation with tools like Raycast, Alfred, and Shortcuts.

## Available Commands

| Command | Description |
| ------- | ----------- |
| `play` | Start or resume playback |
| `play video` | Play a YouTube Music item by its video ID |
| `pause` | Pause playback |
| `playpause` | Toggle play/pause |
| `next track` | Skip to next track |
| `previous track` | Go to previous track |
| `set volume N` | Set volume (0-100) |
| `seek N` | Seek to position N seconds in the current track |
| `toggle mute` | Mute/unmute |
| `toggle shuffle` | Toggle shuffle on/off (binary; does not reach Smart Shuffle) |
| `cycle repeat` | Cycle repeat (Off → All → One) |
| `like track` | Like current track |
| `dislike track` | Dislike current track |
| `get player info` | Get player state as JSON |
| `get play queue` | Get the current playing queue as JSON |
| `play track at index N` | Play a specific track from the queue by its index (1-based index) |

## Examples

### Basic Playback Control

```applescript
tell application "Kaset"
    play
    set volume 50
    toggle shuffle
end tell
```

### Play a YouTube Music item by video ID

```applescript
tell application "Kaset" to play video "dQw4w9WgXcQ"
```

For regular YouTube video links, use the URL routing documented in [URL Scheme and YouTube Links](url-scheme.md), for example `open -a Kaset "https://youtu.be/VIDEO_ID"`.

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

### Get Play Queue

```applescript
tell application "Kaset"
    get play queue
end tell
```

Returns JSON with the current playing queue:

```json
{
  "currentIndex": 2,
  "tracks": [
    {
      "name": "Song 1",
      "artist": "Artist 1",
      "album": "Album 1",
      "duration": 120,
      "videoId": "vid-1",
      "artworkURL": "https://..."
    },
    {
      "name": "Song 2",
      "artist": "Artist 2",
      "album": "",
      "duration": 180,
      "videoId": "vid-2",
      "artworkURL": ""
    }
  ]
}
```

*Note: `currentIndex` is a 1-based index pointing to the active song in the `tracks` array. It will be `0` if the queue is empty.*

### Play Specific Track from Queue

```applescript
tell application "Kaset"
    play track at index 2
end tell
```

*Note: The track index is 1-based, following AppleScript list indexing conventions. If the index is out of bounds, the command will raise an error.*

## Shell Usage

```bash
# Control playback
osascript -e 'tell application "Kaset" to play'
osascript -e 'tell application "Kaset" to pause'
osascript -e 'tell application "Kaset" to next track'

# Set volume (0-100)
osascript -e 'tell application "Kaset" to set volume 75'

# Seek to a position (seconds into the current track)
osascript -e 'tell application "Kaset" to seek 30'

# Toggle modes
osascript -e 'tell application "Kaset" to toggle shuffle'
osascript -e 'tell application "Kaset" to cycle repeat'

# Get player info as JSON
osascript -e 'tell application "Kaset" to get player info'

# Parse with jq
osascript -e 'tell application "Kaset" to get player info' | jq '.currentTrack.name'

# Get play queue as JSON
osascript -e 'tell application "Kaset" to get play queue'

# Play track at index 2 (1-based index)
osascript -e 'tell application "Kaset" to play track at index 2'
```

## Now Playing Notifications

Kaset posts a distributed notification named `com.sertacozercan.Kaset.playerInfo`
whenever discrete playback state changes (current track, play/pause, like status,
shuffle, or repeat). External now-playing surfaces — menu-bar widgets, or notch apps
such as boring.notch — can observe it to refresh reactively instead of polling on a
timer.

The notification is a **bare, change-only trigger**:

- It carries no payload (the App Sandbox strips `userInfo` from a sandboxed sender),
  so observers read the current state with `get player info`.
- It fires only on a *change*; there is no initial snapshot and a missed notification
  is not resent. Observers should call `get player info` once on startup for the
  initial state and keep a low-frequency poll as a fallback.
- High-frequency values — **playback position and volume** — are intentionally not
  triggers (they would flood the notification during playback and volume drags). Read
  `position` and `volume` from `get player info`, polling if you need them live.

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
