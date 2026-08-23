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
swift build

# Run unit tests (do not combine with UI tests)
swift test --skip KasetUITests

# Package and run the app
Scripts/compile_and_run.sh

# If you don't have Apple Development certificates configured,
# use ad-hoc signing instead
KASET_SIGNING=adhoc ./Scripts/compile_and_run.sh

# Lint & Format
swiftlint --strict && swiftformat .
```

Or open `Package.swift` in Xcode to work in the IDE.

## Project Structure

```
Package.swift           → SPM manifest (build configuration)
Sources/
  └── Kaset/            → Main app target
      ├── Models/       → Data models (Song, Playlist, Album, Artist, etc.)
      ├── Services/
      │   ├── API/      → YTMusicClient + YouTubeClient (InnerTube API calls)
      │   ├── Auth/     → AuthService (login state machine)
      │   ├── Player/   → PlayerService, NowPlayingManager (playback, media keys)
      │   └── WebKit/   → WebKitManager (cookie store, persistent login)
      ├── ViewModels/   → Music view models plus YouTube/ video-source view models
      ├── Utilities/    → DiagnosticsLogger, extensions
      └── Views/        → SwiftUI views (MainWindow, Sidebar, PlayerBar, YouTube views, etc.)
  └── APIExplorer/      → API explorer CLI tool
Tests/                  → Unit tests (KasetTests/)
Scripts/                → Build scripts
docs/                   → Detailed documentation
```

### Key Files

| File                                                | Purpose                                    |
| --------------------------------------------------- | ------------------------------------------ |
| `Sources/Kaset/AppDelegate.swift`                   | Window lifecycle, background audio support |
| `Sources/Kaset/Services/WebKit/WebKitManager.swift` | Cookie store & persistence                 |
| `Sources/Kaset/Services/Auth/AuthService.swift`     | Login state machine                        |
| `Sources/Kaset/Services/API/YTMusicClient.swift`    | YouTube Music API client                   |
| `Sources/Kaset/Services/API/YouTubeClient.swift`    | Regular YouTube API client                 |
| `Sources/Kaset/Services/Player/PlayerService.swift` | Playback state & control                   |
| `Sources/Kaset/Services/Player/YouTubePlayerService.swift` | Regular YouTube playback state & control   |
| `Sources/Kaset/Views/MiniPlayerWebView.swift`       | Singleton WebView, playback UI             |
| `Sources/Kaset/Views/YouTube/YouTubeWatchWebView.swift` | Singleton WebView for regular YouTube watch playback |
| `Sources/Kaset/Views/MainWindow.swift`              | Main app window                            |
| `Sources/Kaset/Utilities/DiagnosticsLogger.swift`   | Logging                                    |

## Architecture

For detailed architecture documentation, see the `docs/` folder:

- **[docs/architecture.md](docs/architecture.md)** — Services, state management, data flow
- **[docs/playback.md](docs/playback.md)** — WebView playback system, background audio
- **[docs/youtube.md](docs/youtube.md)** — Regular YouTube source, video playback, Shorts, comments, and parser strategy
- **[docs/testing.md](docs/testing.md)** — Test commands, patterns, debugging

### High-Level Overview

The app uses a clean architecture with:

- **Observable Pattern**: `@Observable` classes for reactive state management
- **MainActor Isolation**: All UI and service classes are `@MainActor` for thread safety
- **Dual Source Model**: YouTube Music and regular YouTube are parallel experiences behind a sidebar source toggle
- **WebKit Integration**: Persistent `WKWebsiteDataStore` for cookie management, authentication, and DRM playback
- **Swift Concurrency**: `async`/`await` throughout, no `DispatchQueue`

### Playback Architecture

Kaset has two playback paths. YouTube Music uses `PlayerService` plus the
`SingletonPlayerWebView` at `music.youtube.com`; regular YouTube uses
`YouTubePlayerService` plus `YouTubeWatchWebView` at `www.youtube.com`.
`PlaybackArbiter` keeps one audio source active at a time and media keys route
to the source that played most recently.

#### YouTube Music

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

#### Regular YouTube

```
User opens a YouTube video
    │
    ▼
YouTubePlayerService.play(video:)
    │
    ├── Sets active video metadata
    ├── Loads www.youtube.com/watch?v={id}
    └── Hosts YouTubeWatchWebView inline or in the floating window
            │
            ▼
    JavaScript bridge sends state, captions, quality, and ad updates
            │
            ▼
    YouTubePlayerService updates playback state and YouTubePlayerBar
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
Close window (⌘W) → Window hides → active playback continues
Click dock icon    → Window shows → same Music/YouTube WebView state
Quit app (⌘Q)     → App terminates → playback stops
```

## Coding Guidelines

### Modern SwiftUI APIs

| ❌ Avoid                          | ✅ Use                                     |
| --------------------------------- | ------------------------------------------ |
| `.foregroundColor()`              | `.foregroundStyle()`                       |
| `.cornerRadius()`                 | `.clipShape(.rect(cornerRadius:))`         |
| `onChange(of:) { newValue in }`   | `onChange(of:) { _, newValue in }`         |
| `Task.sleep(nanoseconds:)`        | `Task.sleep(for: .seconds())`              |
| `NavigationView`                  | `NavigationSplitView` or `NavigationStack` |
| `onTapGesture()`                  | `Button` (unless tap location needed)      |
| `tabItem()`                       | `Tab` API                                  |
| `AnyView`                         | Concrete types or `@ViewBuilder`           |
| `print()`                         | `DiagnosticsLogger`                        |
| `DispatchQueue`                   | Swift concurrency (`async`/`await`)        |
| `String(format: "%.2f", n)`       | `Text(n, format: .number.precision(...))`  |
| Force unwraps (`!`)               | Optional handling or `guard`               |
| Image-only buttons without labels | Add `.accessibilityLabel()`                |

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

### Keyboard Shortcuts

- Preserve standard macOS app/window shortcuts such as `⌘M`, `⌘W`, `⌘Q`, `⌘H`, and `⌘,` unless there is explicit product direction to change them
- Prefer native macOS and Apple Music shortcut conventions for playback actions
- Update `docs/keyboard-shortcuts.md` whenever shortcut behavior changes

### Error Handling

- Throw `YTMusicError.authExpired` on HTTP 401/403
- Use `DiagnosticsLogger` for all logging (not `print()`)
- Show user-friendly error messages with retry options

## Pull Request Guidelines

1. **No Third-Party Frameworks** — Do not introduce third-party dependencies without discussion first
2. **Build Must Pass** — Run `swift build`
3. **Tests Must Pass** — Run `swift test --skip KasetUITests` for unit tests
4. **Linting** — Run `swiftlint --strict && swiftformat .` before submitting
5. **Small PRs** — Keep changes focused and reviewable
6. **Share AI Prompts** — If you used AI assistance, include the prompt in your PR (see below)

## AI-Assisted Contributions & Prompt Requests

We embrace AI-assisted development! Whether you use GitHub Copilot, Claude, Cursor, or other AI tools, we welcome contributions that leverage these capabilities.

### What is a Prompt Request?

A **prompt request** is a contribution where you share the AI prompt that generates code, rather than (or in addition to) the code itself. This approach:

- **Captures intent** — The prompt often explains _why_ better than a code diff
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

Reference: Sources/Kaset/Services/HapticService.swift for existing patterns
```

## Testing

```bash
# Run unit tests
swift test --skip KasetUITests

# Run specific unit test (use --filter)
swift test --skip KasetUITests --filter PlayerServiceTests
```

See [docs/testing.md](docs/testing.md) for detailed testing patterns and debugging tips.
