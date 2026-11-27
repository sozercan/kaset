# ADR-0047: View and ViewModel Invariants

## Status

Accepted

## Context

SwiftUI can recreate a view while its work is pending, and AppKit and WebKit
can publish UI state independently of Swift. These boundaries affect which
updates are safe to apply and which state can survive a view change. This record
captures constraints not evident from the individual call sites.

## Decision

### Session and loading boundaries

- `AuthService` owns account-switch preflight and registered account preparation;
  the account picker must not prepare the account service separately. The window
  re-points playback for history only on verified identity, not UI selection.
  Re-pinning the current identity does not invalidate the like scope or discard
  Liked Music pagination. An initial scope resolution before authenticated
  rendering also needs no second load; a resolution after fail-open does.
  See [ADR-0023](0023-brand-account-history-session-switch.md),
  [ADR-0037](0037-deferred-cookie-restoration.md), and
  [ADR-0041](0041-non-destructive-session-loss.md) for the session boundaries.
- A playlist detail task must run again on a transition to idle, including in
  the legacy view, because account scope can invalidate Liked Music after the
  initial render. Playlist edits retain the active load generation; replacing
  playback does not. A playlist row can only remove a track by its playlist-item
  identity, not just by the track's video ID. Suppress that occurrence in later
  pages so it cannot reappear after an edit. Smart Shuffle waits for playlist
  expansion before generating suggestions when the queue load defers them.
- Requests to refresh Music Home during an issued request coalesce into one
  follow-up using the current state. Broadcast optimistic library mutations
  and rollbacks to the relevant model instances so navigation paths do not
  disagree; fence late rollbacks by revision and account scope.
- For podcast discovery, only the foreground load treats an empty successful
  payload as definitive unavailability; a background probe needs stronger
  evidence ([ADR-0019](0019-podcasts-availability.md)). A show's episode pager
  keys the load by continuation token, not the visible row count: a page can
  add no new episode IDs yet still advance the cursor.
- The YouTube Home and watch-comment loads are single-flight across SwiftUI
  task restarts. An explicit refresh or account/route reset retires the old
  generation; a cancelled waiter alone does not. Returning to the same watch
  route must not implicitly fetch the next comment page. Discard an entry
  matching the parent ID defensively when loading replies, rather than relying
  on the response containing only replies or asserting that the server echoes
  the parent.
- YouTube Home can first paint the grid without waiting for the rails, but an
  empty grid keeps loading until the bounded rail and signed-out fallback paths
  settle. Limit automatic topic fan-out, preserve successful rails on retry, and
  coordinate the post-watch Continue Watching rebuild with full-feed publication.
  Rebuild by watch activity generation with fresh history, not on progress
  ticks or a bare playback start. A transient error preserves the rail and the
  ability to retry, while a successful empty result removes it. Keep pending
  activity across an ordinary refresh, but never across an account reset.
  Keep the pagination trigger mounted while a cursor exists, even with no
  visible videos.
- Guard search results by both query and filter after suspension. A nonempty
  mixed search returns without category fan-out. For an empty result or a
  non-authentication failure, fall back to category requests; one failed
  category does not discard successful ones, but an authentication failure must
  surface. Use [ADR-0028](0028-ordered-semantic-music-search-results.md) for ordering.

### Presentation and interaction

- Keep frequent scroll and playback updates out of broad view bodies. Shelf
  geometry is not observable; the shelf publishes derived overflow state. The
  player bar and mini player own seek state but leave per-tick reads to the
  timeline leaves. Share the mini-player seek hold across layouts and reconcile
  it on fresh state rather than committing a cancelled gesture.
- Preserve the edge-to-edge scroll track and resting content inset from
  [ADR-0021](0021-liquid-glass-sidebar-slide-under.md). Keep autocomplete attached
  as an overlay of the search field; making it participate in the bar's layout
  can materialize a second glass plate during updates. Keep the queue's AppKit
  table out of a `GlassEffectContainer`: the drop gap and destination callbacks
  require the regular material path.
- Isolate nested Like controls with a borderless button. When the play button
  is instead a sibling/background, a plain Like button plus the row's existing
  hover state avoids an AppKit button and a second hover tracker in every row.
  Populate playlist context submenus at parent-menu creation because open
  menus can snapshot their contents. Cancellation is not a load failure and
  must allow the next menu presentation to retry. Keep the share picker's weak
  delegate alive and offer Copy Link explicitly when system services omit it.
- Shelf hit-testing, accessibility and layout must survive AppKit views
  detaching and reattaching at the viewport edge. Clear hover and scoped
  observations on detach; do not require a `mouseExited` or bounds notification.
  Keep raw vertical gestures available to the page and physical arrow placement
  separate from logical paging. Match text and symbol cache keys to all rendering
  inputs, including backing scale and appearance; retain color for emoji. The
  base shelf architecture and measurements are in
  [ADR-0038](0038-native-appkit-home-shelves.md).
