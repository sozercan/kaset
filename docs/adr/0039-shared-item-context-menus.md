# ADR-0039: Shared context menus per item type

## Status

Accepted

## Context

Each page built its own right-click menu from single-entry helpers
(`FavoritesContextMenu`, `ShareContextMenu`, `LikeDislikeContextMenu`,
`AddToQueueContextMenu`, `AddToPlaylistContextMenu`, `StartRadioContextMenu`).
The same item type got different entries and orders depending on the page,
and several pages (Explore, Charts, New Releases, Moods & Genres, most Artist
shelves, podcast episodes) had no menu at all.

## Decision

`SharedViews/ItemContextMenus.swift` defines one menu per item type:
`SongContextMenu`, `AlbumContextMenu`, `PlaylistContextMenu`,
`ArtistContextMenu`, `PodcastShowContextMenu` and `EpisodeContextMenu`, plus
`HomeSectionItemContextMenu` and `SearchResultItemContextMenu` to dispatch on
the item enums. Pages call these instead of assembling entries.

The entries are the union of what any page offered for that type, in the order
most pages already used. Albums, and playlists that can be quick-played, have a
Play entry that starts them without opening them. What legitimately differs by
page is passed in:

- `play`: for songs and episodes, the host's own tap action, so Play from the
  menu does exactly what tapping the card does on that page (radio on shelves,
  the surrounding list in playlists, albums, Top Songs and History). Nil hides
  Play, for the current track in the queue and the player bar.
- `navigate`: a `(any Hashable) -> Void` sink for "View…" and "Go to…"
  entries. Nil uses `NavigationLink(value:)`; hosts outside a
  `NavigationStack`, or menus hosted in `NSHostingMenu`, route the value
  themselves.
- `showsGoToArtist`, `showsGoToAlbum`, `showsViewPodcast`: turned off where
  the link would open the page already showing (an artist's top songs, an
  album's tracks, a podcast's episodes) or where the host cannot navigate (the queue, the
  player bar on some pages).
- `libraryToggle`: replaces Add to Library with Add/Remove when the host
  knows whether the song is saved (the player bar).

Entries that only make sense on one page (Remove from Playlist, Remove from
Queue, Delete Playlist, Favorites reordering) are written by the page after
the shared menu, below a divider.

## Consequences

- Adding or reordering an entry for a type is one change, and every page picks
  it up.
- Entries a type has on one page now appear on all pages, e.g. Add to Library
  for songs on Home and History, Share for podcast shows.
- A new per-page difference in an existing entry should become a parameter on
  the shared type rather than a return to an inline menu.
- Mood and genre category tiles arrive as playlists but get no menu.
- Out of scope: the AppKit queue side panel menu, the sidebar's pinned-item
  menu (reordering only), and YouTube (non-music) views.
