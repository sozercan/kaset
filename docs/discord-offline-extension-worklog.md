# Kaset Work Log: Discord RPC, Offline Mode, and Extension Diagnostics

## Date
2026-05-24

## Summary
This document tracks the recent implementation and debugging work on Kaset for:
- Discord Rich Presence reconnect behavior
- Offline mode / download cache foundation
- Extension UI diagnostics and console logging

## Referenced repos and links
- Kaset GitHub: https://github.com/sozercan/kaset
- MusicRecognizer integration repo: https://github.com/aleksey-saenko/MusicRecognizer
- Offline mode inspiration: Metrolist-style song download and offline list behavior

## Requested features to implement
- Discord Rich Presence that reconnects and displays activity when Discord starts after playback begins
- offline mode with song download support and a visible offline list
- extension popup/options UI handling with visible errors when loading fails
- terminal-visible extension logs and better diagnostics
- support for extensions using Chrome-style `runtime.connect()` / messaging APIs
- MusicRecognizer integration scaffolding for audio recognition

## Work completed

### Discord Rich Presence
- Updated `Sources/Kaset/Services/Discord/DiscordRPCService.swift`
- Added a retry loop for `SET_ACTIVITY` payloads when Discord is not available
- Added directory watchers on `/tmp` and the user temp directory to detect when Discord socket files appear
- Added diagnostics logging for socket connection attempts, handshake, and retry behavior
- Logged `errno=2` connection failures and watcher registration events

### Offline mode
- Confirmed offline settings exist in `Sources/Kaset/Services/SettingsManager.swift`
- Confirmed a basic cache service exists in `Sources/Kaset/Services/Offline/OfflineService.swift`
- Verified that the app currently exposes an offline mode flag in code, but no visible download UI has been implemented yet

### Extension diagnostics
- Confirmed extension console messages are captured in the app logs
- Validated that extension UI errors surface under `com.sertacozercan.Kaset:Extensions`
- Observed repeated extension runtime error: `Invalid call to runtime.connect(). No runtime.onConnect listeners found.`
- Confirmed extension pages may load as blank or fail silently when runtime/messaging APIs are unsupported
- Identified that popup state diagnostics are available, but a visible error overlay and recovery path are still needed

### Extension page issues
- Extension page load errors are currently invisible to the user unless inspecting logs
- Chrome-style extension API calls like `runtime.connect()` and `browser.runtime` are not fully supported
- `runtime.onConnect` listeners are missing for many extensions, causing repeated console errors
- The extension page renderer may load blank or not display controls when required API shims are absent

### Other work
- Added scaffold for MusicRecognizer integration
- Verified build progress after Discord watcher updates; the remaining compile issue in `DiscordRPCService.swift` was fixed and the project now builds cleanly

## Files touched
- `Sources/Kaset/Services/Discord/DiscordRPCService.swift`
- `Sources/Kaset/Services/SettingsManager.swift`
- `Sources/Kaset/Services/Offline/OfflineService.swift`
- `Sources/Kaset/Views/GeneralSettingsView.swift`
- `Sources/Kaset/Views/ExtensionOptionsView.swift` (diagnostics/log capture)

## Current status
- Discord RPC: retry/watch behavior added, compile issue fixed, but socket discovery and reconnection behavior still requires field validation against live Discord socket files.
- Offline mode: settings and cache foundation exist, but there is no user-facing download control or offline song list in the UI yet.
- Extension UI: console logs are visible in app logs, but extension runtime compatibility remains broken for Chrome-style `runtime.connect()` calls.
- Search result issue: current app behavior is still reporting incomplete song result displays in search.
- Logging: terminal log command visibility was confirmed, but direct extension log capture and an easier log flow remain pending.

## Current issues to address
- Discord Rich Presence should attach after Discord starts, not only when already running.
- The app needs explicit Discord socket path discovery and more robust fallback handling.
- Add a visible download/offline playlist UI and integrate `OfflineService` read/write.
- Fix extension UI crash/invisible state and propagate loading errors to the user.
- Search results only providing one result and thats too only song or either channel but it could be vast list so fix that
- Support browser extension runtime APIs expected by Chromium-style extensions, including `runtime.connect()` and `runtime.onConnect`.
- Ensure extension page load failures display a user-visible error overlay instead of failing silently.
- Ensure search results show all matching songs rather than only a single item.

## Plan / next steps
1. Validate and harden Discord socket discovery in `Sources/Kaset/Services/Discord/DiscordRPCService.swift`
   - Ensure `socketWatchers` remain retained and filesystem events are handled correctly
   - Add explicit path logging and fallback strategy for live Discord socket files
2. Confirm actual Discord socket path discovery and support multiple Discord builds/paths
   - Add explicit path logging and fallback strategy
3. Implement a visible offline/download UI
   - Add a download action in search results or playback controls
   - Add an offline song list or offline queue view
   - Hook `OfflineService` cache reads/writes to offline mode behavior
4. Improve extension compatibility
   - Support Chrome-style `runtime.connect` and runtime messaging APIs more robustly
   - Add a visible error or retry UI when extension popup/options fail
5. Add tests and regression coverage
   - `DiscordRPCService` handshake and retry behavior
   - `OfflineService` cache read/write behavior
   - Extension diagnostics logging behavior

## Notes
- The current app build is not yet fully complete for the Discord watch/fix path.
- The “download songs” feature is not available in the current UI; it is pending implementation.
