# Testing Guide

This document covers testing strategies, commands, and best practices for Kaset.

> 🔁 **Default local loop lives in `AGENTS.md`** — Stay CLI-first for everyday verification: `swift build`, `swift test --skip KasetUITests`, then `swiftlint --strict && swiftformat .`. Use Xcode/`xcodebuild` only for UI/runtime debugging, scheme-specific investigation, or CI parity.

## Common Tasks

### Unit Tests

```bash
swift test --skip KasetUITests
```

### Focused YouTube Ask and Localization Tests

```bash
swift test --skip KasetUITests --filter YouTubeAsk
swift test --skip KasetUITests --filter LocalizationCatalogParityTests
```

These are synthetic, non-UI tests. They do not contact YouTube or submit an Ask
suggestion.

### Build Only

```bash
swift build
```

### Package App

```bash
Scripts/build-app.sh
```

### Dev Loop (Build + Run)

```bash
Scripts/compile_and_run.sh
```

### Lint & Format

```bash
swiftlint --strict && swiftformat .
```

## Test Structure

```
Tests/
├── KasetTests/
│   ├── Helpers/
│   │   ├── MockURLProtocol.swift    # Network mocking
│   │   ├── MockYTMusicClient.swift  # YouTube Music API client mock
│   │   ├── MockYouTubeClient.swift  # Regular YouTube API client mock
│   │   └── TestFixtures.swift       # Fixture loading utilities
│   ├── SwiftTestingHelpers/
│   │   └── Tags.swift               # Custom test tags (.api, .parser, etc.)
│   ├── Fixtures/
│   │   ├── home_response.json       # Sample API responses
│   │   ├── search_response.json
│   │   ├── playlist_detail.json
│   │   └── YouTube/                 # Sanitized regular YouTube fixtures
│   ├── YouTubeAskClientTests.swift
│   ├── YouTubeAskViewModelTests.swift
│   ├── *Tests.swift                 # Other app unit tests (Swift Testing)
│   └── MusicIntentIntegrationTests.swift  # Apple Intelligence integration tests
└── YouTubeAskCoreTests/
    ├── Fixtures/                     # Small placeholder-only Ask fixtures
    └── YouTubeAsk*Tests.swift        # Decoder, parser, sanitizer, builder, and fixture safety
```

## Unit Test Requirements

New code in `Sources/Kaset/` (Services, Models, ViewModels, Utilities) must include unit tests.

### Creating a Test File

1. Create test file in `Tests/KasetTests/` matching the source file name
   - Example: `YTMusicClient.swift` → `YTMusicClientTests.swift`
   - Example: `YouTubeClient.swift` / YouTube parsers → `YouTube...Tests.swift`
2. Add the test file to the Xcode project
3. Run tests to verify

### Test File Template (Swift Testing)

> **Note:** This project uses Swift Testing (not XCTest). See [ADR-0006](adr/0006-swift-testing-migration.md) for migration details.

```swift
import Testing
@testable import Kaset

@Suite("MyService", .serialized, .tags(.service))
@MainActor
struct MyServiceTests {
    let sut: MyService
    let mockClient: MockYTMusicClient

    init() {
        mockClient = MockYTMusicClient()
        sut = MyService(client: mockClient)
    }

    @Test("Does something correctly")
    func doesSomething() async throws {
        // Arrange
        mockClient.homeResponse = HomeResponse(sections: [], continuationToken: nil)

        // Act
        let result = try await sut.doSomething()

        // Assert
        #expect(result != nil)
    }
}
```

### Key Swift Testing Patterns

| XCTest | Swift Testing |
|--------|---------------|
| `import XCTest` | `import Testing` |
| `class ... : XCTestCase` | `@Suite struct ...` |
| `func testFoo()` | `@Test func foo()` |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertTrue(x)` | `#expect(x)` |
| `XCTAssertNil(x)` | `#expect(x == nil)` |
| `XCTAssertThrowsError` | `#expect(throws:)` |
| `setUp()` / `tearDown()` | `init()` (ARC handles cleanup) |

### @MainActor Test Suites

For tests of `@MainActor` classes (most services), use `.serialized`:

```swift
@Suite("PlayerService", .serialized, .tags(.service))
@MainActor
struct PlayerServiceTests {
    let sut: PlayerService

    init() {
        sut = PlayerService()
    }

    @Test("Initial state is idle")
    func initialStateIsIdle() {
        #expect(sut.isPlaying == false)
    }
}
```

**Why `.serialized`?** `@MainActor` tests must run serially to avoid race conditions. Swift Testing runs tests in parallel by default.

### Test Tags

Apply tags to categorize tests for filtering:

```swift
@Suite("HomeViewModel", .tags(.viewModel), .timeLimit(.minutes(1)))
```

