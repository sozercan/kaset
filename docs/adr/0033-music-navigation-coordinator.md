# ADR 0033: Music navigation coordinator and shared PlayerBar

## Status

Accepted

## Context

Each music content view mounted its own `PlayerBar` via `.safeAreaInset`, so navigation
switched destroyed and recreated the bar. That reset `@State`, re-ran `.task` work, and
caused artwork flicker (#445). Each view also owned a private `navigationPath` and
re-derived `PlayerBarNavigationAction` plumbing across ~18 call sites.

`MainWindow` already centralized paths for liked music and pinned sidebar playlists
(`pinnedNavigationPaths`).

## Decision

1. Introduce `MusicNavigationCoordinator`, an `@Observable` owner for all music sidebar
   navigation paths and the active route (tab or pinned playlist).
2. Mount a single `PlayerBar` on the music detail column in `MainWindow`, outside every
   `NavigationStack`.
3. Route-level album/artist context for the bar (`playerBarCurrentAlbumID`,
   `playerBarCurrentArtistID`) is updated by detail views through the coordinator on
   appear/disappear.
4. Remove per-view `PlayerBar` instances and `playerBarNavigationAction` init parameters;
   the shared bar in `MainWindow` reads `playerBarNavigationAction` from
   `MusicNavigationCoordinator`.

## Consequences

- `PlayerBar` identity is stable across sidebar navigation; seek, volume, and resolved
  targets persist.
- Navigation targeting for artist/album buttons lives in one coordinator instead of
  per-view copies.
- `#439`-class missing wiring bugs become unrepresentable for the shared bar.
- `popsNavigationStackOnSidebarReselect` and pinned path lifecycle stay per-stack; only
  ownership moves to the coordinator.
