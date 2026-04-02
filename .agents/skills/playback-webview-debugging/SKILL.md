# Playback WebView Debugging

Use this skill when playback, auth recovery, queue sync, or hidden WebView state diverges from the native Swift state.

## When To Use It

- Playback starts, stops, or advances unexpectedly
- Auth looks stale and API calls return 401/403
- WebView metadata drifts from the native queue
- You need to inspect JavaScript bridge events or DOM/player state

## Runtime Workflow

1. Reproduce with the packaged app or `Scripts/compile_and_run.sh`.
2. Use Xcode Console filters to watch runtime logs:
   `subsystem:Kaset category:player`
   `subsystem:Kaset category:auth`
3. In debug builds, verify `webView.isInspectable = true`, then inspect the player WebView with Safari Web Inspector.
4. To simulate auth expiry, delete `__Secure-3PAPISID` via Safari Web Inspector storage tools and trigger an authenticated API call.
5. If auth cookies or headers look suspicious, run `swift run api-explorer auth` and compare against the exported cookie state.

## Landmarks

- `docs/testing.md`
- `docs/playback.md`
- `Sources/Kaset/Views/MiniPlayerWebView.swift`
- `Sources/Kaset/Views/SingletonPlayerWebView+ObserverScript.swift`
- `Sources/Kaset/Services/Player/PlayerService.swift`
- `Sources/Kaset/Services/Player/PlayerService+WebQueueSync.swift`
- `Sources/Kaset/Services/WebKit/WebKitManager.swift`
