# Contributing to Kaset

Thank you for your interest in contributing! This document provides guidelines and information for developers.

## Getting Started

### Requirements

- macOS 26.0 or later
- Xcode 16.0 or later
- Swift 6.0

### Build & Run

```bash
# Clone the repository
git clone https://github.com/sozercan/kaset.git
cd kaset

# Build from command line
xcodebuild -scheme Kaset -destination 'platform=macOS' build

# Run tests
xcodebuild -scheme Kaset -destination 'platform=macOS' test

# Lint & Format
swiftlint --strict && swiftformat .
```

Or open `Kaset.xcodeproj` in Xcode and press ⌘R.

## Project Structure

```
App/                → App entry point, AppDelegate (window lifecycle)
Core/
  ├── Models/       → Data models (Song, Playlist, Album, Artist, etc.)
  ├── Services/
  │   ├── API/      → YTMusicClient (YouTube Music API calls)
  │   ├── Auth/     → AuthService (login state machine)
  │   ├── Player/   → PlayerService, NowPlayingManager (playback, media keys)
  │   └── WebKit/   → WebKitManager (cookie store, persistent login)
  ├── ViewModels/   → HomeViewModel, LibraryViewModel, SearchViewModel
  └── Utilities/    → DiagnosticsLogger, extensions
Views/
  └── macOS/        → SwiftUI views (MainWindow, Sidebar, PlayerBar, etc.)
Tests/              → Unit tests (KasetTests/)
docs/               → Detailed documentation
```

### Key Files

| File | Purpose |
|------|---------|
| `App/AppDelegate.swift` | Window lifecycle, background audio support |
| `Core/Services/WebKit/WebKitManager.swift` | Cookie store & persistence |
| `Core/Services/Auth/AuthService.swift` | Login state machine |
| `Core/Services/Player/PlayerService.swift` | Playback state & control |
| `Views/macOS/MiniPlayerWebView.swift` | Singleton WebView, playback UI |
| `Views/macOS/MainWindow.swift` | Main app window |
| `Core/Utilities/DiagnosticsLogger.swift` | Logging |

## Architecture

For detailed architecture documentation, see the `docs/` folder:

- **[docs/architecture.md](docs/architecture.md)** — Services, state management, data flow
- **[docs/playback.md](docs/playback.md)** — WebView playback system, background audio
- **[docs/testing.md](docs/testing.md)** — Test commands, patterns, debugging

### High-Level Overview

The app uses a clean architecture with:

- **Observable Pattern**: `@Observable` classes for reactive state management
- **MainActor Isolation**: All UI and service classes are `@MainActor` for thread safety
- **WebKit Integration**: Persistent `WKWebsiteDataStore` for cookie management
- **Swift Concurrency**: `async`/`await` throughout, no `DispatchQueue`

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

### Authentication Flow

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

### Background Audio

```
Close window (⌘W) → Window hides → Audio continues
Click dock icon    → Window shows → Same WebView
Quit app (⌘Q)     → App terminates → Audio stops
```

## Coding Guidelines

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

### Swift Concurrency

- Mark `@Observable` classes with `@MainActor`
- Never use `DispatchQueue` — use `async`/`await`, `MainActor`
- For `@MainActor` test classes, don't call `super.setUp()` in async context:

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

### WebKit Patterns

- Use `WebKitManager`'s shared `WKWebsiteDataStore` for cookie persistence
- Use `SingletonPlayerWebView.shared` for playback (never create multiple WebViews)
- Compute `SAPISIDHASH` fresh per request using current cookies

### Error Handling

- Throw `YTMusicError.authExpired` on HTTP 401/403
- Use `DiagnosticsLogger` for all logging (not `print()`)
- Show user-friendly error messages with retry options

## Pull Request Guidelines

1. **No Third-Party Frameworks** — Do not introduce third-party dependencies without discussion first
2. **Build Must Pass** — Run `xcodebuild -scheme Kaset -destination 'platform=macOS' build`
3. **Tests Must Pass** — Run `xcodebuild -scheme Kaset -destination 'platform=macOS' test`
4. **Linting** — Run `swiftlint --strict && swiftformat .` before submitting
5. **Small PRs** — Keep changes focused and reviewable
6. **Share AI Prompts** — If you used AI assistance, include the prompt in your PR (see below)

## AI-Assisted Contributions & Prompt Requests

We embrace AI-assisted development! Whether you use GitHub Copilot, Claude, Cursor, or other AI tools, we welcome contributions that leverage these capabilities.

### What is a Prompt Request?

A **prompt request** is a contribution where you share the AI prompt that generates code, rather than (or in addition to) the code itself. This approach:

- **Captures intent** — The prompt often explains *why* better than a code diff
- **Enables review before implementation** — Maintainers can validate the approach
- **Supports iteration** — Prompts can be refined before code is generated
- **Improves reproducibility** — Anyone can run the prompt to verify results

### Contributing with AI Assistance

#### Option 1: Traditional PR with AI Prompt Disclosure

Submit code as usual, but include the AI prompt in the PR template's "AI Prompt" section. This helps reviewers understand your approach and intent.

#### Option 2: Prompt Request (Prompt-Only)

Create an issue using the **Prompt Request** template if you:
- Have a well-crafted prompt but haven't run it yet
- Want feedback on your approach before implementation
- Prefer maintainers to run and merge the prompt themselves

### Best Practices for AI Prompts

1. **Be specific** — Include file paths, function names, and concrete requirements
2. **Reference project conventions** — Mention AGENTS.md and relevant patterns
3. **Define acceptance criteria** — How will we know it worked?
4. **Include context** — Link to issues, docs, or examples
5. **Test locally when possible** — Verify the prompt produces working code

### Example Prompt

```
Add haptic feedback to the shuffle button in PlayerBar.swift.

Requirements:
- Use HapticService.toggle() on button tap
- Only trigger haptic on state change (not when already shuffled)
- Follow existing haptic patterns used in volume controls
- Add unit test in PlayerServiceTests.swift

Reference: Core/Services/HapticService.swift for existing patterns
```

## Testing

```bash
# Run all tests
xcodebuild -scheme Kaset -destination 'platform=macOS' test

# Run specific test class
xcodebuild -scheme Kaset -destination 'platform=macOS' \
  test -only-testing:KasetTests/PlayerServiceTests
```

See [docs/testing.md](docs/testing.md) for detailed testing patterns and debugging tips.
