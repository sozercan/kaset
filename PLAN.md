# Plan: Native macOS YouTube Music App (MVP)

A native SwiftUI YouTube Music client for macOS 14+ / Swift 6.0+ using browser-cookie authentication with auto-extraction, a hidden `WKWebView` for Premium playback, and native UI for browsing. Follows AGENTS.md patterns: phased delivery, testable exit criteria, and rollback points.

---

## Phase 1: Project Scaffolding & Configuration

**Deliverable:** Xcode project with correct structure, build settings, and entitlements.

| Step | Action |
|------|--------|
| 1.1 | Create macOS App target (SwiftUI lifecycle) with bundle ID and macOS 14.0+ deployment target. |
| 1.2 | Create folder structure: `App/`, `Core/Models/`, `Core/Services/`, `Core/ViewModels/`, `Core/Utilities/`, `Views/macOS/`, `Tests/`. |
| 1.3 | Add entitlements: `com.apple.security.network.client` (outgoing connections), `com.apple.security.app-sandbox` (sandbox). |
| 1.4 | Configure SwiftLint + SwiftFormat with rules matching AGENTS.md style (no `NavigationView`, no `DispatchQueue`, etc.). |

**Exit Criteria:**
- [ ] `xcodebuild -scheme YouTubeMusic -destination 'platform=macOS'` succeeds with zero warnings.
- [ ] `swiftlint --strict && swiftformat --lint .` passes.
- [ ] App launches and shows an empty window.

**Rollback:** Delete project folder; no dependencies on prior state.

---

## Phase 2: WebKit Infrastructure & Persistent Login

**Deliverable:** A reusable `WebKitManager` that owns a persistent `WKWebsiteDataStore`, exposes cookie access, and notifies on cookie changes.

| Step | Action |
|------|--------|
| 2.1 | Create `Core/Services/WebKit/WebKitManager.swift` as a `@MainActor @Observable` singleton. |
| 2.2 | Initialize a persistent `WKWebsiteDataStore(forIdentifier: UUID("YouTubeMusic"))` and store reference. |
| 2.3 | Expose `func getAllCookies() async -> [HTTPCookie]` wrapping `httpCookieStore.allCookies()`. |
| 2.4 | Conform to `WKHTTPCookieStoreObserver`; publish a `@Published var cookiesDidChange: Date` timestamp on each `cookiesDidChange(in:)` callback. |
| 2.5 | Add helper `func cookieHeader(for domain: String) async -> String?` that filters cookies and returns `HTTPCookie.requestHeaderFields(with:)["Cookie"]`. |

**Exit Criteria:**
- [ ] Unit test: `WebKitManager` can set a test cookie, retrieve it, and the observer fires.
- [ ] Cookies persist across app relaunch (manually verify by printing cookies on launch).

**Rollback:** Remove `WebKitManager.swift`; no other code depends on it yet.

---

## Phase 3: Login Flow & Cookie Auto-Extraction

**Deliverable:** A login sheet that presents `https://music.youtube.com`, detects successful sign-in, and extracts the `__Secure-3PAPISID` cookie automatically.

| Step | Action |
|------|--------|
| 3.1 | Create `Core/Services/Auth/AuthService.swift` (`@MainActor @Observable`) with states: `.loggedOut`, `.loggingIn`, `.loggedIn(sapisid: String)`. |
| 3.2 | Create `Views/macOS/LoginWebView.swift` — an `NSViewRepresentable` wrapping `WKWebView` using `WebKitManager`'s shared data store configuration. |
| 3.3 | In `AuthService`, expose `func startLogin()` that sets state to `.loggingIn` and triggers sheet presentation. |
| 3.4 | Observe `WebKitManager.cookiesDidChange`; on each change, call `checkLoginStatus()` which looks for `__Secure-3PAPISID` in cookies. If found, transition to `.loggedIn`. |
| 3.5 | Create `Views/macOS/LoginSheet.swift` that presents `LoginWebView` modally and dismisses when `AuthService.state == .loggedIn`. |
| 3.6 | On app launch, call `checkLoginStatus()` to auto-restore login if cookies exist. |

