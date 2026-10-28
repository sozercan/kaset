# Shortcuts, Siri, and Spotlight

Kaset provides native App Intents, so its actions appear in the Shortcuts app, respond to Siri, and show up in Spotlight without any setup.

## Actions

Find these in Shortcuts by searching for "Kaset".

| Action | What it does |
| ------ | ------------ |
| **Play Music** | Searches YouTube Music and plays the best matching song, followed by its radio. Returns the song. |
| **Play Song** | Plays a song you pick (search inside the action), followed by its radio. |
| **Play Playlist** | Plays a playlist: Liked Music, one from your Library, or any playlist found by search. |
| **Play Album** | Plays an album saved to your Library, or any album found by search. |
| **Play Liked Music** | Plays your Liked Music playlist. Requires sign-in. |
| **Play or Pause** | Pauses if something is playing, otherwise resumes. |
| **Pause** / **Resume Playback** | Pauses or resumes. |
| **Next Track** / **Previous Track** | Changes track, even when the media keys are set to skip forward/backward. |
| **Get Current Song** | Returns the playing song, with its title, artist, and album. |
| **Like Current Song** / **Dislike Current Song** | Rates the playing song. Unlike the player-bar buttons, these never toggle a rating off. Requires sign-in. |

Actions that start playback open Kaset, the same way a `kaset://` link does, and wait for it to finish launching. The transport actions (pause, resume, skip) control whichever source the media keys control, so they also work while a YouTube video is playing. If Kaset is not running or has nothing loaded, they report that nothing is playing.

## Siri

These phrases work without creating a shortcut:

- "Play music in Kaset" (Siri asks what to play)
- "Play my liked songs in Kaset"
- "Play *playlist name* in Kaset", for Liked Music and playlists in your Library
- "Pause Kaset" / "Resume Kaset"
- "Skip this song in Kaset" / "Previous song in Kaset"
- "Like this song in Kaset"
- "What's playing in Kaset"

Phrases are localized for every language Kaset ships.

## Spotlight

While you are signed in, Kaset indexes the playlists and albums in your Library. Search for one in Spotlight to play it. The index follows the signed-in account, and signing out clears it.

The same App Shortcuts are also available as Spotlight actions on macOS 26 and later.

## Requirements

- macOS only runs App Intents for apps signed with a team identity. Release builds are. Ad-hoc signed builds, including CI dev builds, list the actions but cannot run them: Shortcuts reports that it "couldn't communicate with the app".
- Kaset must be in `/Applications` or `~/Applications`. macOS does not register intents for apps run from hidden or temporary folders such as `.build/`.

For scripting beyond these actions, see [AppleScript Support](applescript.md) and the [URL scheme](url-scheme.md).
