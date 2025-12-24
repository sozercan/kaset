# ADR-0006: Migration from XCTest to Swift Testing

## Status

Accepted

## Context

The project currently uses XCTest for all unit and UI tests. Swift Testing (introduced in Swift 5.10 / Xcode 16) offers a more modern, expressive testing framework with:

- **Cleaner syntax**: `@Test` and `@Suite` macros instead of method-name conventions
- **Parameterized tests**: Built-in support via `@Test(arguments:)`
- **Tags for organization**: `@Test(.tags(.slow, .api))` for test categorization
- **Better async support**: First-class async/await integration
- **Richer assertions**: `#expect()` and `#require()` with better diagnostics
- **Parallel by default**: Tests run concurrently unless serialized

## Decision

Migrate from XCTest to Swift Testing in phases, allowing incremental adoption while maintaining test stability.

## Prerequisites

- **Xcode 16+** required for Swift Testing support
- **CI/CD**: Ensure build agents run Xcode 16+ or tests won't be discovered

## Key Differences to Account For

### Teardown Limitations

XCTest supports `tearDown() async throws` for async cleanup. Swift Testing uses `deinit`, which **cannot be async**.

**Mitigation strategies:**
1. For simple nil assignments → Let ARC handle cleanup (no action needed)
2. For async cleanup → Use `defer { await cleanup() }` inside the test body
3. For shared resources → Use `addTeardownBlock` in XCTest interop or redesign

**Our current tests**: All `tearDown` methods just set variables to `nil`. Safe to migrate.

### Mock State Isolation

Swift Testing runs tests in parallel by default. Mocks with `static var` state will cause race conditions.

**Verification**: `MockYTMusicClient`, `MockWebKitManager` use instance properties only. ✅ Safe.

**Rule**: Never add `static var` to mocks. Use instance properties or pass state via `init()`.

## Migration Plan

### Phase 1: Infrastructure Setup

**Deliverables:**
- Create Swift Testing configuration
- Verify test target settings support both frameworks

**Files to create:**
- `Tests/KasetTests/SwiftTestingHelpers/Tags.swift` — Define custom test tags

**Note**: Custom `Traits.swift` deferred until we need behaviors like "requires network" or "flaky test handling".

**Exit criteria:**
- Project builds with `import Testing`
- Can run both XCTest and Swift Testing tests together
- `xcodebuild test` discovers tests from both frameworks

---

### Phase 2: Migrate Helper Files

**Files to verify (no changes expected):**
| File | Status |
|------|--------|
| `Helpers/TestFixtures.swift` | ✅ Pure factory methods, works with both |
| `Helpers/MockYTMusicClient.swift` | ✅ Instance properties only, no static state |
| `Helpers/MockWebKitManager.swift` | ✅ Instance properties only |
| `Helpers/MockURLProtocol.swift` | ✅ Works with both |

**Exit criteria:**
- All helpers work with both XCTest and Swift Testing
- No `static var` in any mock (verified)

---

### Phase 3: Migrate Simple Model Tests

**Priority:** Start with tests that have no setup/teardown requirements.

**Pre-migration cleanup:**
1. **Split `KasetTests.swift`** before migration:
   - Move `testSongDurationParsing`, `testSongDurationDisplayWithNoDuration` → `ModelTests.swift`
   - Move `testYTMusicErrorDescriptions` → `YTMusicErrorTests.swift`
   - Move `testTimeIntervalFormattedDuration` → `ExtensionsTests.swift`
   - Move `testSearchResponseEmpty`, `testHomeResponseEmpty` → `SearchResponseTests.swift`
   - Delete `testAppConfiguration` (tests `Bundle.main` which is unreliable in test targets)
   - Delete `KasetTests.swift` once empty

**Assertion mapping:**
| XCTest | Swift Testing |
|--------|---------------|
| `XCTestCase` class | `@Suite` struct |
| `func test...()` | `@Test func ...()` |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertTrue(x)` | `#expect(x)` |
| `XCTAssertFalse(x)` | `#expect(!x)` |
| `XCTAssertNil(x)` | `#expect(x == nil)` |
| `XCTAssertNotNil(x)` | `#expect(x != nil)` or `try #require(x)` |
| `XCTFail("message")` | `Issue.record("message")` |
| `XCTAssertThrowsError` | `#expect(throws:)` or `#expect { try ... } throws: { ... }` |

