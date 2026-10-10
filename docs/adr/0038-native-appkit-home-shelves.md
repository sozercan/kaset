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
(SwiftUI: header) → `HomeItemCollectionShelf`
(`NSViewRepresentable`) → `HomeItemShelfContainerView` (the scroll view plus
native paging arrows) → `HomeItemShelfView` (a plain horizontal
`NSScrollView` driven by a controller object) whose document view owns one
`HomeItemCell` per item for the shelf's lifetime.

`HomeItemCell` is a single layer-backed `NSView`. Artwork and its hover lift
are sublayers; title, subtitle and explicit badge are a cached bitmap on a
sublayer (the view has no backing store: `wantsUpdateLayer`); the like control
and chart rank are image layers.
The paging arrows are native too: an `NSGlassEffectView` per arrow (an
`NSVisualEffectView` on the macOS 15 path) in a container around the shelf's
scroll view, and the representable reports its size through `sizeThatFits`.
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
- Drawing the card text in `draw(_:)`: AppKit redisplays a view's backing
  store each time SwiftUI re-attaches the shelf, so every card re-typeset its
  title and subtitle at the viewport edge. Moving the text to a cached bitmap
  layer halved dropped frames (constant 2000 pt/s scroll, ~29 → ~14 per pass).
- A SwiftUI `.onHover` per shelf for the paging controls' prominence: SwiftUI
  re-hit-tests hover responders on every scroll frame. The shelf's own AppKit
  tracking area reports hover instead (~14 → ~8 dropped frames per pass).
- Letting SwiftUI size the shelf: without `sizeThatFits`, every realized shelf
  went through `intrinsicLayoutTraits` (Auto Layout measurement plus a window
  constraint pass). Reporting the size directly cut dropped frames ~35% at
  4000 pt/s.
- SwiftUI `.glassEffect()` paging arrows: SwiftUI re-resolves each glass
  element's context on every frame it moves, which was most of the remaining
  scroll cost (4000 pt/s: ~5–8 dropped frames per pass with SwiftUI glass, ~1
  with native glass, ~0 with no arrows). The shadow and hover animations
  measured as free.

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
