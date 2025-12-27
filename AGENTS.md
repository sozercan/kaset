# AGENTS.md

Guidance for AI coding assistants (Claude, GitHub Copilot, Cursor, etc.) working on this repository.

## Role

You are a Senior Swift Engineer specializing in SwiftUI, Swift Concurrency, and macOS development. Your code must adhere to Apple's Human Interface Guidelines. Target **Swift 6.0+** and **macOS 26.0+**.

## What is Kaset?

A native **macOS** YouTube Music client built with **Swift** and **SwiftUI**.

- **Apple Music-style UI**: Liquid Glass player bar, clean sidebar navigation
- **Browser-cookie authentication**: Auto-extracts cookies from an in-app login WebView
- **Hidden WebView playback**: Singleton WebView for YouTube Music Premium (DRM content)
- **Background audio**: Audio continues when window is closed, stops on quit
- **Native UI**: SwiftUI sidebar navigation, player bar, and content views
- **System integration**: Now Playing in Control Center, media keys, Dock menu

## Project Structure

```
App/                → App entry point, AppDelegate (window lifecycle)
Core/
  ├── Models/       → Data models (Song, Playlist, Album, Artist, etc.)
  ├── Services/
  │   ├── API/      → YTMusicClient, Parsers/ (response parsing)
  │   ├── Auth/     → AuthService (login state machine)
  │   ├── Player/   → PlayerService, NowPlayingManager (playback, media keys)
  │   └── WebKit/   → WebKitManager (cookie store, persistent login)
  ├── ViewModels/   → HomeViewModel, LibraryViewModel, SearchViewModel
  └── Utilities/    → DiagnosticsLogger, extensions
Views/
  └── macOS/        → SwiftUI views (MainWindow, Sidebar, PlayerBar, etc.)
Tests/              → Unit tests (KasetTests/)
Tools/              → Standalone CLI tools (api-explorer.swift)
docs/               → Detailed documentation
  └── adr/          → Architecture Decision Records
```

## Documentation

For detailed information, see the `docs/` folder:

- **[docs/architecture.md](docs/architecture.md)** — Services, state management, data flow
- **[docs/playback.md](docs/playback.md)** — WebView playback system, background audio
- **[docs/testing.md](docs/testing.md)** — Test commands, patterns, debugging
- **[docs/adr/](docs/adr/)** — Architecture Decision Records (ADRs)

## Before You Start

1. **Read [PLAN.md](PLAN.md)** — Contains the phased implementation plan
2. **Understand the playback architecture** — See [docs/playback.md](docs/playback.md)
3. **Check ADRs for past decisions** — See [docs/adr/](docs/adr/) before proposing architectural changes
4. **Consult API documentation before implementing API features** — See [docs/api-discovery.md](docs/api-discovery.md) for endpoint reference

### API Discovery Workflow

> ⚠️ **MANDATORY**: Before implementing ANY feature that requires a new or modified API call, you MUST explore the endpoint first using the API Explorer tool. Do NOT guess or assume API response structures.

#### Step 1: Explore with Standalone Tool (Required)

Use the standalone CLI tool to explore endpoints **before writing any code**:

```bash
# Check authentication status
./Tools/api-explorer.swift auth

# List all known endpoints
./Tools/api-explorer.swift list

# Explore public browse endpoints
./Tools/api-explorer.swift browse FEmusic_charts
./Tools/api-explorer.swift browse FEmusic_moods_and_genres

# Explore authenticated endpoints (requires Kaset sign-in)
./Tools/api-explorer.swift browse FEmusic_liked_playlists
./Tools/api-explorer.swift browse FEmusic_history

# Explore with verbose output to see raw JSON
./Tools/api-explorer.swift browse FEmusic_home -v

# Explore action endpoints
./Tools/api-explorer.swift action search '{"query":"taylor swift"}'
./Tools/api-explorer.swift action player '{"videoId":"dQw4w9WgXcQ"}'
```

The tool automatically uses cookies from the Kaset app for authenticated endpoints.

#### Step 2: Check Documentation

Review [docs/api-discovery.md](docs/api-discovery.md) to see if the endpoint is already documented with its auth requirements and response structure.

#### Step 3: For Authenticated Endpoints (🔐)

If the endpoint requires authentication:
1. Run `./Tools/api-explorer.swift auth` to check cookie status
2. If no cookies, run the Kaset app and sign in to YouTube Music
3. The app saves cookies to `~/Library/Application Support/Kaset/cookies.dat`
4. Run the API explorer again

#### Step 4: Document Findings

