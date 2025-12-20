# AGENTS.md

Guidance for AI coding assistants (Claude, GitHub Copilot, Cursor, etc.) working on this repository.

## Role

You are a Senior Swift Engineer specializing in SwiftUI, Swift Concurrency, and macOS development. Your code must adhere to Apple's Human Interface Guidelines. Target **Swift 6.0+** and **macOS 14.0+**.

## What is YouTube Music?

A native **macOS** YouTube Music client built with **Swift** and **SwiftUI**.

- **Browser-cookie authentication**: Auto-extracts cookies from an in-app login WebView
- **Hidden WebView playback**: Supports YouTube Music Premium (DRM content)
- **Native UI**: SwiftUI sidebar navigation, player bar, and content views
- **System integration**: Now Playing in Control Center, media keys, Dock menu

## Project Structure

```
App/                → App entry point (YouTubeMusicApp.swift)
Core/
  ├── Models/       → Data models (Song, Playlist, Album, Artist, etc.)
  ├── Services/
  │   ├── API/      → YTMusicClient (YouTube Music API calls)
  │   ├── Auth/     → AuthService (login state machine)
  │   ├── Player/   → PlayerService, NowPlayingManager (playback control)
  │   └── WebKit/   → WebKitManager (cookie store, persistent login)
  ├── ViewModels/   → HomeViewModel, LibraryViewModel, SearchViewModel
  └── Utilities/    → DiagnosticsLogger, extensions
Views/
  └── macOS/        → SwiftUI views (MainWindow, Sidebar, PlayerBar, etc.)
Tests/              → Unit tests (YouTubeMusicTests/)
```

## Before You Start: Read the Plan

**Always consult [PLAN.md](PLAN.md) before making changes.** It contains the phased implementation plan with exit criteria and architecture decisions.

## Task Planning: Phases with Exit Criteria

For any non-trivial task, **plan in phases with testable exit criteria** before writing code.

### Phase Structure

Every task should be broken into phases. Each phase must have:
1. **Clear deliverable** — What artifact or change is produced
2. **Testable exit criteria** — How to verify the phase is complete
3. **Rollback point** — The phase should leave the codebase in a working state

### Standard Phases

#### Phase 1: Research & Understanding
| Deliverable | Exit Criteria |
|-------------|---------------|
| Identify affected files and dependencies | List all files to modify/create |
| Understand existing patterns | Can explain how similar features work |
| Read PLAN.md | Confirmed approach aligns with architecture |

**Exit gate**: Can articulate the implementation plan without ambiguity.

#### Phase 2: Interface Design
| Deliverable | Exit Criteria |
|-------------|---------------|
| Define new types/protocols | Type signatures compile |
| Plan public API surface | No breaking changes to existing callers |

**Exit gate**: `xcodebuild build` succeeds with stub implementations.

#### Phase 3: Core Implementation
| Deliverable | Exit Criteria |
|-------------|---------------|
| Implement business logic | Unit tests pass for new code |
| Handle error cases | Error paths have test coverage |
| Add logging | `DiagnosticsLogger` calls in place |

**Exit gate**: `xcodebuild test -only-testing:YouTubeMusicTests` passes.

#### Phase 4: Quality Assurance
| Deliverable | Exit Criteria |
|-------------|---------------|
| Linting passes | `swiftlint --strict` reports 0 errors |
| Formatting applied | `swiftformat .` makes no changes |
| Full test suite passes | `xcodebuild test` succeeds |

**Exit gate**: CI-equivalent checks pass locally.

### Checkpoint Communication

After each phase, briefly report:
- ✅ What was completed
- 🧪 Test/verification results
- ➡️ Next phase plan

## Critical Rules (Apply to EVERY Task)

> ⚠️ **NEVER run `git commit` or `git push`** — Always leave committing and pushing to the human.

1. **macOS Only**: This is a macOS-only app. No `#if os()` guards needed unless adding iOS/watchOS in the future.

2. **Verify Builds**: After modifying code, verify the build:
   ```bash
   xcodebuild -scheme YouTubeMusic -destination 'platform=macOS' build
   ```

3. **Linting**: Run after non-trivial changes:
   ```bash
   swiftlint --strict && swiftformat .
   ```

4. **Unit Tests Required**: New code in `Core/` must include tests in `Tests/YouTubeMusicTests/`.

5. **Use Modern SwiftUI APIs**:
   - `.foregroundStyle()` not `.foregroundColor()`
   - `.clipShape(.rect(cornerRadius:))` not `.cornerRadius()`
   - `onChange(of:) { _, newValue in }` (two-param closure)
   - `Task.sleep(for: .seconds())` not `Task.sleep(nanoseconds:)`
   - `NavigationSplitView` or `NavigationStack` not `NavigationView`
   - `Button` not `onTapGesture()` (unless tap location needed)
   - Avoid `AnyView` — use concrete types or `@ViewBuilder`
   - Add `.accessibilityLabel()` to image-only buttons

6. **No Third-Party Frameworks**: Do not introduce third-party dependencies without asking first. This app uses only Apple frameworks.

