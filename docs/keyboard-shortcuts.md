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
| `⌘S`     | Toggle shuffle                      |
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
| `⇧⌘Y`    | Switch source (YouTube Music ⟷ YouTube) |

Navigation shortcuts route to the active source's equivalent destination:
in YouTube mode, `⌘1`/`⌘2`/`⌘F` go to the YouTube Home/Explore/Search
surfaces and `⌘3` goes to Playlists.