If you discover new response structures or endpoint behaviors, update [docs/api-discovery.md](docs/api-discovery.md) with your findings.

> ⚠️ **Do NOT guess API structures** — Always verify with the API Explorer tool or documentation before writing parsers. Incorrect assumptions lead to runtime failures.

## Critical Rules

> 🚨 **NEVER leak secrets, cookies, API keys, or tokens** — Under NO circumstances include real cookies, authentication tokens, API keys, SAPISID values, or any sensitive credentials in code, comments, logs, documentation, test fixtures, or any output. Always use placeholder values like `"REDACTED"`, `"mock-token"`, or `"test-cookie"` in examples and tests. This applies to all files including tests, docs, and ADRs. **Violation of this rule is a critical security incident.**

> ⚠️ **NEVER run `git commit` or `git push`** — Always leave committing and pushing to the human.

> ⚠️ **ALWAYS confirm before running UI tests** — UI tests launch the app and can be disruptive. Ask the human for permission before executing any UI test.

> ⚠️ **No Third-Party Frameworks** — Do not introduce third-party dependencies without asking first.

> ⚠️ **Prefer API over WebView** — Always use `YTMusicClient` API calls when functionality exists. Only use WebView for playback (DRM-protected audio) and authentication. API calls are faster, more testable, and reduce WebView complexity.

> 📝 **Document Architectural Decisions** — For significant design changes, create an ADR in `docs/adr/` following the format in [docs/adr/README.md](docs/adr/README.md).

> ⚡ **Performance Awareness** — For non-trivial features, run performance tests and verify no anti-patterns. When adding parsers or API calls, include `measure {}` tests.

> 🔧 **Improve API Explorer, Don't Write One-Off Scripts** — When exploring or debugging API-related functionality, **always enhance `Tools/api-explorer.swift`** instead of writing temporary scripts. This ensures the tool grows with the project, maintains consistency, and provides reusable functionality for future API work. If you need to fetch raw JSON, test a new endpoint, or debug response parsing, add that capability to the API explorer.

### Build & Verify

After modifying code, verify the build:

```bash
xcodebuild -scheme Kaset -destination 'platform=macOS' build
```

### Code Quality

```bash
swiftlint --strict && swiftformat .
```

> ⚠️ **SwiftFormat `--self insert` rule**: The project uses `--self insert` in `.swiftformat`. This means:
> - In static methods, call other static methods with `Self.methodName()` (not bare `methodName()`)
> - In instance methods, use `self.property` explicitly
> 
> Always run `swiftformat .` before completing work to auto-fix these issues.

### Modern SwiftUI APIs

| ❌ Avoid | ✅ Use |
|----------|--------|
| `.foregroundColor()` | `.foregroundStyle()` |
| `.cornerRadius()` | `.clipShape(.rect(cornerRadius:))` |
| `onChange(of:) { newValue in }` | `onChange(of:) { _, newValue in }` |
| `Task.sleep(nanoseconds:)` | `Task.sleep(for: .seconds())` |
| `NavigationView` | `NavigationSplitView` or `NavigationStack` |
| `onTapGesture()` | `Button` (unless tap location needed) |
| `tabItem()` | `Tab` API |
| `AnyView` | Concrete types or `@ViewBuilder` |
| `print()` | `DiagnosticsLogger` |
| `DispatchQueue` | Swift concurrency (`async`/`await`) |
| `String(format: "%.2f", n)` | `Text(n, format: .number.precision(...))` |
| Force unwraps (`!`) | Optional handling or `guard` |
| Image-only buttons without labels | Add `.accessibilityLabel()` |
| `.background(.ultraThinMaterial)` | `.glassEffect()` for macOS 26+ |

### Liquid Glass UI (macOS 26+)

The app uses Apple's Liquid Glass design language for macOS 26:

```swift
// Player bar with liquid glass capsule
HStack { /* controls */ }
    .glassEffect(.regular.interactive(), in: .capsule)

// Wrap multiple glass elements in a container
GlassEffectContainer(spacing: 0) {
    // Glass elements here
}

// Materialize transition for appearing panels
QueueView()
    .glassEffectTransition(.materialize)

// Glass effect ID for morphing support
.glassEffectID("queue", in: playerNamespace)

// Glass search field
TextField("Search...", text: $query)
    .glassEffect(.regular, in: .capsule)
```

