# ADR-0001: WebView-Based Playback

## Status

Accepted

## Context

Kaset needs to play YouTube Music content, including Premium tracks with DRM protection. There are several approaches to consider:

1. **Direct audio streaming** - Download and play audio files directly
2. **AVPlayer with HLS** - Use Apple's native player with streaming URLs
3. **Hidden WebView** - Load YouTube Music in a WebView and control playback via JavaScript

Direct streaming and AVPlayer approaches cannot handle DRM-protected content. YouTube Music Premium content uses Widevine DRM which requires a browser environment.

## Decision

Use a hidden `WKWebView` (SingletonPlayerWebView) to load YouTube Music's web player at `music.youtube.com/watch?v={videoId}`. Control playback via JavaScript injection and receive state updates through a JavaScript-to-Swift bridge.

Key implementation details:
- Single WebView instance shared across the app (singleton pattern)
- WebView shares cookies with the login WebView for authentication
- JavaScript bridge sends playback state (isPlaying, progress, duration) to Swift
- Native controls (PlayerBar, Now Playing) reflect WebView state
- Background audio continues when window is hidden

## Consequences

### Positive
- **DRM support** - Premium content plays correctly with user's subscription
- **No reverse engineering** - Uses official web interface
- **Feature parity** - Any content playable on web works in Kaset
- **Authentication reuse** - Same cookies as browser login

### Negative
- **Resource usage** - WebView consumes more memory than native audio
- **Latency** - Small delay for JavaScript bridge communication
- **Complexity** - JavaScript injection requires careful error handling
- **Testing difficulty** - WebView behavior harder to unit test

### Mitigations
- Singleton WebView prevents multiple instances
- Debounced state updates reduce bridge traffic
- Dedicated `PlayerWebView` abstraction isolates WebView concerns