Available tags: `.api`, `.parser`, `.viewModel`, `.service`, `.model`, `.slow`, `.integration`

Tags are most useful for suite organization and Xcode/CI filtering. For quick local iteration, prefer a name-based filter:

```bash
# Run tests matching a name or suite pattern
swift test --skip KasetUITests --filter Parser
```

If you need Xcode's logs or scheme-specific filtering, escalate to:

```bash
xcodebuild test -scheme Kaset -only-testing:KasetTests -skip-testing:KasetUITests
```

### Time Limits

Add `.timeLimit()` to async tests to prevent hangs:

```swift
@Suite("SearchViewModel", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
```

## Environment Isolation

### Using MockURLProtocol

For network testing without real API calls:

```swift
// In test setup
let config = URLSessionConfiguration.ephemeral
config.protocolClasses = [MockURLProtocol.self]
let session = URLSession(configuration: config)

// Set response handler
MockURLProtocol.requestHandler = { request in
    let json = """
    {"id": "123", "data": [...]}
    """
    let response = HTTPURLResponse(
        url: request.url!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
    )!
    return (response, json.data(using: .utf8)!)
}
```

## Test Categories

### Service Tests

Test business logic in isolation:

```swift
@Test("Login state transitions correctly")
func authServiceLoginState() async {
    let authService = AuthService()

    authService.startLogin()

    #expect(authService.state == .loggingIn)
}
```

### Model Tests

Test parsing and computed properties:

```swift
@Test("Song parses duration from seconds field")
func songDurationParsing() throws {
    let data: [String: Any] = [
        "videoId": "abc123",
        "title": "Test Song",
        "duration_seconds": 185.0,
    ]

    let song = try #require(Song(from: data))

    #expect(song.videoId == "abc123")
    #expect(song.duration == 185.0)
    #expect(song.durationDisplay == "3:05")
}
```

### ViewModel Tests

Test state management and loading:

```swift
@Test("Home loads sections from API")
func homeViewModelLoading() async throws {
    let mockClient = MockYTMusicClient()
    mockClient.homeResponse = HomeResponse(sections: [makeSection()], continuationToken: nil)
    let viewModel = HomeViewModel(client: mockClient)

    await viewModel.load()

    #expect(!viewModel.isLoading)
    #expect(!viewModel.sections.isEmpty)
}
```

### Parser Tests

Test API response parsing with mock data:

```swift
@Test("Parses home response with sections")
func parseHomeResponse() {
    let data = makeHomeResponseData(sectionCount: 3)

    let (sections, token) = HomeResponseParser.parse(data)

    #expect(sections.count == 3)
}
```

### YouTube Ask Tests

YouTube Ask has two test layers:

1. `YouTubeAskCoreTests` proves the Foundation-only boundary: bounded JSON,
   XSSI, NDJSON, and length-prefixed decoding; strict YouChat ancestry and chip
   extraction; decoy and unsupported-decorator rejection; exact
   `onClick.listMutationCommand` user-turn/loading callback acceptance without
   execution and unknown-command rejection; direct-chip preservation when panel
   commands are ambiguous; legacy append-action and current singular
   list-mutation response parsing; server-order preservation; visible-text
   sanitization; native Markdown block parsing with non-interactive links; exact
   direct-chip request bodies;
   and redacted opaque-command behavior.
2. `KasetTests` covers `YouTubeClient` and view-model integration: one shared
   watch `next` request, signed-in primary-account gating, exact `get_panel`
   URL/body, forbidden-field absence, monotonic message IDs, no cache or retry,
   same-origin redirects, HTTP/error mapping, identity-generation fences, a
   single read-only watch retry after internal identity cancellation, no retry
   after outer task cancellation, lazy preparation, single-flight submission,
   transactional New Chat, cancellation, and prevention of command reuse.

Fixtures must be small, hand-authored, and visibly synthetic. Use placeholder
values such as `fixture-video-a` and `fixture-continuation-a`; never copy cookies,
authorization proofs, API keys, account identifiers, personalized payloads, or
real opaque values into source or test output. Fixture safety tests report only
file, JSON path, rule, and value length—never the rejected value.

Run the complete non-UI Ask slice with:

```bash
swift test --skip KasetUITests --filter YouTubeAsk
```

The UI-test fixture may model eligible, ineligible, and error states, but UI tests
launch the app and require explicit human approval before execution.

### Parameterized Tests

Test multiple inputs efficiently:

```swift
@Test("Duration formatting", arguments: [
    (0.0, "0:00"),
    (65.0, "1:05"),
    (3661.0, "1:01:01"),
])
func durationFormatting(seconds: Double, expected: String) {
    let song = makeSong(duration: seconds)
    #expect(song.durationDisplay == expected)
}
```

## Mocking Guidelines

### MockYTMusicClient

