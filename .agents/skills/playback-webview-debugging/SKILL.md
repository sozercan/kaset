---
name: playback-webview-debugging
description: Use when playback, auth recovery, queue sync, or hidden WebView state diverges from native Swift state and you need to debug the DRM playback WebView, bridge events, or cookie/auth behavior.
metadata:
  short-description: Debug playback WebView state
---

# Playback WebView Debugging

Typical symptoms: playback starts, stops, or advances unexpectedly; API calls return 401/403 because auth looks stale; WebView metadata drifts from the native queue; or you need to see JavaScript bridge events or DOM/player state.

## Runtime Workflow

1. Reproduce with the packaged app or `Scripts/compile_and_run.sh` (see the `dev-loop-packaging` skill).
2. Watch runtime logs in the Xcode Console with the filters `subsystem:Kaset category:player` and `subsystem:Kaset category:auth`. `.info`/`.debug` lines don't reliably surface from the sandbox, so for timing or ordering questions use a file trace as described under Debugging & Measurement in `AGENTS.md`.
3. In debug builds, confirm `webView.isInspectable = true`, then inspect the player WebView with Safari Web Inspector.
4. To simulate auth expiry, delete `__Secure-3PAPISID` with Safari Web Inspector's storage tools and trigger an authenticated API call.
5. If auth cookies or headers look wrong, run `swift run api-explorer auth` and compare against the exported cookie state.

## Landmarks

- `docs/testing.md`
- `docs/playback.md`
- `Sources/Kaset/Views/MiniPlayerWebView.swift`
- `Sources/Kaset/Views/SingletonPlayerWebView+ObserverScript.swift`
- `Sources/Kaset/Views/SingletonPlayerWebView+NavigationState.swift`
- `Sources/Kaset/Views/SingletonPlayerWebView+QueueInjection.swift`
- `Sources/Kaset/Services/Player/PlayerService.swift`
- `Sources/Kaset/Services/Player/PlayerService+WebPlaybackIdentity.swift`
- `Sources/Kaset/Services/Player/PlayerService+WebQueueSync.swift`
- `Sources/Kaset/Services/Player/PlayerService+QueueNavigationRecovery.swift`
- `Sources/Kaset/Services/WebKit/WebKitManager.swift`
