# Video Support Implementation Plan

> **Status**: Planning  
> **Created**: January 3, 2026  
> **Target**: macOS 26+ (Tahoe) with Liquid Glass

## Overview

Add native video playback support for songs (music videos) and podcasts (video podcasts) using a floating Picture-in-Picture style window with Liquid Glass design.

## Design Decisions

| Question | Choice |
|----------|--------|
| Content priority | **C** - Both songs and podcasts |
| Default mode | **B** - Audio-only default, user enables video |
| Window behavior | **C** - Persist if new track has video, close otherwise |
| UI pattern | **B** - Floating PiP window |
| Subtitles | **C** - Only if trivial (YouTube handles natively) |
| Toggle location | **A** - In PlayerBar |
| Video indicator | **C** - Badge on thumbnails + conditional button |
| Window sizing | **A2** - Freely resizable with 16:9 aspect lock |
| Position memory | **B3** - Snaps to corners like macOS native PiP |
| Space behavior | **C1** - Independent, works across Spaces |
| Button when no video | **D1** - Hidden completely |
| Keyboard shortcut | **E2** - ⌘⇧V |
| Video quality | **F4** - Defer to later phase |

---

## Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         MainWindow                               │
│  ┌─────────────┐  ┌─────────────────────────────────────────┐   │
│  │   Sidebar   │  │              Content Area               │   │
│  │             │  │                                         │   │
│  │             │  │   ┌─────────────────────────────────┐   │   │
│  │             │  │   │     NavigationStack views       │   │   │
│  │             │  │   │                                 │   │   │
│  │             │  │   └─────────────────────────────────┘   │   │
│  │             │  │                                         │   │
│  │             │  │   ┌─────────────────────────────────┐   │   │
│  │             │  │   │         PlayerBar               │   │   │
│  │             │  │   │   [🎬 Video button - NEW]       │   │   │
│  │             │  │   └─────────────────────────────────┘   │   │
│  └─────────────┘  └─────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│         VideoPlayerWindow (PiP)         │  ← Separate NSWindow
│  ┌───────────────────────────────────┐  │     Floats above all
│  │                                   │  │     Works across Spaces
│  │         WKWebView                 │  │
│  │      (video content)              │  │
│  │                                   │  │
│  ├───────────────────────────────────┤  │
│  │   advancement advancement  advancement │  │  ← Controls on hover
│  │     [⏮] [⏯] [⏭]  [✕]           │  │
│  └───────────────────────────────────┘  │
└─────────────────────────────────────────┘
```

### Data Flow

```
User taps Video button in PlayerBar
    │
    ▼
PlayerService.showVideo = true
    │
    ▼
VideoPlayerWindow created/shown
    │
    ▼
SingletonPlayerWebView reparented to VideoPlayerWindow
    │
    ├─ WebView resized to show video (not 1x1)
    │
    ▼
Video plays in floating window
    │
    │ Track changes...
    ▼
Check: new track has video?
    │
    ├─ Yes → Keep window, load new video
    │
    └─ No → Close window, return WebView to hidden container
```

---

## Phases

### Phase 1: Video Availability Detection

**Goal**: Detect which tracks have video available and expose via models.

#### 1.1 Model Updates

**File**: `Core/Models/Song.swift`

```swift
// Add to Song struct
/// Whether this track has a music video available.
var hasVideo: Bool?
```

**File**: `Core/Models/Podcast.swift`

```swift
// Add to PodcastEpisode struct  
/// Whether this episode has video available.
var hasVideo: Bool?
```

#### 1.2 JavaScript Bridge Enhancement

**File**: `Views/macOS/MiniPlayerWebView.swift`

Add video detection to the observer script:

```javascript
// In sendUpdate()
const video = document.querySelector('video');
const hasVideo = video ? (video.videoWidth > 1 && video.videoHeight > 1) : false;

bridge.postMessage({
    // ... existing fields
    hasVideo: hasVideo
});
```

#### 1.3 PlayerService State

**File**: `Core/Services/Player/PlayerService.swift`

```swift
/// Whether the current track has video available.
private(set) var currentTrackHasVideo: Bool = false

