# ADR-0010: Fix AirPlay for WebView-Based Playback

## Status

Implemented (with known limitations)

## Context

**Issue:** [GitHub Issue #42](https://github.com/sozercan/kaset/issues/42) - AirPlay does not work

The in-app AirPlay button shows available devices and allows selection, but audio continues playing from the Mac instead of the selected AirPlay device. System-wide AirPlay settings work correctly.

### Root Cause

**Architectural mismatch between the AirPlay UI control and the audio playback system:**

1. **Current Implementation**: Uses `AVRoutePickerView` (AVKit) which only controls routing for AVFoundation-based playback (AVPlayer, AVAudioSession)
2. **Audio Source**: App uses WKWebView to play YouTube Music (required for Widevine DRM per ADR-0001)
3. **The Disconnect**: `AVRoutePickerView` has no connection to WebKit's audio output

## Decision

Replace `AVRoutePickerView` with WebKit's native AirPlay picker triggered via JavaScript injection using `webkitShowPlaybackTargetPicker()`.

This follows the existing pattern used for play/pause, volume, seek, and other playback controls in `SingletonPlayerWebView+PlaybackControls.swift`.

## Implementation

### Files to Modify

1. **`Sources/Kaset/Views/SingletonPlayerWebView+PlaybackControls.swift`** - Add `showAirPlayPicker()` method
2. **`Sources/Kaset/Views/PlayerBar.swift`** - Replace `AVRoutePickerView` with custom button
3. **`Sources/Kaset/Services/Player/PlayerService.swift`** - Add `showAirPlayPicker()` method to call through to SingletonPlayerWebView

### Step 1: Add JavaScript injection method

**File:** `Sources/Kaset/Views/SingletonPlayerWebView+PlaybackControls.swift`

```swift
/// Show the native AirPlay picker for the WebView's video element.
func showAirPlayPicker() {
    guard let webView else { return }

    let script = """
        (function() {
            const video = document.querySelector('video');
            if (video && typeof video.webkitShowPlaybackTargetPicker === 'function') {
                video.webkitShowPlaybackTargetPicker();
                return 'picker-shown';
            }
            return 'no-video-or-unsupported';
        })();
    """
    webView.evaluateJavaScript(script) { [weak self] result, error in
        if let error {
            self?.logger.error("showAirPlayPicker error: \(error.localizedDescription)")
        } else if let result = result as? String {
            self?.logger.debug("showAirPlayPicker: \(result)")
        }
    }
}
```

### Step 2: Add PlayerService method

**File:** `Sources/Kaset/Services/Player/PlayerService.swift`

```swift
/// Show the AirPlay picker for selecting audio output devices.
func showAirPlayPicker() {
    SingletonPlayerWebView.shared.showAirPlayPicker()
}
```

Note: No `Task` wrapper needed since `PlayerService` is already `@MainActor`.

### Step 3: Replace AirPlayButton in PlayerBar

**File:** `Sources/Kaset/Views/PlayerBar.swift`

Replace the `AVRoutePickerView`-based `AirPlayButton` with:

```swift
Button {
    HapticService.toggle()
    self.playerService.showAirPlayPicker()
} label: {
    Image(systemName: "airplayaudio")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.primary.opacity(0.85))
}
.buttonStyle(.pressable)
.accessibilityIdentifier(AccessibilityID.PlayerBar.airplayButton)
.accessibilityLabel("AirPlay")
.disabled(self.playerService.currentTrack == nil)
```

Notes:
- `HapticService.toggle()` matches other PlayerBar buttons
- `self.` prefix per SwiftFormat `--self insert` rule
- Disabled when no track to avoid silent failures (requires video element)

### Step 4: Add accessibility identifier constant

**File:** Wherever `AccessibilityID.PlayerBar` is defined (likely `Sources/Kaset/Constants/AccessibilityID.swift` or similar)

```swift
static let airplayButton = "playerBar.airplayButton"
```

### Step 5: Clean up unused code

- Remove the `AirPlayButton` struct (lines 541-555)
- Remove `import AVKit` from PlayerBar.swift if no longer used

## Consequences

### Positive

- **Actually works** - AirPlay will route WebView audio to selected devices
- **Consistent pattern** - Uses same JavaScript injection approach as other playback controls
- **Native picker** - Shows WebKit's native AirPlay UI which matches system behavior

### Negative

- **Availability detection unreliable** - `webkitplaybacktargetavailabilitychanged` may not fire in WKWebView, so button visibility can't be conditional on AirPlay device availability
- **Requires active playback** - Picker needs video element to exist; button is disabled until a track is playing
- **Minor UX change** - Current `AVRoutePickerView` shows devices even without playback (though they don't work). New approach disables button until playback starts, which is more honest but slightly different behavior

## Verification

1. Build the app - ensure no compilation errors
2. Start playing a song
3. Click the AirPlay button
4. Verify native WebKit AirPlay picker appears
5. Select an AirPlay device (Sonos, HomePod, Apple TV)
6. Verify audio routes to selected device

## Known Limitations

### AirPlay Connection Lost on Track Change

**Problem:** When a track changes (skip, song ends), YouTube Music destroys and recreates the `<video>` element. This breaks the AirPlay connection because WebKit ties the AirPlay session to the specific video element instance.

**Why This Can't Be Fixed:** WebKit does not provide a programmatic API to connect to an AirPlay device. The user must manually click the AirPlay button and select a device after each track change. There is no way to automatically reconnect to the previously selected device.

### Picker Position

The AirPlay picker's position is determined by the video element's location in the viewport. Since YouTube Music hides the video element (0x0 at position 0,0), the picker appears in the top-left corner. Attempts to reposition the video element via CSS have been unsuccessful due to YouTube's CSS hierarchy. This is a cosmetic issue - the picker still functions correctly.

## References

- [Apple: Adding an AirPlay button to Safari media controls](https://developer.apple.com/documentation/webkitjs/adding_an_airplay_button_to_your_safari_media_controls)
- [Apple Developer Forums: AirPlay inside a webview](https://developer.apple.com/forums/thread/30179)
- ADR-0001: WebView-Based Playback