**Files to migrate (in order):**
1. `ModelTests.swift` — Simple struct/enum tests
2. `YTMusicErrorTests.swift` — Error enum tests
3. `LikeStatusTests.swift` — Simple enum tests
4. `HomeSectionTests.swift` — Model tests
5. `ExtensionsTests.swift` — Extension tests
6. `RetryPolicyTests.swift` — Simple logic tests

**Example migration:**

```swift
// BEFORE (XCTest)
import XCTest
@testable import Kaset

final class LikeStatusTests: XCTestCase {
    func testRawValues() {
        XCTAssertEqual(LikeStatus.liked.rawValue, "LIKE")
        XCTAssertEqual(LikeStatus.disliked.rawValue, "DISLIKE")
        XCTAssertEqual(LikeStatus.indifferent.rawValue, "INDIFFERENT")
    }
}

// AFTER (Swift Testing)
import Testing
@testable import Kaset

@Suite("LikeStatus")
struct LikeStatusTests {
    @Test("Raw values are correct")
    func rawValues() {
        #expect(LikeStatus.liked.rawValue == "LIKE")
        #expect(LikeStatus.disliked.rawValue == "DISLIKE")
        #expect(LikeStatus.indifferent.rawValue == "INDIFFERENT")
    }
    
    // With parameterized tests
    @Test("All statuses have non-empty raw values", arguments: LikeStatus.allCases)
    func allStatusesHaveRawValues(status: LikeStatus) {
        #expect(!status.rawValue.isEmpty)
    }
}
```

**Exit criteria:**
- All simple model tests pass with Swift Testing
- No XCTest assertions remain in migrated files

---

### Phase 4: Migrate Parser Tests

**Files to migrate:**
1. `ParsingHelpersTests.swift`
2. `HomeResponseParserTests.swift`
3. `SearchResponseParserTests.swift`
4. `SearchSuggestionsParserTests.swift`
5. `PlaylistParserTests.swift`

**Leverage parameterized tests** for parsers with multiple input cases:

```swift
// BEFORE (XCTest with loop)
final class HomeResponseParserTests: XCTestCase {
    func testParseVariousInputs() {
        let testCases = [
            ("empty", [:], 0),
            ("single", makeSingleSection(), 1),
            ("multiple", makeMultipleSections(), 3),
        ]
        for (name, input, expected) in testCases {
            let result = HomeResponseParser.parse(input)
            XCTAssertEqual(result.sections.count, expected, "Failed for \(name)")
        }
    }
}

// AFTER (Swift Testing with parameterized test)
@Suite("HomeResponseParser")
struct HomeResponseParserTests {
    @Test("Parse various inputs", arguments: [
        ("empty", [:] as [String: Any], 0),
        ("single", makeSingleSection(), 1),
        ("multiple", makeMultipleSections(), 3),
    ])
    func parseVariousInputs(name: String, input: [String: Any], expected: Int) {
        let result = HomeResponseParser.parse(input)
        #expect(result.sections.count == expected, "Failed for \(name)")
    }
}
```

**Benefits**: Each argument set runs as a separate test case with individual pass/fail reporting.

**Exit criteria:**
- All parser tests pass
- JSON fixture loading works correctly
- Parameterized tests used where applicable

---

### Phase 5: Migrate Service Tests with Mocks

**Files to migrate:**
1. `AuthServiceTests.swift`
2. `PlayerServiceTests.swift`
3. `ErrorPresenterTests.swift`
4. `WebKitManagerTests.swift`
5. `YTMusicClientTests.swift`
6. `APICacheTests.swift`

**Pattern for `@MainActor` tests with setup:**