**Exit Criteria:**
- [ ] Launching app with no prior login shows login sheet automatically.
- [ ] Signing in via Google in the sheet auto-dismisses the sheet and logs `AuthService.state == .loggedIn`.
- [ ] Relaunch app → no login sheet shown; `AuthService` is `.loggedIn` immediately.
- [ ] Delete app's WebKit data (via `WKWebsiteDataStore.removeData`) → next launch shows login sheet again.

**Rollback:** Remove `AuthService`, `LoginWebView`, `LoginSheet`; revert `WebKitManager` observer usage.

---

## Phase 4: YouTube Music API Client (Browser Auth)

**Deliverable:** A Swift `YTMusicClient` that makes authenticated requests to YouTube Music's internal API, computing SAPISIDHASH authorization per request.

| Step | Action |
|------|--------|
| 4.1 | Create `Core/Services/API/YTMusicClient.swift` (`@MainActor`) with dependency on `AuthService` and `WebKitManager`. |
| 4.2 | Implement `private func buildAuthHeaders() async throws -> [String: String]` that: (a) gets `__Secure-3PAPISID` from cookies, (b) computes `SAPISIDHASH` = `<timestamp>_<SHA1(timestamp + " " + sapisid + " " + origin)>`, (c) returns `Cookie`, `Authorization`, `Origin`, `Content-Type` headers. |
| 4.3 | Implement `private func request<T: Decodable>(_ endpoint: String, body: [String: Any]) async throws -> T` that POSTs to `https://music.youtube.com/youtubei/v1/{endpoint}?prettyPrint=false` with standard `context` payload (client name `WEB_REMIX`, version, etc.). |
| 4.4 | Throw `YTMusicError.authExpired` on HTTP 401/403; throw `YTMusicError.networkError` on other failures. |
| 4.5 | Implement MVP endpoints: `getHome() async throws -> HomeResponse`, `search(query:) async throws -> SearchResponse`, `getLibraryPlaylists() async throws -> [Playlist]`, `getPlaylist(id:) async throws -> PlaylistDetail`. |
| 4.6 | Create corresponding `Core/Models/` structs: `Song`, `Playlist`, `Album`, `Artist`, `HomeSection`, etc., with `Decodable` conformance parsing YouTube Music's nested JSON. |

**Exit Criteria:**
- [ ] Unit test with mock URLProtocol: `buildAuthHeaders()` produces correct SAPISIDHASH format.
- [ ] Integration test (requires login): `getHome()` returns non-empty `[HomeSection]`.
- [ ] Integration test: `search(query: "never gonna give you up")` returns results containing expected song.
- [ ] When cookies are cleared, API call throws `YTMusicError.authExpired`.

**Rollback:** Remove `YTMusicClient` and model files; no UI depends on them yet.

---

## Phase 5: Hidden WebView Playback Engine

**Deliverable:** A `PlayerService` that controls playback via a hidden `WKWebView` logged into YouTube Music, exposing native Swift controls and state.

| Step | Action |
|------|--------|
| 5.1 | Create `Core/Services/Player/PlayerService.swift` (`@MainActor @Observable`) with state: `currentTrack: Song?`, `isPlaying: Bool`, `progress: TimeInterval`, `duration: TimeInterval`, `queue: [Song]`. |
| 5.2 | Create `Core/Services/Player/PlayerWebView.swift` — a hidden `WKWebView` (frame `.zero`, not added to view hierarchy) using `WebKitManager`'s shared data store. |
| 5.3 | On init, load `https://music.youtube.com` in the hidden webview; wait for page load completion. |
| 5.4 | Inject JavaScript bridge via `WKUserContentController` + `WKScriptMessageHandler` to receive events: `N_STATE_CHANGE`, `N_PROGRESS`, `N_VIDEO_DATA`. |
| 5.5 | Inject JavaScript that hooks into `document.querySelector("ytmusic-app-layout>ytmusic-player-bar").playerApi` and forwards events to the message handler. |
| 5.6 | Expose async control methods: `play(videoId:)`, `playPause()`, `next()`, `previous()`, `seek(to:)`, `setVolume(_:)` — each calls `evaluateJavaScript` with the appropriate `playerApi` method. |
| 5.7 | Parse incoming JS messages to update `@Observable` state properties. |

