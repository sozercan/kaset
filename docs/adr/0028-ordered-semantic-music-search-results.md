# ADR-0028: Ordered Semantic YouTube Music Search Results

## Status

Accepted

## Context

YouTube Music search responses are heterogeneous and change renderer wrappers
without changing the underlying endpoint. Current mixed responses can contain a
playable Top Result, nested card rows, individually wrapped
`itemSectionRenderer` rows, direct shelves, podcast shows, podcast episodes,
profiles, audiobooks, songs, and multiple video kinds.

Kaset previously stored search results in separate type arrays and rebuilt the
visible list in a fixed songs → albums → artists → playlists → podcasts order.
That discarded YouTube Music's relevance ranking. The parser also assumed direct
shelves, treated every playable row as a song, ignored podcast shows, and kept a
single hidden client-owned search continuation value shared across filters.

The hidden continuation value made ownership ambiguous: query changes, filter
changes, fallback fan-out, and pagination all mutated one client cursor. Live
search continuations are also carried by the result shelf and must be posted to
the `search` endpoint, not the generic `browse` continuation path.

## Decision

`SearchResponse.items` is the canonical search representation.

- `SearchResultItem` carries semantic cases for song, video, album, audiobook,
  artist, profile, playlist, podcast show, and podcast episode.
- Existing models remain the payloads: videos use `Song`, profiles use `Artist`,
  audiobooks use `Album`, and episodes use `PodcastEpisode`.
- Typed collections such as `songs`, `videos`, `profiles`, and
  `podcastEpisodes` are computed projections. Compatibility initializers build a
  grouped item list for existing category-specific callers, while mixed parsing
  uses the ordered initializer.
- Mixed parsing traverses only known result containers in response-array order:
  Top Result, nested Top Result rows, direct shelves, and item-section wrappers.
  It does not recursively enter menus, overlays, or unrelated commands.
- First occurrence wins when multiple renderer paths expose the same content.
  Deduplication uses destination identity rather than the semantic case prefix,
  so a video and episode with the same playable ID cannot appear twice.
- Playable rows retain `musicVideoType`; videos and podcast episodes are no
  longer displayed as ordinary songs. `MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC`
  is recognized as a search video without changing the player bar's stricter
  video-toggle policy.
- Search pagination is caller-owned. Filtered responses expose their continuation
  value, and callers pass that value explicitly to `getSearchContinuation`.
  The client no longer owns a shared mutable search cursor. The view model also
  scopes each continuation request to the current result generation and discards
  responses after a query, filter, refresh, or clear invalidates that generation.
- Search continuations are requested from `/search` and parsed through the same
  ordered semantic item pipeline. Both legacy `musicShelfContinuation` envelopes
  and action envelopes using append/reload continuation commands are supported.
- Videos, Profiles, and Episodes are first-class filters alongside the existing
  filters. Static no-spelling-correction params are retained as direct-filter
  fallbacks because full server-issued chip params vary by query context.

## Consequences

- Search preserves the server's Top Result and relevance order.
- Modern renderer wrappers no longer turn valid responses into empty results.
- Videos, profiles, audiobooks, podcast shows, and episodes have correct labels,
  navigation, and playback behavior.
- Pagination no longer depends on hidden cross-query client state, cannot use
  the wrong filter's cursor, and cannot append a stale page into newer results.
- Existing rows remain visible during `.loadingMore`; only the inline continuation
  footer changes to a progress indicator, preserving scroll context.
- Parser and view-model tests must assert ordered semantic items rather than only
  bucket counts.
- Compatibility initializers still group category arrays, so non-mixed callers do
  not need immediate migration.
- Adding a future search type requires a new semantic case and explicit parser/UI
  handling, making unsupported API changes visible at compile time.