```swift
// BEFORE (XCTest)
@MainActor
final class AuthServiceTests: XCTestCase {
    var authService: AuthService!
    var mockWebKitManager: MockWebKitManager!

    override func setUp() async throws {
        mockWebKitManager = MockWebKitManager()
        authService = AuthService(webKitManager: mockWebKitManager)
    }

    override func tearDown() async throws {
        authService = nil  // Just nil assignment - ARC handles this
        mockWebKitManager = nil
    }

    func testInitialState() {
        XCTAssertEqual(authService.state, .initializing)
    }
}

// AFTER (Swift Testing)
@Suite("AuthService", .serialized)
@MainActor
struct AuthServiceTests {
    let authService: AuthService
    let mockWebKitManager: MockWebKitManager
    
    init() {
        mockWebKitManager = MockWebKitManager()
        authService = AuthService(webKitManager: mockWebKitManager)
    }
    // No tearDown needed - ARC cleans up when struct is deallocated
    
    @Test("Initial state is initializing")
    func initialState() {
        #expect(authService.state == .initializing)
    }
}
```

**Key migration notes:**
- Use `init()` instead of `setUp()` — Swift Testing creates new instance per test
- Add `.serialized` trait for `@MainActor` suites to prevent race conditions
- No `tearDown()` needed — ARC handles cleanup automatically
- Our current teardown methods only set vars to `nil`, so migration is safe

**For tests requiring async cleanup (not currently needed, but for reference):**

```swift
@Test("Test with async cleanup")
func testWithAsyncCleanup() async {
    let resource = await createResource()
    defer { Task { await resource.cleanup() } }  // Fire-and-forget cleanup
    
    // ... test logic
}
```

**Exit criteria:**
- All service tests pass
- Mock verification works correctly
- `@MainActor` tests run without concurrency issues
- No flaky tests from parallel execution

---

### Phase 6: Migrate ViewModel Tests

**Files to migrate:**
1. `HomeViewModelTests.swift`
2. `SearchViewModelTests.swift`
3. `LibraryViewModelTests.swift`
4. `ExploreViewModelTests.swift`
5. `ArtistDetailTests.swift`
6. `SearchResponseTests.swift`

**Pattern for async tests:**

```swift
// BEFORE
@MainActor
final class HomeViewModelTests: XCTestCase {
    func testLoadSuccess() async {
        mockClient.homeResponse = TestFixtures.makeHomeResponse()
        await viewModel.load()
        XCTAssertEqual(viewModel.loadingState, .loaded)
    }
}

// AFTER
@Suite("HomeViewModel", .serialized)
@MainActor
struct HomeViewModelTests {
    let mockClient: MockYTMusicClient
    let viewModel: HomeViewModel
    
    init() {
        mockClient = MockYTMusicClient()
        viewModel = HomeViewModel(client: mockClient)
    }
    
    @Test("Load success updates state to loaded")
    func loadSuccess() async {
        mockClient.homeResponse = TestFixtures.makeHomeResponse()
        await viewModel.load()
        #expect(viewModel.loadingState == .loaded)
    }
}
```

**Exit criteria:**
- All ViewModel tests pass
- Async/await works correctly
- State verification is accurate

---

### Phase 7: Migrate Performance Tests

**File:** `PerformanceTests/ParserPerformanceTests.swift`

**Note:** Swift Testing does not have built-in `measure {}` blocks. Options:

1. **Keep in XCTest** — Performance tests can remain as XCTest
2. **Use manual timing** — Measure with `ContinuousClock`
3. **Use XCTest interop** — Import XCTest alongside Testing

**Recommended approach:** Keep performance tests in XCTest for now.

```swift
// Keep as XCTest — performance measurement not yet in Swift Testing
import XCTest
@testable import Kaset

final class ParserPerformanceTests: XCTestCase {
    func testHomeParsingPerformance() {
        let data = makeHomeResponseData(sectionCount: 10, itemsPerSection: 20)
        measure {
            _ = HomeResponseParser.parse(data)
        }
    }
}
```

**Exit criteria:**
- Performance tests still run and measure correctly
- Decision documented on whether to migrate later

---

### Phase 8: Migrate UI Tests (Future)