**Exit Criteria:**
- [ ] `PlayerService.play(videoId: "dQw4w9WgXcQ")` starts playback (audio audible).
- [ ] `isPlaying` toggles correctly on `playPause()`.
- [ ] `progress` updates every ~1 second during playback.
- [ ] `next()` advances to the next track; `currentTrack` updates.
- [ ] Premium user: no ads play; track starts immediately.

**Rollback:** Remove `PlayerService`, `PlayerWebView`; app still builds and shows UI (just no playback).

---

## Phase 6: macOS System Integration

**Deliverable:** Now Playing info in Control Center, media key support, and Dock menu controls.

| Step | Action |
|------|--------|
| 6.1 | Create `Core/Services/Player/NowPlayingManager.swift` that observes `PlayerService` state. |
| 6.2 | Update `MPNowPlayingInfoCenter.default().nowPlayingInfo` with title, artist, album, artwork (async image fetch), duration, elapsed time. |
| 6.3 | Register `MPRemoteCommandCenter` handlers: `.playCommand`, `.pauseCommand`, `.nextTrackCommand`, `.previousTrackCommand`, `.changePlaybackPositionCommand` → call corresponding `PlayerService` methods. |
| 6.4 | Add Dock menu items (Play/Pause, Next, Previous) via `NSApplication.shared.dockTile` or `@NSApplicationDelegateAdaptor`. |

**Exit Criteria:**
- [ ] Playing a track shows title + artist in macOS Control Center (click clock area).
- [ ] Media keys (F7/F8/F9 or Touch Bar) control playback.
- [ ] Right-click Dock icon shows Play/Pause, Next, Previous; clicking them works.

**Rollback:** Remove `NowPlayingManager`; playback still works, just no system integration.

---

## Phase 7: Core UI Implementation

**Deliverable:** Main window with sidebar navigation, player bar, and content views for Home, Library, and Search.

| Step | Action |
|------|--------|
| 7.1 | Create `Views/macOS/MainWindow.swift` with `NavigationSplitView` (sidebar + detail). |
| 7.2 | Create `Views/macOS/Sidebar.swift` with sections: Home, Library (Playlists, Songs, Albums), Search. Use `NavigationLink` with value-based navigation. |
| 7.3 | Create `Views/macOS/PlayerBar.swift` — a bottom bar with album art thumbnail, track info, play/pause/next/prev buttons, progress slider, volume slider. Bind to `PlayerService` state. |
| 7.4 | Create `Views/macOS/HomeView.swift` displaying `HomeSection` rows (horizontal scroll of cards). Tap card → `PlayerService.play(videoId:)`. |
| 7.5 | Create `Views/macOS/LibraryView.swift` listing user's playlists from `YTMusicClient.getLibraryPlaylists()`. |
| 7.6 | Create `Views/macOS/PlaylistDetailView.swift` showing tracks; tap row → play track. |
| 7.7 | Create `Views/macOS/SearchView.swift` with search field; debounced calls to `YTMusicClient.search(query:)`; display results as list. |
| 7.8 | Create `Core/ViewModels/` for each view: `HomeViewModel`, `LibraryViewModel`, `SearchViewModel` — handle loading/error states, expose `@Observable` data. |

**Exit Criteria:**
- [ ] App launches → Home view loads and displays personalized sections.
- [ ] Clicking sidebar "Library > Playlists" shows user's playlists.
- [ ] Clicking a playlist shows its tracks.
- [ ] Clicking a track starts playback; `PlayerBar` updates with track info and progress.
- [ ] Search returns results; clicking a result plays it.
- [ ] All views handle loading (spinner) and error (retry button) states gracefully.

**Rollback:** Remove `Views/macOS/*` except `LoginSheet`; app still authenticates and `PlayerService` works headlessly.

---

## Phase 8: Auth Recovery & Error Handling

**Deliverable:** Robust handling of session expiry: detect 401/403, prompt re-login, retry failed requests.

