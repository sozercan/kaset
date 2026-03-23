# AGENTS.md

Guidance for AI coding assistants working on this repository.

## Role

You are a Senior Swift Engineer specializing in SwiftUI, Swift Concurrency, and macOS development. Your code must adhere to Apple's Human Interface Guidelines. Target **Swift 6.0+** and **macOS 26.0+**.

Kaset is a native macOS YouTube Music client (Swift/SwiftUI) using a hidden WebView for DRM playback and `YTMusicClient` API calls for all data fetching.

## Critical Rules

> 🚨 **NEVER leak secrets, cookies, API keys, or tokens** — Under NO circumstances include real cookies, authentication tokens, API keys, SAPISID values, or any sensitive credentials in code, comments, logs, documentation, test fixtures, or any output. Always use placeholder values like `"REDACTED"`, `"mock-token"`, or `"test-cookie"`. **Violation of this rule is a critical security incident.**

> ⚠️ **ALWAYS confirm before running UI tests** — UI tests launch the app and can be disruptive. Ask the human for permission before executing any UI test.

> ⚠️ **No Third-Party Frameworks** — Do not introduce third-party dependencies without asking first.

> ⚠️ **Prefer API over WebView** — Always use `YTMusicClient` API calls when functionality exists. Only use WebView for playback (DRM-protected audio) and authentication.

> 🔧 **Improve API Explorer, Don't Write One-Off Scripts** — When exploring or debugging API-related functionality, **always enhance `Sources/APIExplorer/main.swift`** instead of writing temporary scripts.

> 📝 **Document Architectural Decisions** — For significant design changes, create an ADR in `docs/adr/`.

> ⌨️ **Preserve Standard macOS Shortcuts** — Do not override standard app/window shortcuts such as `⌘M`, `⌘W`, `⌘Q`, `⌘H`, or `⌘,` unless the human explicitly asks for it. When adding media shortcuts, prefer native macOS and Apple Music conventions, and update `docs/keyboard-shortcuts.md`.

## Build & Code Quality

```bash
# Build
swift build

# Unit Tests (never combine with UI tests)
swift test --skip KasetUITests

# Lint & Format
swiftlint --strict && swiftformat .
```

> ⚠️ **SwiftFormat `--self insert` rule**: The project uses `--self insert` in `.swiftformat`. This means:
> - In static methods, call other static methods with `Self.methodName()` (not bare `methodName()`)
> - In instance methods, use `self.property` explicitly
>
> Always run `swiftformat .` before completing work to auto-fix these issues.

## API Discovery

> ⚠️ **MANDATORY**: Before implementing ANY feature that requires a new or modified API call, you MUST explore the endpoint first using `swift run api-explorer`. Do NOT guess or assume API response structures.

```bash
swift run api-explorer auth          # Check auth status
swift run api-explorer list          # List known endpoints
swift run api-explorer browse FEmusic_home -v  # Explore with verbose output
```

## Coding Rules

These are project-specific rules that differ from standard Swift/SwiftUI conventions:

| ❌ Avoid | ✅ Use | Why |
|----------|--------|-----|
| `print()` | `DiagnosticsLogger` | Project-specific logging |
| `.background(.ultraThinMaterial)` | `.glassEffect()` | macOS 26+ Liquid Glass |
| `DispatchQueue` | Swift concurrency (`async`/`await`) | Strict concurrency policy |
| Force unwraps (`!`) | Optional handling or `guard` | Project policy |

- Mark `@Observable` classes with `@MainActor`
- Use Swift Testing (`@Test`, `#expect`) for all new unit tests
- Throw `YTMusicError.authExpired` on HTTP 401/403
- Use `.task` instead of `.onAppear { Task { } }`
- See `docs/common-bug-patterns.md` for concurrency anti-patterns and pre-submit checklists

## Task Planning

For non-trivial tasks: **Research → Plan → Get approval → Implement → QA**. Run `swift build` continuously during implementation. If things go wrong, revert and re-scope rather than patching.