The project includes ready-to-use API client mocks for both sources. Use `MockYTMusicClient` for YouTube Music view models and services:

```swift
// Tests/KasetTests/Helpers/MockYTMusicClient.swift
final class MockYTMusicClient: YTMusicClientProtocol, @unchecked Sendable {
    var homeResponse: HomeResponse?
    var searchResponse: SearchResponse?
    var error: Error?

    func getHome() async throws -> HomeResponse {
        if let error { throw error }
        return homeResponse ?? HomeResponse(sections: [], continuationToken: nil)
    }
    // ... other methods
}
```

Use `MockYouTubeClient` for the regular YouTube source:

```swift
// Tests/KasetTests/Helpers/MockYouTubeClient.swift
final class MockYouTubeClient: YouTubeClientProtocol, @unchecked Sendable {
    var homeFeed = YouTubeFeed(videos: [], continuation: nil)
    var searchResponse = YouTubeSearchResponse(videos: [], channels: [], playlists: [], continuation: nil)
    var error: Error?

    func getHomeFeed() async throws -> YouTubeFeed {
        if let error { throw error }
        return homeFeed
    }
    // ... other methods
}
```

Regular YouTube parser tests should use sanitized fixtures in `Tests/KasetTests/Fixtures/YouTube/`; re-capture with `swift run api-explorer --youtube ... -o` when YouTube renderer shapes change. Ask fixtures are different: keep them hand-authored and placeholder-only instead of capturing personalized YouChat responses.

**Usage in tests**:
```swift
func testHomeViewModelLoading() async throws {
    let mockClient = MockYTMusicClient()
    mockClient.homeResponse = HomeResponse(sections: [...], continuationToken: nil)

    let viewModel = HomeViewModel(client: mockClient)
    await viewModel.load()

    XCTAssertFalse(viewModel.sections.isEmpty)
}
```

### MockURLProtocol

For lower-level network testing:

```swift
// Tests/KasetTests/Helpers/MockURLProtocol.swift
MockURLProtocol.requestHandler = { request in
    let data = TestFixtures.loadJSON("home_response")
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, ...)
    return (response, data)
}
```

### TestFixtures

Load JSON fixtures from the `Fixtures/` directory:

```swift
// Tests/KasetTests/Helpers/TestFixtures.swift
let data = TestFixtures.loadJSON("home_response")  // Loads home_response.json
let dict = TestFixtures.loadJSONDict("search_response")
```

### Localization Catalog and Mirrors

`Sources/Kaset/Resources/Localizable.xcstrings` is the source of truth and every
shipped `.lproj/Localizable.strings` mirror must be updated in the same change.
Run:

```bash
swift test --skip KasetUITests --filter LocalizationCatalogParityTests
```

For Ask Gemini, localize only UI-owned chrome, disclosure, progress, error, and
accessibility strings. Server-issued suggestion labels and generated answers are
shown as sanitized verbatim text and must not become localization keys.

## Accessibility Testing

### VoiceOver

Test with VoiceOver enabled:

1. Enable: System Settings → Accessibility → VoiceOver
2. Navigate app using keyboard (Tab, Cmd+arrows)
3. Verify all controls have labels

### Required Labels

All icon-only buttons must have accessibility labels:

```swift
Button {
    playerService.playPause()
} label: {
    Image(systemName: "play.fill")
}
.accessibilityLabel("Play")
```

## Integration Testing

### YouTube Ask Compatibility Validation

YouTube Ask unit tests are deterministic and offline. The API Explorer parity
workflow is a separate, read-only manual compatibility check: it sends `next`
and prepares the prompt-free initial panel, but it must never submit a suggestion
or free-form prompt. Its redacted report records whether strict parsing found a
free-text capability in `next` and in the initial `get_panel` without printing
opaque values. Guarded chip or free-text generation requires separate explicit
approval and is not part of routine tests or CI. Free-text tests cover direct
`next` capability loading, fallback materialization from the same immutable
request snapshot, exact validated `get_panel` bodies, string playback offset,
click-tracking context, per-revision consumption, repeated free-text turns with monotonic message IDs, stale-revision rejection, and no automatic retry.

