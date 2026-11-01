# Inline music video in the now-playing showcase

- Status: Accepted
- Date: 2026-10-25

## Context

The showcase can replace artwork with the current music video. Music playback uses one persistent DRM WebView, also hosted by the main audio anchor, mini player, and floating video window. Mounting two hosts can cause queued SwiftUI updates to move the WebView back to an obsolete container.

## Decision

`PlayerService.playbackViewHost` selects one owner from the main window, mini player, floating video window, and showcase. Each representable checks that owner before attaching the existing WebView. Inline video is separate from `showVideo`, so selecting the TV button does not create a window. Returning to an audio anchor explicitly restores hidden display mode; native-window cleanup preserves video mode when the showcase takes over.

The showcase's trailing panel is the morph target: the Up Next panel, lyrics panel, recommendations panel, and the video surface occupy the same column, and the showcase's transport stays shared. Tab buttons select their panel; the dedicated collapse control and the player bar’s lyrics/queue toggles can collapse it. The showcase retains an explicit mini-player button that intentionally switches to a separate mini-player window.

The video source follows YouTube Music's own Song/Video switch: the same playing occurrence stops the audio-version stream and loads the official music video at the aligned position (`PlayerService+ShowcaseVideo.swift`), swapping the queue row's song in place so playback identity stays coherent. When the loaded stream already carries video (live WebView evidence or an OMV track), it is hosted without a reload. A transparent surface above the video owns click-to-pause so the click cannot double-fire through the page's own video and overlay controls.

The showcase keeps the ambient backdrop's live mode, interpolating non-DRM thumbnail still colors with playback progress. DRM video pixels are never captured. That progress observation lives in a leaf view so it does not rebuild the showcase layout on every tick.

## Consequences

Switching presentation preserves the playback document, current track, and position. Mini player and floating video retain explicit ownership priority. Known audio-only track changes return to artwork, while transient WebView availability changes cannot make an active TV toggle impossible to turn off.
