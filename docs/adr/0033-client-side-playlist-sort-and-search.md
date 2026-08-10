# ADR-0033: Client-Side Playlist Sort and Search

## Status

Accepted

## Context

The playlist detail page needed sort (title / artist / duration / album) and
search. Both look like server-side features, and neither can be.

YouTube Music's playlist browse response has no server-side sort for playlist
contents — only library-level listings accept an `order` param. The nearer trap
is that a sort applied to the first page does not survive pagination: the
continuation tokens carry no sort state, so page two returns default order and
the list silently interleaves two orderings. Verified with `api-explorer`; see
`docs/api-discovery.md`.

That forces both features client-side, which in turn forces a decision about
partial data. A playlist is paged, so a sort or search over "what happens to be
loaded" is not a smaller version of the right answer — it is a different answer,
and it changes as pages arrive.

Three further questions followed:

1. **Where does the control live?** ADR-adjacent history matters here: PR #369
   put a sort control in the header action row and was withdrawn because
   `headerButtons` uses `ViewThatFits`, which re-measures both candidates on
   every layout pass when it shares an `HStack` with a flexible sibling. The
   header is inside the track `ScrollView`, so scrolling drove continuous
   re-measure — janky scroll and lagging hover (issue #375).
2. **What is a row's identity?** A sortable list invalidates position-as-identity.
3. **What does playback follow?** The visible order, or the playlist's own?

## Decision

**Sort and filter are a pure function over the fully-drained track set; the
displayed list is the single source for both rendering and playback.**

- `PlaylistTrackListPresenter` is a stateless enum: filter, then sort, no
  networking. Sort keys are decorated once per track — comparing `artistsDisplay`
  directly would re-join the artist array O(n log n) times — and the original
  index is the tie-break, so ordering is stable.
- Activating a sort or search drains the remaining pages (single-flight,
  coalescing with any in-flight drain) so the ordering covers every track.
  Typing debounces that drain; filtering itself applies immediately.
- `displayedTracks` is **cached**, not computed. SwiftUI re-evaluates the detail
  body on every observed change — each paged append, every `loadingState`
  transition — and a computed property re-ran the full filter and sort each time.
  Invalidation hangs off `playlistDetail`'s `didSet` so no load path can forget it.
- The controls live in the **toolbar**, outside the `ScrollView`. This is option 3
  of the four the reporter offered in #375, and it removes the `ViewThatFits`
  interaction rather than working around it. The sort control names the active key
  and direction, so the order is readable without opening the menu.
- Row identity is per-occurrence (`Song.rowIdentity`: namespaced set id, falling
  back to video id), shared with `PlaylistPlaybackActions` so display and playback
  agree on what "the same track" means.
- **Playback follows the displayed list.** Header Play / Play Next / Add to Queue
  and row taps all queue `displayedTracks`. When a sort or search is active and
  pages are still arriving, playback waits for the drain before building the queue.
  The existing play-immediately-and-top-up path appends from the raw playlist,
  which would replay a search's excluded tracks and abandon the sort partway down
  the queue. Unsorted, unfiltered playback keeps that path unchanged.

Sort and search are view state, not persisted, and reset per presentation.

## Consequences

**Easier.** Ordering rules are testable without a view or a network client.
Sorting cannot desynchronize from playback, because there is one list. The
toolbar placement leaves `headerButtons` alone, so #375's jank cannot recur
through this feature.

**Harder.** Sorting or searching a large playlist costs a full drain — many
continuation requests — before the answer is even correct. A setting
(`autoLoadFullPlaylistOnOpen`, off by default) lets users pay that cost on open
instead. Pressing Play with a sort active on a still-paging playlist now waits
rather than starting immediately; the drain banner reports progress, and the
list is not trustworthy before it finishes anyway.

**Watch for.** Invalidating from `didSet` means one full re-sort per mutation
rather than per frame. Paged appends are one mutation per page, which is the
intent, but a path that mutates `playlistDetail` in a tight loop would re-sort
each time; Liked Music's live-sync insert/remove is the one to watch if batches
ever grow.

**Not addressed.** The row number renumbers under sort. `Song` carries no
track-number field — the column has always been a positional ordinal — so
preserving album track numbers would mean parsing a field the API may not
expose. Deferred.
