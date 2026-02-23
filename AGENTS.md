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

- **[docs/architecture.md](docs/architecture.md)** — Services, state management, data flow, Liquid Glass patterns, performance guidelines
- **[docs/playback.md](docs/playback.md)** — WebView playback system, background audio, WebKit patterns
- **[docs/testing.md](docs/testing.md)** — Test commands, patterns, Swift Testing guide
- **[docs/common-bug-patterns.md](docs/common-bug-patterns.md)** — Anti-patterns that have caused bugs (concurrency, SwiftUI, WebKit)
- **[docs/task-planning.md](docs/task-planning.md)** — Phase-based planning with exit criteria
- **[docs/adr/](docs/adr/)** — Architecture Decision Records (ADRs)

## Before You Start

1. **Understand the playback architecture** — See [docs/playback.md](docs/playback.md)
2. **Check ADRs for past decisions** — See [docs/adr/](docs/adr/) before proposing architectural changes
3. **Read the bug patterns** — See [docs/common-bug-patterns.md](docs/common-bug-patterns.md) before writing or reviewing code
4. **Consult API documentation before implementing API features** — See [docs/api-discovery.md](docs/api-discovery.md) for endpoint reference

### API Discovery Workflow

> ⚠️ **MANDATORY**: Before implementing ANY feature that requires a new or modified API call, you MUST explore the endpoint first using `./Tools/api-explorer.swift`. Do NOT guess or assume API response structures. See [docs/api-discovery.md](docs/api-discovery.md) for full workflow, auth setup, and endpoint reference.

Quick start:
```bash
./Tools/api-explorer.swift auth          # Check auth status
./Tools/api-explorer.swift list          # List known endpoints
./Tools/api-explorer.swift browse FEmusic_home -v  # Explore with verbose output
```

## Critical Rules

> 🚨 **NEVER leak secrets, cookies, API keys, or tokens** — Under NO circumstances include real cookies, authentication tokens, API keys, SAPISID values, or any sensitive credentials in code, comments, logs, documentation, test fixtures, or any output. Always use placeholder values like `"REDACTED"`, `"mock-token"`, or `"test-cookie"` in examples and tests. This applies to all files including tests, docs, and ADRs. **Violation of this rule is a critical security incident.**

> ⚠️ **ALWAYS confirm before running UI tests** — UI tests launch the app and can be disruptive. Ask the human for permission before executing any UI test.

> ⚠️ **No Third-Party Frameworks** — Do not introduce third-party dependencies without asking first.

> ⚠️ **Prefer API over WebView** — Always use `YTMusicClient` API calls when functionality exists. Only use WebView for playback (DRM-protected audio) and authentication.

> 📝 **Document Architectural Decisions** — For significant design changes, create an ADR in `docs/adr/` following the format in [docs/adr/README.md](docs/adr/README.md).

> 🤖 **Document Your Prompts** — When completing a task, summarize the key prompt(s) used so the human can include them in the PR. See [CONTRIBUTING.md](CONTRIBUTING.md#ai-assisted-contributions--prompt-requests).

> ⚡ **Performance Awareness** — For non-trivial features, run performance tests and verify no anti-patterns. When adding parsers or API calls, include `measure {}` tests.

> 🔧 **Improve API Explorer, Don't Write One-Off Scripts** — When exploring or debugging API-related functionality, **always enhance `Tools/api-explorer.swift`** instead of writing temporary scripts.

## Build & Code Quality

```bash
# Build
xcodebuild -scheme Kaset -destination 'platform=macOS' build

# Unit Tests (never combine with UI tests)
xcodebuild -scheme Kaset -destination 'platform=macOS' test -only-testing:KasetTests

# Lint & Format
swiftlint --strict && swiftformat .
```

> ⚠️ **SwiftFormat `--self insert` rule**: The project uses `--self insert` in `.swiftformat`. This means:
> - In static methods, call other static methods with `Self.methodName()` (not bare `methodName()`)
> - In instance methods, use `self.property` explicitly
>
> Always run `swiftformat .` before completing work to auto-fix these issues.

## Coding Standards

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

### Swift Concurrency

- Mark `@Observable` classes with `@MainActor`
- Never use `DispatchQueue` — use `async`/`await`, `MainActor`
- See [docs/common-bug-patterns.md](docs/common-bug-patterns.md) for concurrency anti-patterns

### Liquid Glass UI (macOS 26+)

> See [docs/architecture.md#ui-design-macos-26](docs/architecture.md#ui-design-macos-26) for detailed patterns.

### Swift Testing

> ✅ Use Swift Testing for all new unit tests. See [docs/testing.md](docs/testing.md) and [ADR-0006](docs/adr/0006-swift-testing-migration.md).

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

## Architecture Overview

> See [docs/architecture.md](docs/architecture.md) and [docs/playback.md](docs/playback.md) for detailed flows.

**Key Concepts**:
- **Singleton WebView** for playback (DRM requires WebKit)
- **Background audio** via `windowShouldClose` returning `false` (hides instead of closes)
- **Cookie-based auth** with `__Secure-3PAPISID` extracted from WebView
- **API-first** — use `YTMusicClient` for data, WebView only for playback/auth

## Checklists

### Performance

> See [docs/architecture.md#performance-guidelines](docs/architecture.md#performance-guidelines) for detailed patterns.

- [ ] No `await` calls inside loops or `ForEach`
- [ ] Lists use `LazyVStack`/`LazyHStack` for large datasets
- [ ] Network calls cancelled on view disappear (`.task` handles this)
- [ ] Parsers have `measure {}` tests if processing large payloads
- [ ] Images use `ImageCache` with appropriate `targetSize`
- [ ] Search input is debounced
- [ ] ForEach uses stable identity

### Concurrency Safety

> See [docs/common-bug-patterns.md](docs/common-bug-patterns.md) for detailed examples.

- [ ] No fire-and-forget `Task { }` without error handling
- [ ] Optimistic updates handle `CancellationError` explicitly
- [ ] Background tasks cancelled in `deinit`
- [ ] Using `.task` instead of `.onAppear { Task { } }`
- [ ] Continuation tokens scoped per-request (not shared across types)
- [ ] No `static var shared` pattern with mutable assignment in `init`
- [ ] WebView message handlers removed in `dismantleNSView`
- [ ] `WKNavigationDelegate` implements `webViewWebContentProcessDidTerminate`

## Task Planning

> ⚠️ **Never implement without an approved plan.** See [docs/task-planning.md](docs/task-planning.md) for the full phase-based workflow with exit criteria.

For non-trivial tasks: **Research → Plan → Get approval → Implement → QA**. Write research findings to a persistent file. Run `xcodebuild build` continuously during implementation. Mark progress as you go. If things go wrong, revert and re-scope rather than patching.