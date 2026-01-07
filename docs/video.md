# Video Mode

This document details the Picture-in-Picture (PiP) video playback feature.

## Overview

Video Mode allows users to watch music videos in a floating window while using other apps. The feature leverages the same singleton WebView used for audio playback to display video content.

## Architecture

### Components

| Component | File | Purpose |
|-----------|------|---------|
| `VideoWindowController` | `App/VideoWindowController.swift` | Manages the floating video window lifecycle |
| `VideoPlayerWindow` | `Views/macOS/VideoPlayerWindow.swift` | SwiftUI view for video display |
| `VideoContainerView` | `Views/macOS/VideoPlayerWindow.swift` | NSView container that hosts the WebView |
| `SingletonPlayerWebView+VideoMode` | `Views/macOS/SingletonPlayerWebView+VideoMode.swift` | CSS injection for video extraction |

### Display Modes

The `SingletonPlayerWebView` supports three display modes:

```swift
enum DisplayMode {
    case hidden     // 1×1 pixel, audio-only playback
    case miniPlayer // 160×90 pixel toast for user interaction
    case video      // Full-size video in floating window
}
```

## Video Window Features

### Window Properties

| Property | Value | Reason |
|----------|-------|--------|
| `level` | `.normal` | Standard window (not always-on-top) |
| `collectionBehavior` | `[.canJoinAllSpaces, .fullScreenAuxiliary]` | Visible on all Spaces, works with fullscreen apps |
| `aspectRatio` | `16:9` | Maintains video aspect ratio during resize |
| `minSize` | `320×180` | Minimum readable size |
| `backgroundColor` | `.black` | Letterbox color for non-16:9 content |

### Corner Snapping

The video window remembers its position across sessions:
- Position is saved to `UserDefaults` when window closes
- Window repositions to nearest corner (top-left, top-right, bottom-left, bottom-right)
- Default corner: bottom-right

## Video Extraction

When entering video mode, JavaScript extracts the `<video>` element from YouTube Music's DOM:

### Injection Flow

1. **Click Video Tab**: Attempts to click YouTube Music's "Video" toggle (if available)
2. **Create Container**: Creates `#kaset-video-container` with `position: fixed`
3. **Move Video**: Moves `<video>` element into the container
4. **Enable Controls**: Sets `video.controls = true` for native HTML5 controls
5. **Apply Volume**: Syncs video volume with app's volume setting

### CSS Strategy

```javascript
container.style.cssText = `
    position: fixed !important;
    top: 0 !important;
    left: 0 !important;
    width: 100vw !important;
    height: 100vh !important;
    z-index: 2147483647 !important;
`;
```

The container uses viewport units (`100vw`/`100vh`) so it **automatically resizes** when the window is resized. No re-injection is needed on resize.

## Resize Handling

The video container uses CSS that auto-adjusts to window size:
- `refreshVideoModeCSS()` is called on resize but does nothing substantive
- The `position: fixed` with `100vw/100vh` handles resize natively
- No re-extraction of the video element is performed on resize

## Window Lifecycle

### Opening Video Window

```
User clicks Video button
    → PlayerService.showVideo = true
    → MainWindow.onChange() calls VideoWindowController.show()
    → VideoWindowController creates NSWindow + VideoPlayerWindow
    → SingletonPlayerWebView.updateDisplayMode(.video)
    → injectVideoModeCSS() extracts video to fullscreen container
```

### Closing Video Window

```
User clicks close button (red X)
    → NSWindow.willCloseNotification fires
    → windowWillClose() saves corner position
    → performCleanup() calls updateDisplayMode(.hidden)
    → removeVideoModeCSS() restores video to original location
    → PlayerService.showVideo = false
```

### Track Changes

When a new track starts while video window is open:
- Video window closes automatically
- User can reopen for the new track
- This prevents showing wrong video for the audio

## Known Issues & Solutions

### Issue: Video Turns Off on Resize (FIXED)

**Root Cause**: The `hasVideo` detection in the JavaScript observer became unreliable when video mode was active. When the video element was extracted from the DOM or the Song/Video toggle buttons were hidden by our CSS, the observer would report `hasVideo=false`. The `updateVideoAvailability` function would then auto-close the video window.

**Solution**: Removed the auto-close behavior from `updateVideoAvailability`. The video window now only closes when:
1. User explicitly closes it (red X button)
2. Track changes (handled by `trackChanged` in the Coordinator)
3. User toggles `showVideo` off

The `hasVideo` property is still updated and used to enable/disable the Video button in the UI, but it no longer affects an already-open video window.

### Issue: Volume Jump When Opening Video

**Root Cause**: Moving the video element could cause a momentary volume spike.

**Solution**: The injection script now:
1. Mutes the video before extraction
2. Sets the correct volume
3. Unmutes after extraction

### Issue: Video Availability

**Root Cause**: Not all songs have music videos available.

**Solution**: `PlayerService.hasVideo` tracks video availability. The Video button is only enabled when a video exists.

## Debugging

### Enable WebView Inspector

In Debug builds, right-click the video window and select "Inspect Element":

```swift
#if DEBUG
    webView.isInspectable = true
#endif
```

### Check Video State

The injection script returns diagnostic info:

```javascript
return {
    success: true,
    videoWidth: video.videoWidth,
    videoHeight: video.videoHeight,
    volume: video.volume
};
```

### Logs

Video-related logs use `DiagnosticsLogger.player`:
- `"updateDisplayMode called with mode: ..."` — Mode changes
- `"Video extracted, volume set to: ..."` — Successful extraction
- `"Video restored to original location"` — Cleanup completed

## Future Improvements

- [ ] Picture-in-Picture API integration (native macOS PiP)
- [ ] Keyboard shortcuts for video controls
- [ ] Fullscreen video mode
- [ ] Remember window size (not just corner)