The production app explicitly selects the fixed WEB request profile. The July 28,
2026 parity run was inconclusive because the exported session appeared signed out;
keep recording all request/response evidence in
[api-discovery.md](api-discovery.md#youtube-ask-gemini--youchat-investigation-2026-07-27)
and keep the activation rule in [ADR-0032](adr/0032-youtube-ask-gemini.md).

### AI Integration Tests (Apple Intelligence)

The `MusicIntentIntegrationTests` suite validates LLM parsing of natural language commands into `MusicIntent` structs.

#### Requirements

- macOS 26+ with Apple Intelligence enabled
- Tests skip gracefully when AI is unavailable via `throw TestSkipped()`

#### Flakiness Mitigation

LLM outputs are inherently non-deterministic. These tests mitigate flakiness by:

1. **Retry logic**: Each test retries up to 3 times before failing (with 500ms delays)
2. **Relaxed matching**: Checks multiple fields (e.g., `mood` OR `query`) for expected content
3. **Case-insensitive**: All string comparisons are lowercased
4. **Fresh sessions**: Each attempt uses a new `LanguageModelSession` to avoid context drift
5. **Tagged for exclusion**: Use `-skip-test-tag integration` in CI to skip these tests

#### Recommended CI Configuration

For stable CI pipelines, **exclude integration tests** and run them separately in a scheduled job. These are CI/Xcode-specific commands; keep day-to-day local verification on the default CLI loop above:

```bash
# CI: Run unit tests only (stable)
xcodebuild test -scheme Kaset -destination 'platform=macOS' \
  -only-testing:KasetTests -skip-test-tag integration

# Scheduled job: Run integration tests (may need re-runs)
xcodebuild test -scheme Kaset -destination 'platform=macOS' \
  -only-testing:KasetTests/MusicIntentIntegrationTests
```

#### What's Tested

| Category         | Test Count | Example Prompts                              |
| ---------------- | ---------- | -------------------------------------------- |
| Basic Actions    | 5          | "Play music", "Skip", "Pause", "Like this"   |
| Mood Queries     | 5          | "Play something chill", "Play upbeat music"  |
| Genre Queries    | 5          | "Play jazz", "Play rock", "Play electronic"  |
| Era Queries      | 4          | "Play 80s hits", "Play 90s top songs"        |
| Artist Queries   | 3          | "Play Beatles", "Play Taylor Swift"          |
| Activity Queries | 4          | "Music for studying", "Workout songs"        |
| Complex Queries  | 3          | "Chill jazz from the 80s", "Acoustic covers" |
| Queue Action     | 1          | "Add jazz to the queue"                      |
| **Total**        | **~30**    |                                              |

#### Run Commands

```bash
# Special-case: run ONLY integration tests (requires Apple Intelligence)
xcodebuild test -scheme Kaset -destination 'platform=macOS' \
  -only-testing:KasetTests/MusicIntentIntegrationTests

# Default local run for the non-UI test suite
swift test --skip KasetUITests
```

#### Test Characteristics

- **Tagged**: `.integration` and `.slow` for easy filtering
- **Auto-skip**: Uses `.enabled(if:)` to skip entire suite when AI unavailable
- **Parameterized**: Efficient coverage with Swift Testing's `arguments:`
- **Retry-enabled**: Up to 3 attempts per test to handle LLM non-determinism
- **Relaxed validation**: Checks multiple fields to accommodate LLM output variance

### Manual Test Checklist

Before releasing:

- [ ] Fresh login works (delete app data first)
- [ ] Home page loads with content
- [ ] Search returns results
- [ ] Playback starts on click
- [ ] Track changes work
- [ ] Background audio works (close window)
- [ ] Media keys work
- [ ] Re-opening window doesn't duplicate audio
- [ ] Sign out and re-login works
- [ ] Ask Gemini remains absent while no request profile has passed parity
- [ ] Eligible YouTube watch pages show a toolbar sparkles action, not an inline card
- [ ] The Ask panel opens lazily and dismisses by outside click and Escape without losing the chat

### Simulating Auth Expiry (Runtime Debugging)

Use this runtime debugging workflow when auth state looks stale or you need to inspect 401/403 recovery behavior:

To test auth recovery:

1. Open Safari → Develop → Show Web Inspector (for any WebView)
2. Storage → Cookies → Delete `__Secure-3PAPISID`
3. Trigger an API call → should show login sheet

## Debugging

### Console Logging

Use Xcode's Console when the CLI loop is not enough and you need runtime inspection:

```
subsystem:Kaset category:player
subsystem:Kaset category:auth
```

### WebView Debugging (Runtime Escalation)

Enable Web Inspector for debug builds when playback or auth issues need DOM or JavaScript inspection:

Enable Web Inspector for debug builds:

```swift
#if DEBUG
    webView.isInspectable = true
#endif
```

Right-click WebView → Inspect Element

## Continuous Integration

### GitHub Actions Workflow

CI can use Xcode-specific commands for macOS runner parity. Keep this separate from the default local CLI loop above.

```yaml
name: Build & Test

on: [push, pull_request]

jobs:
  build:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_26.2.app/Contents/Developer

      - name: Build
        run: xcodebuild -scheme Kaset -destination 'platform=macOS' build

      - name: Test
        run: xcodebuild -scheme Kaset -destination 'platform=macOS' test

      - name: Lint
        run: swiftlint --strict
```
