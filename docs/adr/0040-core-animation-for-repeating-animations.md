# ADR-0040: Core Animation for repeating animations

## Status

Accepted

## Context

Two views animate for as long as music plays: the now-playing equalizer in the
current track's playlist row, and the player bar title, which scrolls like a
marquee when it is too long to fit. Both were SwiftUI animations: a
`repeatForever` on the equalizer bars' height, and `withAnimation` loops over
the marquee's `offset` and fade mask.

On macOS a running SwiftUI animation ticks through `NSHostingView.layout()` on
every display refresh, and each tick re-renders the window's display list. While
the window is key and the pointer is over it, AppKit also recomputes drag
regions and cursor rects on every tick, which hit-tests the SwiftUI responder
and focus trees. Measured on a debug build, Guest Mode, window 1312×821, track
muted (see #536):

| State | Kaset CPU |
|---|---|
| Playlist page, equalizer on screen | ~39% (pointer outside), ~82% (key window, pointer over the list) |
| Home page, long title scrolling | ~26% |
| Home page, short title | ~4% |
| Paused | ~0% |

Measured, and therefore rejected:

- Animating the bars with `scaleEffect` instead of a height frame: no change
  (~43% / ~82%). The cost is SwiftUI ticking the animation, not the layout the
  animated value causes; the marquee's `offset` animation, which never changes
  layout, cost the same.

## Decision

Animations that repeat indefinitely run in Core Animation, on layers the view
owns, so the render server draws every frame and the app does no per-frame
work.

- `EqualizerView` is an `NSViewRepresentable` over `EqualizerBarsView`: one
  `CALayer` per bar, with a repeating `CABasicAnimation` on
  `bounds.size.height` (not a scale, so the rounded ends stay round).
- `PlayerBarMarqueeText` keeps its SwiftUI accessibility label (as static
  text) and hosts `PlayerBarMarqueeView`: two `CATextLayer` copies on a scrolling layer, masked
  by a `CAGradientLayer`. One repeating keyframe animation scrolls the layer and
  another fades the mask; `PlayerBarMarqueeCycle` computes both timelines from
  the same rest, speed and fade constants the SwiftUI version used.
- Both views return `nil` from `hitTest` so clicks and context menus still
  reach the row and the player bar underneath, report their size through
  `sizeThatFits`, and restart their animations when attached to a window.

## Consequences

- Same setup, window uncovered and key:

  | State | Before | After |
  |---|---|---|
  | Playlist page, equalizer on screen | ~39% / ~82% | ~4% (either pointer position) |
  | Home page, long title scrolling | ~26% | ~1–3% |
  | Paused, long title scrolling | — | 0% |

  The remaining ~4% while playing is the playback progress updates, the same
  as a page with nothing animating. In a 5 s sample with the equalizer on
  screen, the main thread is 89% idle and `NSHostingView.layout()` drops from
  ~600 samples to ~56.
- New indefinitely repeating animations (spinners, shimmers, visualizers) should
  follow the same approach. Short, finite SwiftUI animations are unaffected:
  they tick only while they run.
- Text in the marquee is drawn by `CATextLayer` with `labelColor`, resolved
  against the view's appearance in `updateLayer`.