7. **Swift Concurrency**: Always mark `@Observable` classes with `@MainActor`. Never use `DispatchQueue` — use Swift concurrency (`async`/`await`, `MainActor`).

8. **XCTest with @MainActor**: For `@MainActor` test classes, use `async` setUp/tearDown **without** calling `super`:
   ```swift
   @MainActor
   final class MyServiceTests: XCTestCase {
       override func setUp() async throws {
           // Do NOT call: try await super.setUp()
           // Set up test fixtures here
       }
       
       override func tearDown() async throws {
           // Clean up here
           // Do NOT call: try await super.tearDown()
       }
   }
   ```
   **Why?** `XCTestCase` is not `Sendable`. Calling `super.setUp()` from a `@MainActor` async context sends `self` across actor boundaries, causing Swift 6 strict concurrency errors.

9. **WebKit Patterns**: 
   - Always use `WebKitManager`'s shared `WKWebsiteDataStore` for cookie persistence
   - Use `WKHTTPCookieStoreObserver` for cookie change notifications, not polling
   - Compute `SAPISIDHASH` fresh per request using current cookies

10. **Error Handling**:
    - Throw `YTMusicError.authExpired` on HTTP 401/403
    - Use `DiagnosticsLogger` for all logging (not `print()`)
    - Show user-friendly error messages with retry options

## Quick Style Rules

| ❌ Avoid | ✅ Prefer |
|----------|-----------|
| `DispatchQueue.main.async` | `await MainActor.run {}` or `@MainActor` |
| `NavigationView` | `NavigationSplitView` or `NavigationStack` |
| `onTapGesture()` | `Button` (unless tap location needed) |
| `AnyView` | Concrete types or `@ViewBuilder` |
| `print()` | `DiagnosticsLogger` |
| Force unwraps (`!`) | Optional handling or `guard` |
| `super.setUp()` in `@MainActor` tests | Omit super calls in async setUp/tearDown |
| Polling cookies | `WKHTTPCookieStoreObserver` |
| Hardcoded DOM selectors | Centralized JS constants file |

## Quick Reference

### Build Commands

```bash
# Build
xcodebuild -scheme YouTubeMusic -destination 'platform=macOS' build

# Test
xcodebuild -scheme YouTubeMusic -destination 'platform=macOS' test

# Lint & Format
swiftlint --strict && swiftformat .
```

### Key Files

- `Core/Services/WebKit/WebKitManager.swift` — Cookie store & persistence
- `Core/Services/Auth/AuthService.swift` — Login state machine
- `Core/Services/API/YTMusicClient.swift` — YouTube Music API client
- `Core/Services/Player/PlayerService.swift` — Playback control via hidden WebView
- `Core/Services/Player/NowPlayingManager.swift` — System media integration
- `Core/Utilities/DiagnosticsLogger.swift` — Logging (use this for all logs)
- `Core/Models/YTMusicError.swift` — Unified error types

### Authentication Flow

```
App Launch
    │
    ▼
┌─────────────────┐
│ Check cookies   │──── __Secure-3PAPISID exists? ────┐
│ in WebKitManager│                                    │
└─────────────────┘                                    │
    │ No                                               │ Yes
    ▼                                                  ▼
┌─────────────────┐                          ┌─────────────────┐
│ Show LoginSheet │                          │ AuthService     │
│ (WKWebView)     │                          │ .loggedIn       │
└─────────────────┘                          └─────────────────┘
    │
    │ User signs in → cookies set
    │
    ▼
┌─────────────────┐
│ Observer fires  │
│ cookiesDidChange│
└─────────────────┘
    │
    ▼
┌─────────────────┐
│ Extract SAPISID │
│ Dismiss sheet   │
└─────────────────┘
```

### API Request Flow

```
YTMusicClient.getHome()
    │
    ▼
┌─────────────────────────────────────────────────┐
│ buildAuthHeaders()                              │
│  1. Get cookies from WebKitManager              │
│  2. Extract __Secure-3PAPISID                   │
│  3. Compute SAPISIDHASH = ts_SHA1(ts+sapi+origin)│
│  4. Build Cookie, Authorization, Origin headers │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ POST https://music.youtube.com/youtubei/v1/browse│
│ Body: { context: { client: WEB_REMIX }, ... }   │
└─────────────────────────────────────────────────┘
    │
    ├── 200 OK → Parse JSON → Return HomeResponse
    │
    └── 401/403 → Throw YTMusicError.authExpired
                  → AuthService.sessionExpired()
                  → Show LoginSheet
```

### Playback Flow

```
User clicks Play
    │
    ▼
┌─────────────────────────────────────────────────┐
│ PlayerService.play(videoId:)                    │
│  → evaluateJavaScript in hidden WKWebView       │
│  → playerApi.loadVideoById(videoId)             │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ WKWebView plays audio (DRM handled by WebKit)   │
│  → JS bridge sends state updates                │
│  → PlayerService updates @Observable properties │
└─────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────┐
│ NowPlayingManager observes PlayerService        │
│  → Updates MPNowPlayingInfoCenter               │
│  → Registers MPRemoteCommandCenter handlers     │
└─────────────────────────────────────────────────┘
```
