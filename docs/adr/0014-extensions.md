# ADR 0014: Extensions — User-Managed Web Extensions

**Date:** 2026-04-03  
**Status:** Accepted

## Context

Kaset did not have a way to install or manage WebKit web extensions. The app already relied on WebKit for authentication and DRM playback, but users could not:
- Add their own WebKit-compatible extensions.
- Toggle extensions on or off without editing app code.
- Open extension-provided options or popup pages from the native settings UI.

## Decision

Add user-managed **Extensions**, backed by `ExtensionsManager`:

1. **Empty by default** — no extensions are pre-installed; the manager starts with an empty list.
2. **User-added only** — users select an extension directory via a macOS open panel.
3. **Copied into app storage** — Kaset clones the selected extension into `~/Library/Application Support/Kaset/ManagedExtensions/` so it can load a stable local copy.
4. **Persisted metadata** — the extension list is stored as JSON in `~/Library/Application Support/Kaset/extensions.json`, including the copied folder path plus any options or popup page metadata derived from `manifest.json`.
5. **Toggle, configure, and remove** — each extension can be enabled/disabled, removed, or opened in an options sheet from the Extensions settings tab when the extension exposes a supported page.
6. **Loaded at launch** — `WebKitManager.loadExtensions()` reads `ExtensionsManager.resolvedURLs()` and calls `WKWebExtension(resourceBaseURL:)` for each enabled entry.

A new **Extensions** tab is added to the Settings window (`ExtensionsSettingsView`). No extension is bundled or loaded automatically by the app.

## Architecture

```
ExtensionsManager (singleton, @MainActor @Observable)
  ├── extensions: [ManagedExtension]  persisted to extensions.json
  ├── resolvedURLs() -> [(id, URL)]   resolves copied extension directories
  ├── addExtension(at:)               copies files, reads manifest.json, stores metadata
  ├── removeExtension(id:)
  └── toggleExtension(id:)

WebKitManager
  ├── loadExtensions()  iterates ExtensionsManager.resolvedURLs(), loads via WKWebExtensionController
  └── KasetWebExtensionHost exposes playback WebViews as WKWebExtension tabs/windows

ExtensionsSettingsView
  └── renders manager.extensions, calls add/remove/toggle
```

### ManagedExtension model

| Field | Type | Purpose |
|---|---|---|
| `id` | String (UUID) | Stable identifier |
| `name` | String | Display name (from manifest.json or directory name) |
| `isEnabled` | Bool | Whether to load at next launch |
| `relativePath` | String | Relative path to the copied extension inside `ManagedExtensions/` |
| `optionsPath` | String? | Relative path to an extension-provided options page, when present |
| `popupPath` | String? | Relative path to an extension-provided popup page, when present |
| `localBookmark` | Data? | Optional security-scoped bookmark for the copied local folder |

### Playback WebView hosting

WebKit extension injection is not driven by `WKWebViewConfiguration.webExtensionController` alone. WebKit also asks the containing app for browser-like tabs and windows, and `WKWebExtensionTab.webView(for:)` is the seam that lets extension content injection and tab-scoped APIs resolve the target `WKWebView`. Kaset does not expose browser tabs in its product UI, so `KasetWebExtensionHost` provides a small internal tab/window model for the two long-lived playback surfaces:

- `SingletonPlayerWebView` (`music.youtube.com`) registers as the music playback tab.
- `YouTubeWatchWebView` (`www.youtube.com/watch`) registers as the YouTube video playback tab.

The host is intentionally an adapter around existing singleton playback WebViews rather than a new owner of playback lifecycle. Playback services still own loading, teardown, and navigation; the host only supplies WebKit extension tab/window identity and forwards navigation property changes.

## Consequences

- **Positive**: Users have full control — they can install any WebKit-compatible extension, custom content scripts, privacy tools, and similar tooling.
- **Positive**: No extension is loaded by default — the app has zero implicit behavioural dependencies on a third-party codebase at runtime.
- **Positive**: Copying extensions into app storage avoids depending on the original import location remaining available.
- **Positive**: Extension options and popup pages can be surfaced through the native settings flow when available.
- **Positive**: Playback WebViews are exposed through a focused WebKit tab/window adapter, concentrating extension-hosting behaviour in one module instead of spreading `WKWebExtensionTab` protocol details across player views.
- **Negative**: Imported extensions are snapshots; if the original source folder changes, users must re-import it to pick up updates.
- **Negative**: Changes require a restart (no public unload API on `WKWebExtensionController`). The UI communicates this clearly.

## Alternatives Considered

- **Keep the app without extension support**: Rejected — users need a supported path for content scripts, privacy tools, and similar WebKit extensions.
- **Load extensions directly from the user-selected folder**: Rejected — copied local storage is more reliable than depending on ongoing access to an arbitrary external directory.
- **Reload extensions in-process without restart**: Not possible with the current `WKWebExtensionController` public API.