/// Whether video mode is active (user has opened video window).
var showVideo: Bool = false {
    didSet {
        // Auto-close if track changes to audio-only
        if showVideo && !currentTrackHasVideo {
            showVideo = false
        }
    }
}
```

#### 1.4 Exit Criteria

- [ ] `Song.hasVideo` and `PodcastEpisode.hasVideo` properties exist
- [ ] JS bridge sends `hasVideo` in STATE_UPDATE
- [ ] `PlayerService.currentTrackHasVideo` updates correctly
- [ ] Build succeeds: `xcodebuild -scheme Kaset build`
- [ ] Unit tests pass

---

### Phase 2: PlayerBar Video Button

**Goal**: Add video toggle button to PlayerBar, hidden when no video available.

#### 2.1 Button Implementation

**File**: `Views/macOS/PlayerBar.swift`

Add to `actionButtons` view (between Queue and volume divider):

```swift
// Video button - only shown when video available
if playerService.currentTrackHasVideo {
    Button {
        HapticService.toggle()
        withAnimation(AppAnimation.standard) {
            player.showVideo.toggle()
        }
    } label: {
        Image(systemName: playerService.showVideo ? "tv.fill" : "tv")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(playerService.showVideo ? .red : .primary.opacity(0.85))
    }
    .buttonStyle(.pressable)
    .keyboardShortcut("v", modifiers: [.command, .shift])
    .accessibilityLabel("Video")
    .accessibilityValue(playerService.showVideo ? "Playing" : "Off")
}
```

#### 2.2 Exit Criteria

- [ ] Video button appears in PlayerBar when `currentTrackHasVideo == true`
- [ ] Button hidden when no video available
- [ ] ⌘⇧V keyboard shortcut works
- [ ] Button toggles `playerService.showVideo`
- [ ] Build succeeds

---

### Phase 3: Video PiP Window

**Goal**: Create floating video window with Liquid Glass styling.

#### 3.1 New File: VideoPlayerWindow

**File**: `Views/macOS/VideoPlayerWindow.swift`

```swift
import SwiftUI
import WebKit