**Files in `KasetUITests/`:**
- `KasetUITestCase.swift` (base class)
- `AppLaunchUITests.swift`
- `HomeViewUITests.swift`
- `SearchViewUITests.swift`
- `LibraryViewUITests.swift`
- `SidebarUITests.swift`
- `PlayerBarUITests.swift`
- `LikedMusicViewUITests.swift`
- `ExploreViewUITests.swift`

**Status:** UI testing with Swift Testing is still maturing. Recommend keeping UI tests in XCTest until Xcode provides better XCUI integration with Swift Testing.

**Future migration pattern (when ready):**

```swift
// UI tests will likely stay XCTest-based for XCUIApplication
import XCTest

final class HomeViewUITests: XCTestCase {
    // Keep as XCTest for XCUIApplication support
}
```

**Exit criteria:**
- Document decision to defer UI test migration
- UI tests continue to work with XCTest

---

## File-by-File Migration Checklist

### Pre-Migration Cleanup

| Task | Status |
|------|--------|
| Split `KasetTests.swift` into proper test files | ✅ Done |
| Delete `KasetTests.swift` after split | ✅ Done |
| Verify no mocks use `static var` | ✅ Done |

### Unit Tests (`KasetTests/`)

| File | Phase | Complexity | Status |
|------|-------|------------|--------|
| `ModelTests.swift` | 3 | Low | ✅ Done |
| `YTMusicErrorTests.swift` | 3 | Low | ✅ Done |
| `LikeStatusTests.swift` | 3 | Low | ✅ Done |
| `HomeSectionTests.swift` | 3 | Low | ✅ Done |
| `ExtensionsTests.swift` | 3 | Low | ✅ Done |
| `RetryPolicyTests.swift` | 3 | Low | ✅ Done |
| `ParsingHelpersTests.swift` | 4 | Medium | ✅ Done |
| `HomeResponseParserTests.swift` | 4 | Medium | ✅ Done |
| `SearchResponseParserTests.swift` | 4 | Medium | ✅ Done |
| `SearchSuggestionsParserTests.swift` | 4 | Medium | ✅ Done |
| `PlaylistParserTests.swift` | 4 | Medium | ✅ Done |
| `AuthServiceTests.swift` | 5 | Medium | ✅ Done |
| `PlayerServiceTests.swift` | 5 | High | ✅ Done |
| `ErrorPresenterTests.swift` | 5 | Medium | ✅ Done |
| `WebKitManagerTests.swift` | 5 | Medium | ✅ Done |
| `YTMusicClientTests.swift` | 5 | High | ✅ Done |
| `APICacheTests.swift` | 5 | Medium | ✅ Done |
| `HomeViewModelTests.swift` | 6 | Medium | ✅ Done |
| `SearchViewModelTests.swift` | 6 | Medium | ✅ Done |
| `LibraryViewModelTests.swift` | 6 | Medium | ✅ Done |
| `ExploreViewModelTests.swift` | 6 | Medium | ✅ Done |
| `ArtistDetailTests.swift` | 6 | Medium | ✅ Done |
| `SearchResponseTests.swift` | 6 | Low | ✅ Done |
| `FoundationModelsTests.swift` | 6 | Medium | ✅ Done |
| `PerformanceTests/ParserPerformanceTests.swift` | 7 | **Keep XCTest** | ✅ Verified |

### UI Tests (`KasetUITests/`)

| File | Status |
|------|--------|
| All UI tests | ⬜ **Defer** (keep XCTest) |

---

## Assertion Mapping Reference

| XCTest | Swift Testing |
|--------|---------------|
| `XCTAssert(x)` | `#expect(x)` |
| `XCTAssertTrue(x)` | `#expect(x)` or `#expect(x == true)` |
| `XCTAssertFalse(x)` | `#expect(!x)` or `#expect(x == false)` |
| `XCTAssertEqual(a, b)` | `#expect(a == b)` |
| `XCTAssertNotEqual(a, b)` | `#expect(a != b)` |
| `XCTAssertNil(x)` | `#expect(x == nil)` |
| `XCTAssertNotNil(x)` | `#expect(x != nil)` or `let x = try #require(x)` |
| `XCTAssertGreaterThan(a, b)` | `#expect(a > b)` |
| `XCTAssertLessThan(a, b)` | `#expect(a < b)` |
| `XCTAssertThrowsError(try x)` | `#expect(throws: Error.self) { try x }` |
| `XCTAssertNoThrow(try x)` | `#expect(throws: Never.self) { try x }` |
| `XCTFail("message")` | `Issue.record("message")` |
| `XCTUnwrap(x)` | `try #require(x)` |

