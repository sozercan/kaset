# URL Scheme and YouTube Links

Kaset supports deep links for opening content directly from other apps, scripts, or the command line. There are two URL families:

- `kaset://...` custom-scheme links for YouTube Music content
- Regular YouTube watch links (`youtube.com/watch` and `youtu.be`) routed into the YouTube source

## YouTube Music Custom Scheme

### Play a Song

Play a song by its YouTube Music video ID:

```bash
open "kaset://play?v=VIDEO_ID"
```

### Open Music Content

`URLHandler` can parse these custom-scheme routes:

| URL | Parsed content |
|-----|----------------|
| `kaset://play?v=VIDEO_ID` | Song playback through YouTube Music |
| `kaset://playlist?list=PLAYLIST_ID` | Music playlist |
| `kaset://album?id=ALBUM_ID` | Music album |
| `kaset://artist?id=CHANNEL_OR_LIBRARY_ARTIST_ID` | Music artist |

> Current app routing starts playback for `kaset://play`. Playlist, album, and artist parsing is available for navigation flows but is not exposed as a full external-routing UI yet.

## YouTube Music Web Links

Kaset also recognizes common `music.youtube.com` URLs:

| URL | Parsed content |
|-----|----------------|
| `https://music.youtube.com/watch?v=VIDEO_ID` | Song playback through YouTube Music |
| `https://music.youtube.com/playlist?list=PLAYLIST_ID` | Music playlist |
| `https://music.youtube.com/browse/MPRE...` / `OLAK...` | Music album |
| `https://music.youtube.com/channel/UC...` | Music artist |
| `https://music.youtube.com/browse/MPLAUC...` | Library artist |

## Regular YouTube Links

Regular YouTube watch links switch Kaset to the YouTube source and open the video in the floating YouTube player when they are delivered to Kaset. From Terminal, target the app explicitly so macOS does not hand the HTTPS URL to the default browser:

```bash
open -a Kaset "https://www.youtube.com/watch?v=VIDEO_ID"
open -a Kaset "https://youtu.be/VIDEO_ID"
```

Recognized hosts are `youtube.com`, `www.youtube.com`, `m.youtube.com`, and `youtu.be`. Non-watch YouTube pages are ignored by the URL handler.

## Usage Examples

### From Terminal

```bash
# Play a YouTube Music song
open "kaset://play?v=VIDEO_ID"

# Open a regular YouTube video in YouTube mode
open -a Kaset "https://www.youtube.com/watch?v=VIDEO_ID"
```

### From AppleScript

```applescript
do shell script "open 'kaset://play?v=VIDEO_ID'"
do shell script "open -a Kaset 'https://youtu.be/VIDEO_ID'"
```

### From Shortcuts

Use the "Open URLs" action with `kaset://play?v=VIDEO_ID`. For regular YouTube HTTPS links, use a "Run Shell Script" action with `open -a Kaset "https://youtu.be/VIDEO_ID"` so the link is sent to Kaset instead of the default browser.

## See Also

- [YouTube Mode](youtube.md) — Regular YouTube source architecture and playback behavior
- [Playback System](playback.md) — YouTube Music WebView playback
- [AppleScript Support](applescript.md) — Automate playback with scripts, Raycast, Alfred, and Shortcuts