/// Floating Picture-in-Picture style window for video playback.
@available(macOS 26.0, *)
struct VideoPlayerWindow: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(WebKitManager.self) private var webKitManager
    
    @State private var isHovering = false
    
    var body: some View {
        ZStack {
            // Video content (WebView container)
            VideoWebViewContainer()
            
            // Controls overlay (shown on hover)
            if isHovering {
                VideoControlsOverlay()
                    .transition(.opacity)
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .frame(minWidth: 320, minHeight: 180)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

/// NSViewRepresentable container for the video WebView.
struct VideoWebViewContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        // WebView will be reparented here by SingletonPlayerWebView
        return container
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        SingletonPlayerWebView.shared.ensureInHierarchy(container: nsView)
    }
}

/// Minimal playback controls overlay for the video window.
@available(macOS 26.0, *)
struct VideoControlsOverlay: View {
    @Environment(PlayerService.self) private var playerService
    
    var body: some View {
        VStack {
            Spacer()
            
            HStack(spacing: 24) {
                // Previous
                Button {
                    Task { await playerService.previous() }
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                
                // Play/Pause
                Button {
                    Task { await playerService.playPause() }
                } label: {
                    Image(systemName: playerService.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                
                // Next
                Button {
                    Task { await playerService.next() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                // Close video
                Button {
                    playerService.showVideo = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
            .padding()
        }
    }
}
```

#### 3.2 Window Management

**File**: `App/VideoWindowController.swift` (NEW)

```swift
import AppKit
import SwiftUI

/// Manages the floating video PiP window.
@MainActor
final class VideoWindowController {
    static let shared = VideoWindowController()
    
    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    
    // Corner snapping
    enum Corner: Int {
        case topLeft, topRight, bottomLeft, bottomRight
    }
    private var currentCorner: Corner = .bottomRight
    
    private init() {}
    
    /// Shows the video window.
    func show(
        playerService: PlayerService,
        webKitManager: WebKitManager
    ) {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        
        let contentView = VideoPlayerWindow()
            .environment(playerService)
            .environment(webKitManager)
        
        let hostingView = NSHostingView(rootView: AnyView(contentView))
        self.hostingView = hostingView
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 270),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.title = "Video"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.aspectRatio = NSSize(width: 16, height: 9)
        window.minSize = NSSize(width: 320, height: 180)
        
        // Position at saved corner
        positionAtCorner(window: window, corner: currentCorner)
        
        window.makeKeyAndOrderFront(nil)
        self.window = window
        
        // Observe window close
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }
    
    /// Closes the video window.
    func close() {
        window?.close()
        window = nil
        hostingView = nil
    }
    
    @objc private func windowWillClose(_ notification: Notification) {
        // Update corner based on final position
        if let window = notification.object as? NSWindow {
            currentCorner = nearestCorner(for: window)
            saveCorner()
        }
        window = nil
        hostingView = nil
        
        // Notify PlayerService
        Task { @MainActor in
            // PlayerService.shared.showVideo = false
        }
    }
    
    private func positionAtCorner(window: NSWindow, corner: Corner) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        let padding: CGFloat = 20
        
        var origin: NSPoint
        switch corner {
        case .topLeft:
            origin = NSPoint(
                x: screenFrame.minX + padding,
                y: screenFrame.maxY - windowSize.height - padding
            )
        case .topRight:
            origin = NSPoint(
                x: screenFrame.maxX - windowSize.width - padding,
                y: screenFrame.maxY - windowSize.height - padding
            )
        case .bottomLeft:
            origin = NSPoint(
                x: screenFrame.minX + padding,
                y: screenFrame.minY + padding
            )
        case .bottomRight:
            origin = NSPoint(
                x: screenFrame.maxX - windowSize.width - padding,
                y: screenFrame.minY + padding
            )
        }
        
        window.setFrameOrigin(origin)
    }
    
    private func nearestCorner(for window: NSWindow) -> Corner {
        guard let screen = NSScreen.main else { return .bottomRight }
        let screenFrame = screen.visibleFrame
        let windowCenter = NSPoint(
            x: window.frame.midX,
            y: window.frame.midY
        )
        let screenCenter = NSPoint(
            x: screenFrame.midX,
            y: screenFrame.midY
        )
        
        let isLeft = windowCenter.x < screenCenter.x
        let isTop = windowCenter.y > screenCenter.y
        
        switch (isLeft, isTop) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
    
    private func saveCorner() {
        UserDefaults.standard.set(currentCorner.rawValue, forKey: "videoWindowCorner")
    }
    
    private func loadCorner() {
        let raw = UserDefaults.standard.integer(forKey: "videoWindowCorner")
        currentCorner = Corner(rawValue: raw) ?? .bottomRight
    }
}
```

#### 3.3 MainWindow Integration

**File**: `Views/macOS/MainWindow.swift`

Add observer to show/hide video window:

```swift
.onChange(of: playerService.showVideo) { _, showVideo in
    if showVideo {
        VideoWindowController.shared.show(
            playerService: playerService,
            webKitManager: webKitManager
        )
    } else {
        VideoWindowController.shared.close()
    }
}
```

#### 3.4 Exit Criteria

- [ ] Video window appears when `showVideo` becomes true
- [ ] Window is floating (stays above other windows)
- [ ] Window works across Spaces
- [ ] 16:9 aspect ratio maintained during resize
- [ ] Window snaps to nearest corner on close
- [ ] Controls appear on hover
- [ ] Close button returns to audio-only mode
- [ ] Build succeeds

---

### Phase 4: WebView Reparenting

**Goal**: Move WebView between hidden container and video window.

#### 4.1 SingletonPlayerWebView Updates

**File**: `Views/macOS/MiniPlayerWebView.swift`

```swift
/// Current display mode for the WebView.
enum DisplayMode {
    case hidden      // 1x1 for audio-only
    case miniPlayer  // 160x90 toast
    case video       // Full size in video window
}

var displayMode: DisplayMode = .hidden

/// Updates WebView size based on display mode.
func updateDisplayMode(_ mode: DisplayMode) {
    guard let webView else { return }
    displayMode = mode
    
    switch mode {
    case .hidden:
        // WebView stays in hierarchy but tiny
        webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    case .miniPlayer:
        webView.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
    case .video:
        // Full size - parent container determines size
        webView.frame = webView.superview?.bounds ?? .zero
        webView.autoresizingMask = [.width, .height]
    }
}
```

#### 4.2 Exit Criteria

- [ ] WebView reparents cleanly between containers
- [ ] Audio continues during reparenting
- [ ] Video displays at correct size in video window
- [ ] Returning to audio-only shrinks WebView back to 1x1

---

### Phase 5: Video Badge on Thumbnails

**Goal**: Show video indicator badge on tracks that have music videos.

#### 5.1 Badge Component

**File**: `Views/macOS/SharedViews/VideoBadge.swift` (NEW)

```swift
import SwiftUI

/// Small video indicator badge for thumbnails.
@available(macOS 26.0, *)
struct VideoBadge: View {
    var body: some View {
        Image(systemName: "video.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(3)
            .background(.black.opacity(0.6), in: .circle)
    }
}
```

#### 5.2 Apply to Thumbnails

Update thumbnail views to overlay badge when `hasVideo == true`:

- `SongRow` / `SongCard` components
- Playlist detail track rows
- Search result items

```swift
// Example usage
AsyncImage(url: song.thumbnailURL) { ... }
    .overlay(alignment: .bottomTrailing) {
        if song.hasVideo == true {
            VideoBadge()
                .padding(4)
        }
    }
```

#### 5.3 Exit Criteria

- [ ] Badge appears on thumbnails for tracks with video
- [ ] Badge styling matches Liquid Glass aesthetic
- [ ] Badge doesn't obscure important thumbnail content

---

### Phase 6: Track Change Behavior

**Goal**: Handle video window when track changes.

#### 6.1 PlayerService Logic

**File**: `Core/Services/Player/PlayerService.swift`

```swift
/// Called when track metadata updates from WebView.
func updateTrackMetadata(...) {
    // ... existing code ...
    
    // Update video availability
    let hadVideo = currentTrackHasVideo
    currentTrackHasVideo = newHasVideo
    
    // Auto-close video window if new track has no video
    if showVideo && !currentTrackHasVideo {
        showVideo = false
    }
}
```

#### 6.2 Exit Criteria

- [ ] Video window stays open when changing to another video track
- [ ] Video window closes when changing to audio-only track
- [ ] Transition is smooth (no flicker)

---

### Phase 7: Polish & Testing

**Goal**: Final polish, edge cases, and tests.

#### 7.1 Edge Cases

- [ ] Video window behavior when app goes to background
- [ ] Video window behavior on display change (external monitor)
- [ ] Memory management (WebView not duplicated)
- [ ] Full-screen video support (green button)

#### 7.2 Accessibility

- [ ] Video window has proper accessibility labels
- [ ] VoiceOver announces video availability
- [ ] Reduced Motion respected for transitions

#### 7.3 Tests

**File**: `Tests/KasetTests/VideoSupportTests.swift` (NEW)

```swift
import Testing
@testable import Kaset

@Suite("Video Support")
struct VideoSupportTests {
    
    @Test("hasVideo property updates from metadata")
    func hasVideoUpdates() async {
        // Test that PlayerService.currentTrackHasVideo updates correctly
    }
    
    @Test("showVideo closes when track has no video")
    func autoCloseOnAudioOnlyTrack() async {
        // Test auto-close behavior
    }
    
    @Test("Video button hidden when no video available")
    func videoButtonVisibility() async {
        // Test button appears/disappears correctly
    }
}
```

#### 7.4 Exit Criteria

- [ ] All edge cases handled
- [ ] Accessibility audit passed
- [ ] Unit tests written and passing
- [ ] Manual QA on music videos and video podcasts
- [ ] `swiftlint --strict && swiftformat .` passes
- [ ] Full test suite passes

---

## Files to Create/Modify

### New Files

| File | Purpose |
|------|---------|
| `Views/macOS/VideoPlayerWindow.swift` | PiP video window view |
| `App/VideoWindowController.swift` | Window management |
| `Views/macOS/SharedViews/VideoBadge.swift` | Thumbnail badge |
| `Tests/KasetTests/VideoSupportTests.swift` | Unit tests |

### Modified Files

| File | Changes |
|------|---------|
| `Core/Models/Song.swift` | Add `hasVideo` property |
| `Core/Models/Podcast.swift` | Add `hasVideo` to `PodcastEpisode` |
| `Core/Services/Player/PlayerService.swift` | Add `showVideo`, `currentTrackHasVideo` |
| `Views/macOS/PlayerBar.swift` | Add video toggle button |
| `Views/macOS/MiniPlayerWebView.swift` | Add video detection, display modes |
| `Views/macOS/MainWindow.swift` | Video window observer |
| `Core/Utilities/AccessibilityIdentifiers.swift` | Add video button ID |

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| WebView reparenting breaks audio | Medium | High | Test thoroughly, add fallback |
| PiP conflicts with system PiP | Low | Medium | Use different window level |
| Video detection unreliable | Medium | Medium | Add retry logic, timeout |
| Performance impact | Low | Medium | Profile, optimize if needed |

---

## Success Metrics

1. **Functional**: Users can watch music videos and video podcasts
2. **Reliable**: Video window doesn't crash or break audio
3. **Native**: Feels like a macOS Tahoe app (Liquid Glass, PiP behavior)
4. **Discoverable**: Users know when video is available

---

## Future Enhancements (Out of Scope)

- Video quality settings
- Fullscreen video mode
- AirPlay video to Apple TV
- Custom subtitle styling
- Video download for offline
- Mini video in PlayerBar expansion (Option A from brainstorm)