**Liquid Glass Anti-Patterns** (avoid these):
- ❌ `.buttonStyle(.glass)` on buttons inside a glass container (causes rectangles)
- ❌ `glassEffectUnion` on buttons already in a glass capsule (glass-on-glass)
- ❌ Glass effects on content areas (lists, tables, media)
- ❌ Custom opacity that bypasses accessibility

**Implemented Glass Effects**:
- `PlayerBar` — glass capsule with namespace for morphing
- `Sidebar` — wrapped in `GlassEffectContainer`
- `QueueView` / `LyricsView` — `.glassEffectTransition(.materialize)`
- `SearchView` — glass search field and suggestions dropdown
```

**PlayerBar Pattern**:
- Each view that can be navigated to must include the `PlayerBar` via `safeAreaInset`
- The `PlayerBar` floats at the bottom of the content area (not sidebar)
- Uses `.glassEffect(.regular.interactive(), in: .capsule)` for the liquid glass look
- Uses `@Namespace` for glass effect morphing support

```swift
// Add to every navigable view
.safeAreaInset(edge: .bottom, spacing: 0) {
    PlayerBar()
}
```

**Key Views requiring PlayerBar**:
- `HomeView` (on NavigationStack)
- `LibraryView` (on NavigationStack)
- `SearchView` (on VStack)
- `PlaylistDetailView` (on Group)

### Swift Testing (Preferred)

> ✅ **Use Swift Testing for all new unit tests** — See [ADR-0006](docs/adr/0006-swift-testing-migration.md) for details.

Swift Testing is 4x faster than XCTest and provides cleaner syntax. Use it for all new tests except:
- **Performance tests** — Keep in XCTest (requires `measure {}`)
- **UI tests** — Keep in XCTest (requires XCUIApplication)

| XCTest | Swift Testing |
|--------|---------------|
| `import XCTest` | `import Testing` |
| `class ... : XCTestCase` | `@Suite struct ...` |
| `func testFoo()` | `@Test func foo()` |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertTrue(x)` | `#expect(x)` |
| `XCTAssertNil(x)` | `#expect(x == nil)` |
| `XCTFail("msg")` | `Issue.record("msg")` |
| `setUp()` / `tearDown()` | `init()` (ARC handles cleanup) |

**Pattern for `@MainActor` tests:**

```swift
import Testing
@testable import Kaset

@Suite(.serialized)  // Required for @MainActor
@MainActor
struct MyServiceTests {
    let service: MyService
    let mockClient: MockYTMusicClient

    init() {
        mockClient = MockYTMusicClient()
        service = MyService(client: mockClient)
    }

    @Test("Does something correctly")
    func doesSomething() async {
        await service.doSomething()
        #expect(service.state == .done)
    }
}
```

**Parameterized tests** — Use for multiple input cases:

```swift
@Test("Status raw values", arguments: [
    (LikeStatus.liked, "LIKE"),
    (LikeStatus.disliked, "DISLIKE"),
])
func statusRawValues(status: LikeStatus, expected: String) {
    #expect(status.rawValue == expected)
}
```

### Swift Concurrency

- Mark `@Observable` classes with `@MainActor`
- Never use `DispatchQueue` — use `async`/`await`, `MainActor`

### WebKit Patterns

- Use `WebKitManager`'s shared `WKWebsiteDataStore` for cookie persistence
- Use `SingletonPlayerWebView.shared` for playback (never create multiple WebViews)
- Compute `SAPISIDHASH` fresh per request using current cookies

### Error Handling

- Throw `YTMusicError.authExpired` on HTTP 401/403
- Use `DiagnosticsLogger` for all logging (not `print()`)
- Show user-friendly error messages with retry options

## Key Files

| File | Purpose |
|------|---------|
| `Tools/api-explorer.swift` | **Standalone API explorer CLI** (run before implementing API features) |
| `App/AppDelegate.swift` | Window lifecycle, background audio support |
| `Core/Services/WebKit/WebKitManager.swift` | Cookie store & persistence |
| `Core/Services/Auth/AuthService.swift` | Login state machine |
| `Core/Services/Player/PlayerService.swift` | Playback state & control |
| `Views/macOS/MiniPlayerWebView.swift` | Singleton WebView, playback UI |
| `Views/macOS/MainWindow.swift` | Main app window |
| `Core/Utilities/DiagnosticsLogger.swift` | Logging |

## Quick Reference

### Build Commands

```bash
# Build
xcodebuild -scheme Kaset -destination 'platform=macOS' build

# Unit Tests (run separately from UI tests)
xcodebuild -scheme Kaset -destination 'platform=macOS' test -only-testing:KasetTests

# Lint & Format
swiftlint --strict && swiftformat .
```

