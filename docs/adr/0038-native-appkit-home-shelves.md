# ADR-0038: Native AppKit cards for Home-style shelves

## Status

Accepted

## Context

The Home, Explore, Charts, New Releases and Moods pages are a vertical SwiftUI
`ScrollView` of horizontal shelves. Built entirely in SwiftUI, scrolling
dropped 10–20% of frames at 120 Hz once a page had paginated to ~20 shelves,
and no view-level tuning (Equatable cards, cheaper shelf state, lighter hover
chrome) changed that by more than a few percent. Profiling showed the
per-frame cost was SwiftUI's own display-list and platform-view management for
hundreds of card subtrees, not the card bodies.

A throwaway `NSCollectionView` shelf with trivial cells brought dropped frames
to under one per scroll pass. Building it out for real surfaced the actual
invariant: SwiftUI detaches and re-attaches each shelf's platform view as it
crosses the viewport, and AppKit's cost for that — and for every scroll frame
while attached — scales with the number of `NSView`s in the subtree.

## Decision

Shelves of `HomeSectionItem` cards render through `HomeItemShelfSection`
(SwiftUI: header, glass paging arrows) → `HomeItemCollectionShelf`
(`NSViewRepresentable`) → `HomeItemShelfView` (a plain horizontal
`NSScrollView` driven by a controller object) whose document view owns one
`HomeItemCell` per item for the shelf's lifetime.

`HomeItemCell` is a single layer-backed `NSView`. Artwork and its hover lift
are sublayers; title, subtitle and explicit badge are drawn into the view's
bitmap once per configure; the like control and chart rank are image layers.
SwiftUI is used only for the hovered card's glass play overlay and for the
context menu (`NSHostingMenu` over the existing SwiftUI menu items), so the
existing menu logic, `SongLikeStatusManager`, and `ImageCache` are shared
rather than duplicated.

Measured, and therefore rejected:

- Hosting the SwiftUI card in collection-view cells keeps almost none of the
  win; the SwiftUI subtree itself is the per-frame cost.
- A page-level AppKit container (no SwiftUI culling, everything alive) is
  worse than SwiftUI culling; per-frame cost scales with live views.
- Subclassing `NSScrollView` for the shelf costs ~10 CPU points by itself.
- `NSCollectionView` recycling rebuilds every cell each time a shelf scrolls
  back onto the page; with a few dozen items per shelf, keeping cells is
  cheaper.
- Multi-view cells (text fields, buttons, badge views) cost ~7 dropped frames
  per pass through AppKit's attach/detach and constraint passes.

## Consequences

- Dropped frames per continuous scroll pass at 19 shelves: 19–24 → ~5.
- Card look and interactions are reimplemented natively and must be kept in
  step with `HomeSectionItemCard` (still used by Mood category pages):
  hover lift, like control, explicit badge, chart rank, two-line titles,
  accessibility label/role/actions, Return/Space activation under Full
  Keyboard Access.
- New card chrome must stay layer-based; adding `NSView`s per card brings the
  re-attach cost back.
- `CarouselShelfSection`/`CarouselShelf` remain for non-`HomeSectionItem`
  shelves (Favorites, Artist detail, Podcasts, YouTube).
