# ADR-0021: Liquid Glass Sidebar Slide-Under

## Status

Accepted

## Context

On macOS 26 (Tahoe), `NavigationSplitView` renders its sidebar as a floating
Liquid Glass panel that sits in a functional layer *above* the detail column.
Apple Music uses this so browse content (album/playlist shelves) is faintly
visible, blurred, *through* the sidebar as it scrolls — the content slides
under the glass rather than stopping at the column boundary.

Kaset did not get this effect for free, for two independent reasons:

1. **The sidebar read as opaque.** The sidebar's `List(.sidebar)` painted the
   stock opaque `.sidebar` vibrancy material on top of the system Liquid Glass,
   occluding it. The glass was present but hidden, so the panel looked like a
   solid dark column. (The `GlassEffectContainer`/`VStack` wrapper was inert —
   `GlassEffectContainer` paints no background of its own.)

2. **Detail content never reached under the sidebar.** Every detail scroll view
   inset its content with a fixed `.padding(.horizontal, 24)`, so nothing was
   physically positioned in the band beneath the sidebar. The frosted glass had
   only the bare window background to sample, reinforcing the opaque look.

This contradicts the prior guidance in `architecture.md` ("Reserve glass for
navigation/floating controls — not for content areas") and its description of
the sidebar as "a standard SwiftUI `List` with `.listStyle(.sidebar)`", so a
decision record is warranted.

Several plausible-but-wrong levers were ruled out on-device and against the
macOS 26.5 SDK / Apple docs (WWDC 2025 sessions 256 & 323; the Landmarks
"Extending horizontal scrolling under a sidebar or inspector" sample):

- **`.scrollClipDisabled()`** only disables clipping on a scroll view's own
  frame within the detail column's coordinate space. It never routes content
  into the under-sidebar band, so it does not produce the effect.
- **`.contentMargins(.horizontal, …)` on a *horizontal* shelf** stops the
  scroll track short of the leading edge, which *defeats* the system's
  auto-scroll-under behavior.
- **`.backgroundExtensionEffect()`** mirrors and blurs a *single view's own
  pixels* into the safe area. It is for static hero/backdrop images, not for
  moving a live card grid under the sidebar.

## Decision

**Use the standard `NavigationSplitView` column sidebar (no overlay/ZStack
rebuild) and route real content into the band under the floating glass, the way
Apple's Landmarks sample does.** Two coordinated changes:

1. **Reveal the system sidebar glass (subtractive).** Make `List` the sidebar
   column root and hide its opaque scroll-content background via
   `.scrollContentBackground(.hidden)`, exposed through a gated compat shim
   `compatTranslucentSidebar()`. The footer rides the same glass via
   `.safeAreaInset(edge: .bottom)`. No explicit `.glassEffect()` is added — that
   would be glass-on-glass and darken the panel. Applied to both `Sidebar` and
   `YouTubeSidebar`. On the legacy macOS 15 path the same shim instead lays an
   `.ultraThinMaterial` behind the sidebar so it still reads as a blurred,
   translucent panel (the material the player bar uses) rather than a flat
   opaque column. Note this material is vibrant over the *window* (desktop),
   not the detail cards — true content-through under the sidebar is a macOS 26
   behavior.

2. **Route detail content under the sidebar.**
   - *Horizontal shelves* (`CarouselShelf`): run the scroll track edge-to-edge
     and move the resting inset into a leading `Spacer` *inside* the row
     (`contentInset`). When the track touches the leading edge, the system
     auto-scrolls live cards under the glass. The old leading edge-fade `.mask`
     was removed because it faded cards to transparent in exactly the band that
     should refract through the glass.
   - *Vertical grids/lists and accent-backdrop detail pages*: convert fixed
     `.padding(.horizontal, 24)` to
     `.contentMargins(.horizontal, …, for: .scrollContent)` so the scroll view
     reaches the column edge while keeping an unchanged resting inset. (Vertical
     content does not visibly *slide* under the sidebar — that is inherently a
     horizontal-scroll effect — but its edge and any accent backdrop refract
     through the glass.)

A shared `DetailContentLayout.horizontalInset` constant (24) keeps the resting
inset consistent across all surfaces.

### Gating

`compatTranslucentSidebar()` branches on **both** `!usesLegacyMacOS15UI`
**and** `#available(macOS 26.0, *)`. The `usesLegacyMacOS15UI` flag is a debug
toggle, not the OS version. On macOS 26 (non-legacy) it hides the list
background to reveal the system Liquid Glass; otherwise (legacy flag, or real
macOS 15 where the `#available` check is false at runtime) it falls back to an
`.ultraThinMaterial` frosted panel. The `.contentMargins`/`Spacer` layout
changes are macOS 14+ and produce the same resting layout on the legacy path
(there is simply no glass to slide under).

## Consequences

- The sidebar is a translucent Liquid Glass panel; horizontal shelves slide
  under it as Apple Music does. The show-through is a faint, blurred, tinted
  hint (not crisp transparency) — this is the intended native appearance and
  keeps sidebar labels legible.
- The effect is macOS 26 only. The legacy macOS 15 path keeps the same resting
  content layout and renders the sidebar as a frosted `.ultraThinMaterial`
  panel (translucent over the window, not the detail cards).
- `CarouselShelf` lost its edge-fade mask, `fadeWidth`, `hoverBleed`, and the
  associated `maskColors`. The paging-control affordances are unchanged.
- This refines the previous "glass is for navigation, not content" guidance:
  content is not *given* a glass material; rather, standard content is allowed
  to pass beneath the system-provided navigation glass.

## References

- Apple — Landmarks: Extending horizontal scrolling under a sidebar or inspector
- Apple — `View.backgroundExtensionEffect()`, `View.scrollContentBackground(_:)`
- Apple — Adopting Liquid Glass (Technology Overviews)
- WWDC 2025 — Sessions 256 (What's new in SwiftUI) and 323 (Build a SwiftUI app
  with the new design)
