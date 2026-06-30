# ADR-0022: YouTube Home Sections — Continue Watching + Personalized Topic Rails

## Status

Accepted

## Context

The YouTube (video) Home tab rendered a single flat, vertical `LazyVGrid` of
recommended videos. We wanted a YouTube-Music-style home: a **Continue
Watching** rail of partially-watched videos on top, followed by several
**side-scrolling personalized sections** with real topic labels (Gaming, AI,
Music, …) — personalized, not arbitrary.

Investigation with `api-explorer --youtube` against a signed-in account
surfaced three facts that shaped the design:

1. **`FEwhat_to_watch` is a near-flat recommendation grid.** It returns a
   `richGridRenderer` of individual videos plus only 1–3 titled
   `richShelfRenderer` shelves (e.g. "Breaking news"). There is **no** rich
   set of named rails like YouTube Music's home, and **no** "Continue
   watching" shelf.
2. **Resume progress is per-video, not a shelf.** `YouTubeVideo.watchedPercent`
   (0–100) is already parsed from both renderer generations and already
   rendered as a red bar by `VideoThumbnailView`. The richest source of
   in-progress videos is the history feed (`FEhistory`).
3. **The home response carries a personalized filter-chip bar.** At
   `richGridRenderer.header.feedFilterChipBarRenderer`, ~18 chips
   (Gaming/Music/AI/News plus account-specific ones like "Bungie Inc.") each
   carry a `navigationEndpoint.continuationCommand.token`. Browsing a chip
   token returns a personalized, topic-filtered grid (the "Gaming" chip
   returned 67 gaming videos, ~5/67 overlapping default home) with its own
   pagination token. The response uses `reloadContinuationItemsCommand`, which
   `YouTubeFeedParser.parseContinuation` already handles.

## Decision

**Synthesize the sections client-side from existing endpoints; keep the change
additive.**

- **Continue Watching** is `getHistory().videos` filtered to
  `watchedPercent ∈ 1…95` (started, not effectively finished), excluding
  Shorts and live, deduped and capped. No new endpoint, no persistence — the
  history feed is the source of truth.
- **Topic rails** come from the home chip bar. Two new parser entry points,
  `parseChips` and `parseHomeShelves`, preserve the chip/shelf titles the old
  flattening walk discarded. New client methods `getHomeChips` /
  `getHomeShelves` (cache hits on the same `FEwhat_to_watch` response) and
  `getHomeTopicFeed(continuation:)` (reusing `parseContinuation`) expose them. The
  selected "All" chip (no token) is skipped.
- **New models** `YouTubeHomeSection { id, title, videos, kind }` and
  `YouTubeHomeChip` live alongside the unchanged flat `YouTubeFeed`. The view
  model gains a `sections` array built concurrently with the existing flat
  `videos` grid (an isolated `withTaskGroup` fetches all topic feeds in
  parallel, preserving chip order); per-section failures are logged and the
  section omitted, never failing the page.
- **The view** renders `sections` as `CarouselShelfSection` rails (the same
  generic shelf the music home uses) above the existing recommendation grid,
  reusing `VideoCard` as-is. The grid keeps its infinite-scroll pagination.

## Consequences

- The existing flat home pipeline (`getHomeFeed`, `loadMore`, `videos`) and
  its tests are untouched; the feature is purely additive, so the
  `YouTubeClientProtocol` change is new methods only (no signature churn).
- Topic rails depend on YouTube's chip bar, which is personalized and varies
  per account and over time; titles are carried through verbatim rather than
  matched against literals. Non-topic chips ("Watched", "Recently uploaded",
  "Mixes") are kept in YouTube's own order.
- Topic feeds re-request `FEwhat_to_watch` for chips (cache hit) then one
  `browse` per chip — bounded to ~8 rails at first paint. Per-rail
  continuation tokens are captured but in-rail "load more" is deferred.
- Parser shape depends on `richGridRenderer.header.feedFilterChipBarRenderer`
  and `richSectionRenderer.content.richShelfRenderer`; YouTube's renderer
  migration could move these. Inline parser tests pin the confirmed shapes;
  `api-explorer --youtube browse FEwhat_to_watch` is the re-discovery tool.

See [docs/youtube.md](../youtube.md) for the full architecture.
