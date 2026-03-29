# Playback System

This document details the WebView-based playback system, its architecture, and implementation notes.

## Overview

YouTube Music uses DRM (Widevine) to protect Premium content. Native playback via AVPlayer is not possible because:

1. **Bot Detection**: YouTube's APIs detect non-browser clients and block them
2. **DRM**: Premium content requires Widevine CDM, only available in WebKit
3. **User Interaction**: YouTube requires a user gesture to start playback

Our solution: A **singleton WebView** that loads YouTube Music watch pages and plays audio through WebKit's native DRM support.

## Architecture

### Components

| Component | File | Purpose |
|-----------|------|---------|
| `SingletonPlayerWebView` | `MiniPlayerWebView.swift` | Manages the one-and-only WebView |
| `PersistentPlayerView` | `MiniPlayerWebView.swift` | SwiftUI wrapper for the WebView |
| `PlayerService` | `PlayerService.swift` | Playback state and control |
| `PlayerService+WebQueueSync` | `PlayerService+WebQueueSync.swift` | Keeps native queue state authoritative when WebView events drift |
| `AppDelegate` | `AppDelegate.swift` | Window lifecycle for background audio |

### Singleton Pattern

```swift
@MainActor
final class SingletonPlayerWebView {
    static let shared = SingletonPlayerWebView()

    private(set) var webView: WKWebView?
    var currentVideoId: String?

    func getWebView(webKitManager:, playerService:) -> WKWebView
    func loadVideo(videoId: String)
}
```

**Why Singleton?**
- Prevents multiple audio streams
- Survives SwiftUI view recreation
- Survives window close/reopen
- Single source of truth for playback

## Playback Flow

### 1. User Initiates Play

```swift
// In a view
playerService.play(videoId: "dQw4w9WgXcQ")
```

This sets:
- `pendingPlayVideoId` = video ID
- `showMiniPlayer` = `true` (shows toast for user interaction)

### 2. WebView Loads

`MainWindow` observes `pendingPlayVideoId`:

```swift
if let videoId = playerService.pendingPlayVideoId {
    PersistentPlayerView(videoId: videoId, isExpanded: playerService.showMiniPlayer)
        .frame(width: showMiniPlayer ? 160 : 1, height: showMiniPlayer ? 90 : 1)
}
```

### 3. Video Starts

`PersistentPlayerView` either:
- Creates new WebView (first play)
- Reuses existing WebView (subsequent plays)

```swift
func makeNSView(context: Context) -> NSView {
    let webView = SingletonPlayerWebView.shared.getWebView(...)

    // Load if different video
    if SingletonPlayerWebView.shared.currentVideoId != videoId {
        webView.load(URLRequest(url: watchURL))
    }

    return container
}
```

### 4. State Updates

The observer script continuously reports:
- Playback state (`isPlaying`, `progress`, `duration`)
- Track metadata (`title`, `artist`, `thumbnailUrl`)
- The observed `videoId`
- Whether the observer thinks the track changed
- Like status and lightweight video availability

Swift updates `PlayerService` from every `STATE_UPDATE`, then uses
`PlayerService+WebQueueSync` to decide whether the reported track matches
Kaset's queue or whether YouTube autoplay needs to be corrected.

### 5. Track-End Handling

Natural track completion is handled by a dedicated bridge event:

```javascript
bridge.postMessage({
    type: 'TRACK_ENDED',
    videoId: lastVideoId || currentVideoId()
});
```

Swift validates that the ended `videoId` still matches the expected queue song
before advancing. This prevents stale `ended` events from double-advancing the
queue after Kaset has already loaded the next track.

## Track Changing

When user plays a different track:

1. `pendingPlayVideoId` changes
2. SwiftUI calls `updateNSView` (not `makeNSView`)
3. `SingletonPlayerWebView.loadVideo(videoId:)` called
4. Current audio paused, target volume prepared, new URL loaded

```swift
func loadVideo(videoId: String) {
    guard videoId != currentVideoId else { return }

    // Update ID immediately to prevent duplicate loads
    currentVideoId = videoId

    // Pause current, set the target volume, then load new
    webView.evaluateJavaScript("document.querySelector('video')?.pause()") { _, _ in
        webView.evaluateJavaScript("window.__kasetTargetVolume = currentVolume")
        self.webView?.load(URLRequest(url: watchURL))
    }
}
```

When the WebView reports a new `videoId`, Kaset treats that as authoritative
even if the DOM title/artist are still stale. This avoids a race where YouTube
switches tracks before the player bar text catches up.

## Background Audio

### Window Close Behavior

By default, closing a window destroys its view hierarchy, killing the WebView. We prevent this:

```swift
// AppDelegate.swift
extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)  // Hide instead of close
        return false          // Don't actually close
    }
}
```

### App Lifecycle

```swift
func applicationShouldTerminateAfterLastWindowClosed(_:) -> Bool {
    return false  // Keep app running when window hidden
}
```

### Reopening Window

```swift
func applicationShouldHandleReopen(_:, hasVisibleWindows:) -> Bool {
    if !hasVisibleWindows {
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return true
        }
    }
    return true
}
```

### Flow Summary

| Action | Result |
|--------|--------|
| Close window (⌘W) | Window hides, audio continues |
| Click dock icon | Window reappears, same audio |
| Quit app (⌘Q) | App terminates, audio stops |

## JavaScript Bridge

### Observer Script

Injected into every watch page. The real script is more defensive than the
minimal version below:

```javascript
(function() {
    'use strict';
    const bridge = window.webkit.messageHandlers.singletonPlayer;
    let lastTitle = '';
    let lastArtist = '';
    let lastVideoId = '';

    function currentVideoId() {
        const player = document.querySelector('ytmusic-player');
        const data = player?.playerApi?.getVideoData?.();
        return data?.video_id || data?.videoId || '';
    }

    function sendTrackEnded() {
        bridge.postMessage({
            type: 'TRACK_ENDED',
            videoId: lastVideoId || currentVideoId()
        });
    }

    function sendUpdate() {
        const video = document.querySelector('video');
        const progressBar = document.querySelector('#progress-bar');
        const title = /* DOM title, or player API title if DOM is stale */;
        const artist = /* DOM artist, or player API artist if DOM is stale */;
        const videoId = currentVideoId();
        const trackChanged =
            (title !== '' && (title !== lastTitle || artist !== lastArtist))
            || (videoId !== '' && videoId !== lastVideoId);

        if (trackChanged) {
            if (title !== '') {
                lastTitle = title;
                lastArtist = artist;
            }
            if (videoId !== '') {
                lastVideoId = videoId;
            }
        }

        bridge.postMessage({
            type: 'STATE_UPDATE',
            isPlaying: video ? !video.paused : false,
            progress: parseInt(progressBar?.getAttribute('value') || '0'),
            duration: parseInt(progressBar?.getAttribute('aria-valuemax') || '0'),
            title: title,
            artist: artist,
            videoId: videoId,
            trackChanged: trackChanged
        });
    }
})();
```

### Message Handler

```swift
func userContentController(_:, didReceive message: WKScriptMessage) {
    guard let body = message.body as? [String: Any],
          let type = body["type"] as? String
    else { return }

    Task { @MainActor in
        if type == "TRACK_ENDED" {
            await playerService.handleTrackEnded(
                observedVideoId: body["videoId"] as? String
            )
            return
        }

        playerService.updatePlaybackState(...)
        playerService.updateTrackMetadata(...)
    }
}
```

### Queue Authority

Kaset treats its own queue as the source of truth whenever one exists:
- `handleTrackEnded(observedVideoId:)` advances the native queue immediately
- `updateTrackMetadata(...)` accepts `videoId`-only transitions even if the DOM
  metadata is temporarily blank or stale
- If YouTube advances to an unexpected track near the end of a song, Kaset
  replays the expected queue track instead of inheriting YouTube autoplay
- At the end of a non-repeating queue, Kaset marks playback ended rather than
  allowing autoplay to continue into unrelated tracks

## Mini Player UI

A small toast in the bottom-right corner:

| State | Size | Purpose |
|-------|------|---------|
| Visible | 160×90 | User clicks to interact |
| Hidden | 1×1 | WebView stays in hierarchy |

```swift
.frame(
    width: playerService.showMiniPlayer ? 160 : 1,
    height: playerService.showMiniPlayer ? 90 : 1
)
```

### Auto-Dismiss

When playback starts, the mini player auto-dismisses:

```swift
// In Coordinator
if isPlaying && playerService.showMiniPlayer {
    playerService.confirmPlaybackStarted()
}
```

## Common Issues

### Multiple Audio Streams

**Cause**: Multiple WebViews created

**Solution**: Singleton pattern ensures one WebView

### Audio Stops on Window Close

**Cause**: WebView destroyed with view hierarchy

**Solution**: `windowShouldClose` returns `false`, hides instead

### Track Not Changing

**Cause**: `updateNSView` not called

**Solution**: Pass `videoId` as parameter to trigger SwiftUI updates

### No Playback

**Cause**: User interaction required by YouTube

**Solution**: Mini player toast allows user to click play

## User Agent

We use Safari's user agent to avoid "browser not optimized" warnings:

```swift
static let userAgent = """
    Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) \
    AppleWebKit/605.1.15 (KHTML, like Gecko) \
    Version/17.0 Safari/605.1.15
    """
```

## Debugging

Enable WebView inspector in Debug builds:

```swift
#if DEBUG
    webView.isInspectable = true
#endif
```

Right-click the mini player → "Inspect Element" to debug JavaScript.

## Infinite Mix

When playing artist mixes (`RDEM...` playlists), the app supports infinite queue loading:

### How It Works

1. **Initial Load**: `playWithMix()` fetches ~50 songs via the `next` endpoint
2. **Continuation Token**: The API returns a `nextRadioContinuationData.continuation` token
3. **Auto-Fetch**: When ≤10 songs remain in queue, `fetchMoreMixSongsIfNeeded()` loads more
4. **Duplicate Filter**: New songs are filtered to prevent duplicates
5. **Repeat**: Process continues until no more continuation tokens

### Key Components

| Component | Purpose |
|-----------|----------|
| `RadioQueueResult` | Holds songs + continuation token |
| `mixContinuationToken` | Stored in `PlayerService` |
| `isFetchingMoreMixSongs` | Prevents concurrent fetches |
| `fetchMoreMixSongsIfNeeded()` | Triggered on `next()` and `playFromQueue()` |

### State Reset

The continuation token is cleared when:
- Playing a regular queue (`playQueue`)
- Playing song radio (`playWithRadio`)
- Clearing the queue (`clearQueue`)

This prevents infinite fetch from triggering on non-mix playback.

## Video Mode

For floating video window functionality, see [docs/video.md](video.md).

## Future Improvements

- [x] Queue management (next/previous)
- [x] Infinite mix loading
- [x] Video mode (floating video window)
- [x] Seek support via JavaScript
- [x] Volume control
- [x] Now Playing in Control Center (via WKWebView media session + remote commands)
