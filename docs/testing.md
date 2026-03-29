# Testing Guide

This document covers testing strategies, commands, and best practices for Kaset.

## Test Commands

### Unit Tests

```bash
swift test
```

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
Tests/KasetTests/
├── Helpers/
│   ├── MockURLProtocol.swift    # Network mocking
│   ├── MockYTMusicClient.swift  # API client mock
│   └── TestFixtures.swift       # Fixture loading utilities
├── SwiftTestingHelpers/
│   └── Tags.swift               # Custom test tags (.api, .parser, etc.)
├── Fixtures/
│   ├── home_response.json       # Sample API responses
│   ├── search_response.json
│   └── playlist_detail.json
├── *Tests.swift                 # Unit test files (Swift Testing)
└── MusicIntentIntegrationTests.swift  # AI integration tests
```

## Unit Test Requirements

New code in `Sources/Kaset/` (Services, Models, ViewModels, Utilities) must include unit tests.

### Creating a Test File

1. Create test file in `Tests/KasetTests/` matching the source file name
   - Example: `YTMusicClient.swift` → `YTMusicClientTests.swift`
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

**Run by tag:**
```bash
# Run only parser tests
xcodebuild test -scheme Kaset -only-testing:KasetTests -skip-testing:KasetUITests \
  2>&1 | grep -E "parser"
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

The project includes a ready-to-use mock client:

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

For stable CI pipelines, **exclude integration tests** and run them separately in a scheduled job:

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
# Run ONLY integration tests (requires Apple Intelligence)
xcodebuild test -scheme Kaset -destination 'platform=macOS' \
  -only-testing:KasetTests/MusicIntentIntegrationTests

# Run all unit tests (integration tests auto-skip if AI unavailable)
xcodebuild test -scheme Kaset -destination 'platform=macOS' \
  -only-testing:KasetTests
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

### Simulating Auth Expiry

To test auth recovery:

1. Open Safari → Develop → Show Web Inspector (for any WebView)
2. Storage → Cookies → Delete `__Secure-3PAPISID`
3. Trigger an API call → should show login sheet

## Debugging

### Console Logging

Use Xcode's Console to filter logs:

```
subsystem:Kaset category:player
subsystem:Kaset category:auth
```

### WebView Debugging

Enable Web Inspector for debug builds:

```swift
#if DEBUG
    webView.isInspectable = true
#endif
```

Right-click WebView → Inspect Element

## Continuous Integration

### GitHub Actions Workflow

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