- An artwork memory hit renders synchronously, with no placeholder, fade, or
  view-state write. Include target size in the request identity and let eviction
  restart the load instead of copying cached pixels into each view's state.
  See [ADR-0044](0044-image-cache-and-palette-work.md) for the shared cache.
- A window drag handle belongs over noninteractive content: SwiftUI and WebKit
  can intercept mouse events before AppKit's background window drag sees them.
  Present the extension-folder picker with explicit activation and `runModal()`;
  the sheet API did not reliably present from the SwiftUI Settings tabs.

### Playback view boundaries

- Do not turn reparenting the persistent music WebView into navigation or CSS
  reinjection. Rebuilding video mode during a move can briefly reveal YouTube's
  UI. Apply video visibility after a bounded warmup and on player-tree/layout
  events, not via a permanent animation-frame loop. Multiple lyrics surfaces
  share the page's line-boundary polling; removing one must not stop another's
  updates, and a reload needs the last published boundaries.
- A ready media element wins over a lagging player bar. Keep an explicitly
  unknown physical identity unknown, and do not consume a deduplication slot
  until identity resolves or the observer reaches its deadline. Reject a bare
  document URL as artwork (`img.src` can resolve an empty attribute to it).
  Accept like status only after the bar catches up with the actual track.
  Media events supply the playback heartbeat when hidden-page timers throttle;
  keep a trailing send for throttled updates when no next tick is guaranteed.
  See [ADR-0026](0026-generation-scoped-web-playback-bridge.md) for the fences.
- Set autoplay and volume intent at document start; `didFinish` can arrive
  after media readiness. An advancing ad is not a stalled document. For restored
  playback, allow a paused preroll to advance without unsuppressing the content
  that still needs a seek. Enforce native volume without debouncing repeated
  page resets, and keep remote command registration native-owned for seek and
  explicit next/previous mode.
- On YouTube, a document-start target alone does not protect the first audible
  frame. Enforce it before media plays (including replacement players), muting
  before lowering to zero and setting the level before unmuting. Admit navigation
  before replacing the document and bind recovery seeks to ready, non-ad media
  for the intended occurrence; page metadata alone can lead the physical media.
- A provisional page queue insertion is not trusted until the visible queue
  confirms the target after the selected source. A stale `selected` attribute
  can disagree with the only row showing playback. Identify Play Next by its
  insertion endpoint rather than localized labels. Reused menus can open by
  changing visibility alone; gate the DOM observer and fallback to one attempt
  per opening. See [ADR-0035](0035-gapless-playback-native-queue.md).
- The inline watch view, Shorts, and the floating window host one YouTube
  WebView. A late Shorts update cannot claim it after selection changes. Let
  the AppKit container size the hosted view. For the pop-out, enforce aspect
  and size floor in one resize delegate; separate AppKit constraints can let
  one axis shrink far enough to crash hosting layout. Suspend frame autosave
  during fullscreen and restore it and the desired window level on confirmed
  exit or failed entry. Provide a native drag hit area. When inline controls
  hand off to the bottom bar, measure visibility without the bar's own safe-area
  inset, or it can perpetually hide the strip it waits for. The extracted watch
  surface forwards scroll to the native parent; unextracted documents keep their
  normal scrolling. Keep caption siblings visible even when the page controls
  are suppressed, and let native controls own the cursor.
- The ambient backdrop never samples protected playback frames. Use artwork
  as the fallback, with storyboard samples only for the matching video in
  live mode. Bound the timeline to 8 Hz and use a static thumbnail glow in
  Reduce Motion or Low Power Mode. Accept only HTTPS `ytimg.com` and its
  subdomains for storyboard URLs supplied by the page. Cap the grid, frames and
  sheets, crop full-size sheets using their actual dimensions, and skip padding
  cells on the final sheet. Pixel work stays off the main actor and a superseded
  load cannot publish its colors to a new selection. Numbered stills are a
  fallback, not a contract about exact sample times or crops.

### Tracked follow-ups

- History cursor replay [#615](https://github.com/sozercan/kaset/issues/615),
  filtered Home pagination [#614](https://github.com/sozercan/kaset/issues/614),
  and localized playlist authors [#612](https://github.com/sozercan/kaset/issues/612).
- Watch recovery re-seek [#611](https://github.com/sozercan/kaset/issues/611)
  and fractional surface clipping [#613](https://github.com/sozercan/kaset/issues/613).
- Persist the reviewed changes when applying a playlist refinement
  ([#619](https://github.com/sozercan/kaset/issues/619)).
- Replace extension-registry and restart timing assumptions
  ([#625](https://github.com/sozercan/kaset/issues/625)) and login cookie-settle
  sleeps ([#626](https://github.com/sozercan/kaset/issues/626)).

## Consequences

Loading, presentation, and playback can change independently without dropping
valid work or publishing a stale result. Keep the boundary behaviors covered
when replacing a UI surface or changing the ownership of its tasks.
