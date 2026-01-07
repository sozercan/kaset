# Video Mode

This document details the floating video window feature.

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

1. **Inject Blackout CSS**: Immediately covers the page with a black overlay to prevent UI flash
2. **Click Video Tab**: Attempts to click YouTube Music's "Video" toggle (if available)
3. **Create Container**: Creates `#kaset-video-container` with `position: fixed`
4. **Move Video**: Moves `<video>` element into the container
5. **Disable Controls**: Sets `video.controls = false` (users control via app's player bar)
6. **Block Click Events**: Prevents clicks from reaching YouTube's underlying handlers
7. **Apply Volume**: Syncs video volume with app's volume setting
8. **Remove Blackout**: Shows the extracted video

### CSS Strategy

```javascript
container.style.cssText = `
    position: fixed !important;
    top: 0 !important;
    left: 0 !important;
    width: ${containerWidth}px !important;
    height: ${containerHeight}px !important;
    z-index: 2147483647 !important;
`;
```

The container uses explicit pixel values (not viewport units) because WKWebView viewport units don't update reliably on resize. `refreshVideoModeCSS()` is called on resize to update dimensions.

## Resize Handling

On window resize:
1. `refreshVideoModeCSS()` is called
2. Updates container and video element to new pixel dimensions
3. No re-extraction of the video element is performed

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
- Video window closes automatically (after a 3-second grace period for initial load)
- User can reopen for the new track
- This prevents showing wrong video for the audio

The grace period prevents the video from closing during the initial `trackChanged` events that fire when the video is first loaded.

## Known Issues & Solutions

### Issue: Video Turns Off on Resize (FIXED)

**Root Cause**: The `hasVideo` detection in the JavaScript observer became unreliable when video mode was active. When the video element was extracted from the DOM or the Song/Video toggle buttons were hidden by our CSS, the observer would report `hasVideo=false`. The `updateVideoAvailability` function would then auto-close the video window.

**Solution**: Removed the auto-close behavior from `updateVideoAvailability`. The video window now only closes when:
1. User explicitly closes it (red X button)
2. Track changes (handled by `trackChanged` in the Coordinator)
3. User toggles `showVideo` off

The `hasVideo` property is still updated and used to enable/disable the Video button in the UI, but it no longer affects an already-open video window.

### Issue: Volume Jump When Opening Video (FIXED)

**Root Cause**: YouTube's internal player APIs and the HTML5 video element have separate volume states. Moving the video element or clicking the Video tab could cause YouTube to reset volume.

**Solution**: Volume enforcement via multiple mechanisms:
1. `window.__kasetTargetVolume` stores the app's target volume
2. `volumechange` event listener enforces the target volume (with debouncing)
3. Volume is applied via three APIs: `video.volume`, `playerApi.setVolume()`, and `movie_player.setVolume()`
4. Click events on the video container are blocked to prevent YouTube's handlers from changing volume
5. Volume is reapplied after video extraction completes

### Issue: UI Flash When Opening Video (FIXED)

**Root Cause**: When entering video mode, YouTube's web UI was briefly visible before video extraction completed.

**Solution**: Inject a blackout overlay (`#kaset-blackout`) immediately when entering video mode. This black `<div>` covers the entire viewport until video extraction is complete.

### Issue: Volume Wrong on Song Start (FIXED)

**Root Cause**: The WKUserScript for volume initialization was created at WebView creation time, capturing a stale volume value. When pages reloaded for new songs, this stale script ran.

**Solution**: 
1. Removed static volume init script from WebView configuration
2. `didFinish` navigation delegate applies current volume dynamically
3. Observer script applies `__kasetTargetVolume` when video element is first detected

### Issue: Video Availability

**Root Cause**: Not all songs have music videos available.

**Solution**: `PlayerService.currentTrackHasVideo` tracks video availability using a hybrid detection approach. The Video button is only enabled when a video exists.

## Video Detection

Video availability is detected using a **hybrid approach** with two sources:

### 1. API-Based Detection (Authoritative)

When `fetchSongMetadata` is called, the parser extracts `musicVideoType` from the YouTube Music API response:

```swift
// Response path (next endpoint):
navigationEndpoint.watchEndpoint.watchEndpointMusicSupportedConfigs
    .watchEndpointMusicConfig.musicVideoType
```

The `MusicVideoType` enum classifies content:

| Value | Enum Case | Has Video |
|-------|-----------|-----------|
| `MUSIC_VIDEO_TYPE_OMV` | `.omv` | ✅ Yes |
| `MUSIC_VIDEO_TYPE_ATV` | `.atv` | ❌ No (audio track video) |
| `MUSIC_VIDEO_TYPE_UGC` | `.ugc` | ❌ No (user-generated placeholder) |
| `MUSIC_VIDEO_TYPE_PODCAST_EPISODE` | `.podcastEpisode` | ❌ No |

Only Official Music Videos (OMV) have actual video content. ATV tracks show a static album art "video."

**Files**:
- [Core/Models/MusicVideoType.swift](../Core/Models/MusicVideoType.swift) — Enum definition with `hasVideoContent` property
- [Core/Services/API/Parsers/SongMetadataParser.swift](../Core/Services/API/Parsers/SongMetadataParser.swift) — `parseMusicVideoType(from:)` method
- [Core/Services/Player/PlayerService+Library.swift](../Core/Services/Player/PlayerService+Library.swift) — Calls `updateVideoAvailability(hasVideo:)` after parsing

### 2. DOM-Based Detection (Fast Fallback)

The JavaScript observer in the WebView provides immediate feedback before the API call completes:

```javascript
// Detects Song/Video toggle button
const toggleButton = document.querySelector('#tab-renderer tp-yt-paper-tab:nth-child(2)');
const hasVideo = toggleButton != null;
```

This is a **fallback** mechanism because:
- DOM detection fires immediately when the WebView loads the page
- API detection requires a network round-trip to the `next` endpoint
- DOM detection can be unreliable when video mode CSS is injected

**File**: [Views/macOS/SingletonPlayerWebView+ObserverScript.swift](../Views/macOS/SingletonPlayerWebView+ObserverScript.swift)

### Detection Flow

```
Track starts playing
    ├── DOM observer fires immediately
    │   └── PlayerService.updateVideoAvailability() called (fast, may be inaccurate)
    │
    └── fetchSongMetadata() completes
        └── musicVideoType parsed
            └── PlayerService.updateVideoAvailability() called (authoritative)
```

The API-based detection overwrites any earlier DOM-based value, providing the correct authoritative result.

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
- `"Singleton WebView finished loading: ..."` — Page navigation complete
- `"Video restored to original location"` — Cleanup completed

## Future Improvements

- [ ] Picture-in-Picture API integration (native macOS PiP)
- [ ] Keyboard shortcuts for video controls
- [ ] Fullscreen video mode
- [ ] Remember window size (not just corner)
- [ ] Video quality selection (requires WebView JavaScript injection to access streamingData formats)
