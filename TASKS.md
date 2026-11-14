# Tasks

## Batch 1 (in flight, 3 agents in parallel)

- [x] 1. Panel isolation: in any page, hovering content "through" the lyrics/queue panels must not activate the content underneath; each panel feels like its own surface. (One unverified edge: native shelf-hover occlusion — check by hand.)
- [x] 2. Remove the auto "Liked Music" playlist row from the sidebar Playlists section (already listed under Collection); a genuinely user-created playlist named "Liked Music" must NOT be filtered.
- [x] 3. Show playlist cover art in the sidebar playlist rows (replacing the generic glyph).
- [x] 4. 3rd-party syllable-synced lyrics: auto-fetch popular keyless providers (industry standard for open-source YT Music clients), pick the best/most popular lyrics for the song, render with syllable sync. (NetEase word-level + KuGou line-level; Musixmatch verified dead keyless, not implemented.)
- [x] 5. Online lyrics translation (industry standard provider for open-source YT Music clients), shown together with pronunciation/romanization. (Google gtx endpoint, on-device kept as offline fallback.)
- [x] 6. Hover feedback on sidebar buttons/rows that are clickable.

## Batch 2 (after batch 1 lands)

- [x] 7. Spacing polish: small spacing details across the app (no overhaul).
- [x] 8. Modern button treatment app-wide (hover + press feedback, Apple Music-like, replacing old-iTunes look).
- [x] 9. Now-playing showcase: clicking the playing song's name opens a full-window album/single cover showcase overlay (researched from YT Music/Apple Music), click again or Esc dismisses.

## Process rules

- Sol review after each feature lands; fixes go back to the coding agent; feature is done only when sol is clean.
- 3 subagents at a time; no commits/PRs until the user tests and gives the go-ahead.
