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
| `toggle mute` | Mute/unmute |
| `toggle shuffle` | Toggle shuffle on/off (binary; does not reach Smart Shuffle) |
| `cycle repeat` | Cycle repeat (Off → All → One) |
| `like track` | Like current track |
| `dislike track` | Dislike current track |
| `get player info` | Get player state as JSON |
| `get play queue` | Get the current playing queue as JSON |
| `play track at index N` | Play a specific track from the queue by its index (1-based index) |
| `play videos {"id1", "id2"} [starting at N]` | Replace the queue with these video IDs and start playing at a 1-based index (default 1) |
| `add to queue {"id1", "id2"} [with next]` | Append video IDs to the queue, or insert them after the current track `with next` |
| `remove from queue "id"` | Remove every occurrence of a video ID from the queue |

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

### Build the Queue by Video ID

```applescript
tell application "Kaset"
    -- Replace the queue and start playing the second video
    play videos {"CLNaOxz3dr4", "SNNCW_DDAn4", "dQw4w9WgXcQ"} starting at 2

    -- Insert after the current track
    add to queue {"CLNaOxz3dr4"} with next

    -- Append to the end of the queue
    add to queue {"SNNCW_DDAn4"}

    -- Remove every occurrence of a video
    remove from queue "dQw4w9WgXcQ"
end tell
```

*Notes:*

- *Queued videos start as ID-only entries titled "Loading..." and get their title, artist and artwork filled in shortly afterwards, the same as `play video`.*
- *`play videos` uses the same 1-based indexing as `play track at index`. An empty list raises error `-1700`; an out-of-range `starting at` raises error `-1728`. If shuffle is on, the starting video plays first and the rest of the list is shuffled, as when starting a playlist.*
- *`add to queue` never starts playback, even when the queue is empty. `next` is a boolean parameter, so write `with next` (or `next true`).*
- *`remove from queue` removes every copy of the video and raises error `-1728` if the queue does not contain it.*

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

# Get play queue as JSON
osascript -e 'tell application "Kaset" to get play queue'

# Play track at index 2 (1-based index)
osascript -e 'tell application "Kaset" to play track at index 2'

# Replace the queue by video ID and start at the second video
osascript -e 'tell application "Kaset" to play videos {"CLNaOxz3dr4", "SNNCW_DDAn4"} starting at 2'

# Insert a video after the current track
osascript -e 'tell application "Kaset" to add to queue {"CLNaOxz3dr4"} with next'

# Remove a video from the queue
osascript -e 'tell application "Kaset" to remove from queue "CLNaOxz3dr4"'
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