---

## Setup/Teardown Mapping

| XCTest | Swift Testing | Notes |
|--------|---------------|-------|
| `override func setUp()` | `init()` | New instance per test |
| `override func setUp() async throws` | `init() async throws` | Async init supported |
| `override func tearDown()` | Not needed | ARC handles cleanup |
| `override func tearDown() async throws` | `defer { }` in test body | **No async deinit** |
| `override func setUpWithError() throws` | `init() throws` | Throwing init |
| `override class func setUp()` | Static property with initializer | One-time setup |

### Async Teardown Workaround

If you need async cleanup (we currently don't, but for future reference):

```swift
@Test("Test requiring async cleanup")
func testWithAsyncCleanup() async throws {
    let resource = try await createResource()
    
    // Option 1: Fire-and-forget (if cleanup failure is non-critical)
    defer { Task { await resource.cleanup() } }
    
    // Option 2: Synchronous cleanup wrapper (if cleanup must complete)
    defer { 
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await resource.cleanup()
            semaphore.signal()
        }
        semaphore.wait()
    }
    
    // Test logic here
}
```

---

## Test Organization with Tags

Define custom tags for categorization:

```swift
// Tests/KasetTests/SwiftTestingHelpers/Tags.swift
import Testing

extension Tag {
    @Tag static var api: Self
    @Tag static var parser: Self
    @Tag static var viewModel: Self
    @Tag static var service: Self
    @Tag static var model: Self
    @Tag static var slow: Self
    @Tag static var integration: Self
}
```

Usage:

```swift
@Test("API returns valid response", .tags(.api, .slow))
func apiReturnsValidResponse() async throws {
    // ...
}
```

Run filtered tests:

```bash
# Run only API tests
swift test --filter .api

# Exclude slow tests
swift test --skip .slow
```

---

## Build Commands After Migration

```bash
# Run all tests (both XCTest and Swift Testing)
xcodebuild -scheme Kaset -destination 'platform=macOS' test

# Run only unit tests (excludes UI tests)
xcodebuild -scheme Kaset -destination 'platform=macOS' test -only-testing:KasetTests

# Run specific Swift Testing suite
swift test --filter HomeViewModelTests

# Run tests with specific tag (after Tags.swift is created)
swift test --filter .api
```

**CI/CD Note**: Ensure build agents use **Xcode 16+**. Earlier versions will not discover Swift Testing tests.

---

## Consequences

### Positive

- Cleaner, more readable test code
- Better async/await support without XCTest quirks
- Parameterized tests reduce duplication and improve reporting
- Tags enable flexible test filtering
- Structs are more lightweight than classes
- Parallel execution by default improves test speed

### Negative

- Learning curve for team
- Performance testing stays in XCTest (no `measure {}` equivalent)
- UI tests remain in XCTest (XCUIApplication integration)
- No async `deinit` for cleanup (requires workarounds)

### Neutral

- Both frameworks coexist during migration
- Incremental migration is fully supported
- Test count and coverage remain the same

---

## Immediate Next Steps

1. **Create `Tags.swift`** in `Tests/KasetTests/SwiftTestingHelpers/`
2. **Split `KasetTests.swift`** into proper test files
3. **Migrate `LikeStatusTests.swift`** as the pilot (simplest file)
4. **Verify both frameworks run together**: `xcodebuild test -only-testing:KasetTests`

---

## References

- [Swift Testing Documentation](https://developer.apple.com/documentation/testing)
- [Migrating from XCTest](https://developer.apple.com/documentation/testing/migratingfromxctest)
- [WWDC24: Meet Swift Testing](https://developer.apple.com/videos/play/wwdc2024/10179/)
- [WWDC24: Go further with Swift Testing](https://developer.apple.com/videos/play/wwdc2024/10195/)
