# Keyboard Shortcuts

Kaset provides keyboard control for playback and navigation while preserving standard macOS window shortcuts.

## Playback

| Shortcut | Action                              |
| -------- | ----------------------------------- |
| `Space`  | Play / Pause                        |
| `⌘→`     | Next track                          |
| `⌘←`     | Previous track                      |
| `⌘↑`     | Volume up                           |
| `⌘↓`     | Volume down                         |
| `⌘S`     | Toggle shuffle (off/on; the player-bar control also cycles to Smart Shuffle) |
| `⌘R`     | Cycle repeat mode (Off → All → One) |
| `⇧⌘M`    | Switch to Mini Player               |

Mute is still available from the Playback menu and AppleScript, but Kaset intentionally does not assign a default mute shortcut so the native macOS minimize shortcut (`⌘M`) continues to work.

Playback shortcuts are source-aware where both sources implement an equivalent action: play/pause, skip, seek, and volume route to regular YouTube when a YouTube video was the last active playback source. Shuffle, repeat, queue, and lyrics remain YouTube Music concepts.

## Navigation

| Shortcut | Action           |
| -------- | ---------------- |
| `⌘1`     | Go to Home       |
| `⌘2`     | Go to Explore    |
| `⌘3`     | Go to Library    |
| `⌘F`     | Go to Search     |
| `⌘K`     | Open Command Bar |
| `⇧⌘R`    | Refresh Home suggestions |
| `⇧⌘Y`    | Switch source (YouTube Music ⟷ YouTube) |

Navigation shortcuts route to the active source's equivalent destination:
in YouTube mode, `⌘1`/`⌘2`/`⌘F` go to the YouTube Home/Explore/Search
surfaces and `⌘3` goes to Playlists.
`⇧⌘R` refreshes the active source's Home feed and bypasses its cached suggestions.

With macOS Keyboard navigation enabled, `Tab` moves between shelf cards and each
song's Like/Unlike control. `⇧Tab` moves in reverse. `Return` or `Space` activates
the focused card or toggles the focused Like/Unlike control.

With **Show Controls on Video** on (Settings → YouTube), any key press outside a
text field reveals the watch page's on-video controls for a few seconds. With
Keyboard navigation enabled, `Tab` keeps them up so focus can move into them,
until the pointer moves over the video again.