### Test Execution Rules

> ⚠️ **NEVER run unit tests and UI tests together** — Always execute them separately.

**Unit Tests (`KasetTests`)**:
```bash
xcodebuild -scheme Kaset -destination 'platform=macOS' test -only-testing:KasetTests
```

**UI Tests (`KasetUITests`)** — Run ONE test at a time:
```bash
# Run a single UI test
xcodebuild -scheme Kaset -destination 'platform=macOS' test \
  -only-testing:KasetUITests/TestClassName/testMethodName
```

**UI Test Workflow**:
1. Run ONE UI test at a time
2. If it fails, fix the issue before proceeding
3. Verify the fix by re-running that specific test
4. Only move to the next UI test after the current one passes

This prevents cascading failures and makes debugging significantly easier.

### Playback Architecture

```
User clicks Play
    │
    ▼
PlayerService.play(videoId:)
    │
    ├── Sets pendingPlayVideoId
    └── Shows mini player toast (160×90)
            │
            ▼
    SingletonPlayerWebView.shared
            │
            ├── One WebView for entire app
            ├── Loads music.youtube.com/watch?v={id}
            └── JS bridge sends state updates
                    │
                    ▼
            PlayerService updates:
            - isPlaying
            - progress
            - duration
```

### Background Audio

```
Close window (⌘W) → Window hides → Audio continues
Click dock icon    → Window shows → Same WebView
Quit app (⌘Q)     → App terminates → Audio stops
```

### Authentication

```
App Launch → Check cookies → __Secure-3PAPISID exists?
    │                              │
    │ No                           │ Yes
    ▼                              ▼
Show LoginSheet              AuthService.loggedIn
    │
    │ User signs in
    ▼
Observer detects cookie → Dismiss sheet
```

## Performance Checklist

Before completing non-trivial features, verify:

- [ ] No `await` calls inside loops or `ForEach`
- [ ] Lists use `LazyVStack`/`LazyHStack` for large datasets
- [ ] Network calls cancelled on view disappear (`.task` handles this)
- [ ] Parsers have `measure {}` tests if processing large payloads
- [ ] Images use `ImageCache` (not loading inline)
- [ ] Search input is debounced (not firing on every keystroke)

Run performance tests:
```bash
xcodebuild test -scheme Kaset -destination 'platform=macOS' \
  -only-testing:KasetTests/ParserPerformanceTests
```

## Task Planning: Phases with Exit Criteria

For any non-trivial task, **plan in phases with testable exit criteria** before writing code. This ensures incremental progress and early detection of issues.

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
| Read relevant docs | Confirmed patterns in `docs/` apply |

**Exit gate**: Can articulate the implementation plan without ambiguity.

#### Phase 2: Interface Design
| Deliverable | Exit Criteria |
|-------------|---------------|
| Define new types/protocols | Type signatures compile |
| Plan public API surface | No breaking changes to existing callers (or changes identified) |

**Exit gate**: `xcodebuild build` succeeds with stub implementations.

#### Phase 3: Core Implementation
| Deliverable | Exit Criteria |
|-------------|---------------|
| Implement business logic | Unit tests pass for new code |
| Handle error cases | Error paths have test coverage |
| Add logging | `DiagnosticsLogger` calls in place |
| Performance verified | Anti-pattern checklist passed, perf tests added if applicable |

**Exit gate**: `xcodebuild test -only-testing:KasetTests` passes.

#### Phase 4: Quality Assurance
| Deliverable | Exit Criteria |
|-------------|---------------|
| Linting passes | `swiftlint --strict` reports 0 errors |
| Formatting applied | `swiftformat .` makes no changes |
| Full test suite passes | `xcodebuild test` succeeds |

**Exit gate**: CI-equivalent checks pass locally.

### Example: Adding a New Service

```
Phase 1: Research
├── Exit: Understand YTMusicClient pattern, confirm no existing solution

Phase 2: Interface
├── Create NewService.swift with protocol + stub
├── Exit: `xcodebuild build` passes

Phase 3: Implementation
├── Implement methods, add error handling
├── Create NewServiceTests.swift
├── Exit: `xcodebuild test -only-testing:KasetTests/NewServiceTests` passes

Phase 4: QA
├── Run swiftlint, swiftformat
├── Exit: Full test suite passes, no lint errors
```

### Checkpoint Communication

After each phase, briefly report:
- ✅ What was completed
- 🧪 Test/verification results
- ➡️ Next phase plan

This keeps the human informed and provides natural points to course-correct.