| Step | Action |
|------|--------|
| 8.1 | In `YTMusicClient`, catch `YTMusicError.authExpired` and notify `AuthService.sessionExpired()`. |
| 8.2 | In `AuthService.sessionExpired()`, transition to `.loggedOut` and set a flag `needsReauth = true`. |
| 8.3 | In `MainWindow`, observe `AuthService.needsReauth`; if true, present `LoginSheet` as a modal. |
| 8.4 | After successful re-login (`.loggedIn`), set `needsReauth = false` and refresh the current view's data. |
| 8.5 | Add a "Sign Out" menu item that clears `WKWebsiteDataStore` and transitions to `.loggedOut`. |

**Exit Criteria:**
- [ ] Simulate expired session (manually delete `__Secure-3PAPISID` cookie) → next API call triggers login sheet.
- [ ] Re-authenticate → sheet dismisses, view reloads data successfully.
- [ ] "Sign Out" menu item clears session; app shows login sheet.

**Rollback:** Remove recovery logic; app will crash or show errors on auth failure (acceptable for earlier phases).

---

## Phase 9: Polish & Quality Assurance

**Deliverable:** Production-ready MVP with logging, accessibility, and passing test suite.

| Step | Action |
|------|--------|
| 9.1 | Add `DiagnosticsLogger` using `os.Logger` for auth, API, and playback events. |
| 9.2 | Add `.accessibilityLabel()` to all icon-only buttons (play, pause, next, prev, etc.). |
| 9.3 | Ensure all async operations show loading indicators; all errors show user-friendly messages with retry. |
| 9.4 | Write unit tests for `YTMusicClient` (mocked), `AuthService` state transitions, `PlayerService` state updates. |
| 9.5 | Run `swiftlint --strict && swiftformat .` and fix any issues. |
| 9.6 | Test with VoiceOver enabled; ensure all controls are navigable and labeled. |

**Exit Criteria:**
- [ ] `xcodebuild test -scheme YouTubeMusic -destination 'platform=macOS'` passes all tests.
- [ ] `swiftlint --strict` reports zero violations.
- [ ] VoiceOver can navigate sidebar, play a track, and control playback.
- [ ] Console logs show structured diagnostics for key events (login, API calls, playback state changes).

**Rollback:** N/A — this phase is additive polish.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                        YouTubeMusicApp                          │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────────────┐   │
│  │ AuthService │◄──│WebKitManager│──►│ WKWebsiteDataStore  │   │
│  │ (state)     │   │ (cookies)   │   │ (persistent)        │   │
│  └──────┬──────┘   └──────┬──────┘   └─────────────────────┘   │
│         │                 │                                     │
│         ▼                 ▼                                     │
│  ┌─────────────┐   ┌─────────────┐                             │
│  │YTMusicClient│   │PlayerService│◄─── Hidden WKWebView        │
│  │ (API calls) │   │ (playback)  │     (music.youtube.com)     │
│  └──────┬──────┘   └──────┬──────┘                             │
│         │                 │                                     │
│         ▼                 ▼                                     │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                    ViewModels                            │   │
│  │  HomeVM  │  LibraryVM  │  SearchVM  │  PlayerVM          │   │
│  └─────────────────────────────────────────────────────────┘   │
│         │                                                       │
│         ▼                                                       │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │                     SwiftUI Views                        │   │
│  │  MainWindow ─┬─ Sidebar ─┬─ HomeView                     │   │
│  │              │           ├─ LibraryView / PlaylistDetail │   │
│  │              │           └─ SearchView                   │   │
│  │              └─ PlayerBar                                │   │
│  └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│                    NowPlayingManager ──► MPNowPlayingInfoCenter │
│                                      ──► MPRemoteCommandCenter  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Risk Mitigations

| Risk | Mitigation |
|------|------------|
| YouTube Music API changes break parsing | Use defensive decoding (`decodeIfPresent`); log parse failures; version-pin known-working payload shapes. |
| `playerApi` DOM selector changes | Abstract selectors into a single JS file; monitor ytmdesktop repo for updates. |
| Google blocks headless/hidden WebView | User-Agent matches real Safari; WebView is real WebKit, not headless. |
| Cookie rotation breaks SAPISIDHASH | `WKHTTPCookieStoreObserver` ensures we always use fresh cookies. |

---

## Out of Scope (Future)

- Uploads functionality
- Podcasts
- Last.fm scrobbling
- Discord Rich Presence
- Lyrics display
- Queue management UI
- Multiple account support
- iOS/watchOS versions
