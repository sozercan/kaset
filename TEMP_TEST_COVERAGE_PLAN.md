# Test Coverage Assessment & Plan

## Current Unit Test Coverage

| **Category** | **Status** | **Coverage Notes** |
|--------------|------------|---------------------|
| **ViewModels** | ⚠️ Partial | `HomeViewModel`, `LibraryViewModel`, `SearchViewModel`, `ExploreViewModel` are tested. Missing: `ChartsViewModel`, `MoodCategoryViewModel`, `MoodsAndGenresViewModel`, `NewReleasesViewModel`, `TopSongsViewModel`, `PlaylistDetailViewModel`, `ArtistDetailViewModel`, `LikedMusicViewModel` |
| **PlayerService** | ✅ Good | Core functionality well tested: state, queue management, play/pause, shuffle/repeat, volume, `playWithRadio`. Missing: `playWithMix`, `fetchMoreMixSongsIfNeeded` (infinite mix), Library actions (`likeCurrentTrack`, `dislikeCurrentTrack`, `toggleLibraryStatus`) |
| **API Parsers** | ⚠️ Partial | `HomeResponseParser`, `PlaylistParser`, `SearchResponseParser`, `SearchSuggestionsParser` have tests. Missing: `RadioQueueParser`, `LyricsParser`, `SongMetadataParser`, `ArtistParser` (only perf test) |
| **Services** | ⚠️ Partial | `AuthService`, `APICache`, `FavoritesManager`, `HapticService`, `WebKitManager`, `RetryPolicy`, `URLHandler` are tested. Missing: `NowPlayingManager`, `SongLikeStatusManager`, `SettingsManager`, `NetworkMonitor`, `ShareService`, `ErrorPresenter`, `UpdaterService`, `NotificationService` |
| **Models** | ✅ Good | Solid coverage via `ModelTests`, `HomeSectionTests`, `LikeStatusTests`, `SearchResponseTests`, `ArtistDetailTests`, `YTMusicErrorTests` |
| **AI Features** | ✅ Good | `FoundationModelsService`, `AIErrorHandler`, `AITools`, `MusicIntents` are tested |
| **Performance** | ✅ Good | `ParserPerformanceTests` covers key parsers |

## Current UI Test Coverage

| **Area** | **Tests Exist** | **Coverage Notes** |
|----------|-----------------|---------------------|
| `AppLaunchUITests` | ✅ | Basic app launch |
| `SidebarUITests` | ✅ | Navigation items |
| `HomeViewUITests` | ✅ | Home view rendering |
| `ExploreViewUITests` | ✅ | Explore view |
| `SearchViewUITests` | ✅ | Search functionality |
| `LibraryViewUITests` | ✅ | Library/playlists |
| `LikedMusicViewUITests` | ✅ | Liked songs |
| `PlayerBarUITests` | ✅ | Controls, persistence |
| **Missing** | ❌ | `QueueView`, `LyricsView`, `ArtistDetailView`, `PlaylistDetailView`, `MoodsAndGenresView`, `ChartsView`, `NewReleasesView`, Settings views |

---

## Priority Recommendations

### High Priority (Add Tests)

- [ ] **`PlayerService+Library` unit tests** — The like/dislike/library toggle logic is critical and currently untested. These methods do optimistic updates + API calls with rollback on failure.

- [ ] **`PlayerService` Mix functionality tests** — The new `playWithMix` and `fetchMoreMixSongsIfNeeded` (infinite mix) are complex features with continuation tokens that need coverage.

- [ ] **`RadioQueueParser` unit tests** — This parser handles both initial and continuation responses. No tests exist and it's used by the new radio/mix features.

- [ ] **Missing ViewModel tests** — `LikedMusicViewModel`, `PlaylistDetailViewModel`, `ArtistDetailViewModel`, `ChartsViewModel` are user-facing and should have basic load/error/refresh tests matching the pattern in `HomeViewModelTests`.

- [ ] **`SongLikeStatusManager` unit tests** — Manages like status caching and API sync with optimistic updates. Easy to test with mocks.

### Medium Priority (Add Tests)

- [ ] **`SettingsManager` unit tests** — UserDefaults persistence logic should be verified, especially launch page handling.

- [ ] **`LyricsParser` and `SongMetadataParser` unit tests** — These parsers are used by playback but have no test coverage.

- [ ] **`ArtistParser` unit tests** — Only has a performance test, needs correctness tests for various artist page structures.

- [ ] **Queue panel UI tests** — `QueueView` tests for reordering, removing songs, and shuffle behavior.

- [ ] **Lyrics panel UI tests** — `LyricsView` visibility toggle and mutual exclusivity with queue.

### Lower Priority (Nice to Have)

- [ ] **`NetworkMonitor`** — Difficult to unit test (system API), but could add basic property tests.

- [ ] **`NowPlayingManager`** — Mostly delegates to `MPRemoteCommandCenter`; limited testability without mocking Apple frameworks.

- [ ] **Settings UI tests** — General/Intelligence settings panels.

- [ ] **`MoodCategoryViewModel`, `MoodsAndGenresViewModel`, `NewReleasesViewModel`, `TopSongsViewModel`** — These follow the same pattern as tested ViewModels, so risk is lower.

---

## Existing Test Files Reference

### Unit Tests (`Tests/KasetTests/`)

```
APICacheTests.swift
AIErrorHandlerTests.swift
AIToolTests.swift
ArtistDetailTests.swift
AuthServiceTests.swift
ExploreViewModelTests.swift
ExtensionsTests.swift
FavoritesManagerTests.swift
FoundationModelsServiceTests.swift
FoundationModelsTests.swift
HapticServiceTests.swift
HomeResponseParserTests.swift
HomeSectionTests.swift
HomeViewModelTests.swift
LibraryViewModelTests.swift
LikeStatusTests.swift
ModelTests.swift
MusicIntentIntegrationTests.swift
MusicIntentTests.swift
ParsingHelpersTests.swift
PlayerServiceTests.swift
PlaylistParserTests.swift
RetryPolicyTests.swift
SearchResponseParserTests.swift
SearchResponseTests.swift
SearchSuggestionsParserTests.swift
SearchViewModelTests.swift
ShareableTests.swift
URLHandlerTests.swift
WebKitManagerTests.swift
YTMusicClientTests.swift
YTMusicErrorTests.swift
PerformanceTests/ParserPerformanceTests.swift
```

### UI Tests (`Tests/KasetUITests/`)

```
AppLaunchUITests.swift
ExploreViewUITests.swift
HomeViewUITests.swift
KasetUITestCase.swift
LibraryViewUITests.swift
LikedMusicViewUITests.swift
PlayerBarUITests.swift
SearchViewUITests.swift
SidebarUITests.swift
```

---

## Test Patterns to Follow

### Unit Tests (Swift Testing)

```swift
import Foundation
import Testing
@testable import Kaset

@Suite("FeatureName", .serialized, .tags(.viewModel), .timeLimit(.minutes(1)))
@MainActor
struct FeatureNameTests {
    var mockClient: MockYTMusicClient
    var viewModel: FeatureViewModel

    init() {
        self.mockClient = MockYTMusicClient()
        self.viewModel = FeatureViewModel(client: self.mockClient)
    }

    @Test("Initial state is idle")
    func initialState() {
        #expect(self.viewModel.loadingState == .idle)
    }

    @Test("Load success sets data")
    func loadSuccess() async {
        // Setup mock
        self.mockClient.someResponse = TestFixtures.makeSomeData()
        
        await self.viewModel.load()
        
        #expect(self.viewModel.loadingState == .loaded)
    }

    @Test("Load error sets error state")
    func loadError() async {
        self.mockClient.shouldThrowError = YTMusicError.networkError(underlying: URLError(.notConnectedToInternet))
        
        await self.viewModel.load()
        
        if case .error = self.viewModel.loadingState {
            // Expected
        } else {
            Issue.record("Expected error state")
        }
    }
}
```

### Performance Tests (XCTest)

```swift
import XCTest
@testable import Kaset

final class SomeParserPerformanceTests: XCTestCase {
    func testParsingPerformance() {
        let data = makeTestData(count: 100)
        
        measure {
            _ = SomeParser.parse(data)
        }
    }
}
```

---

## Notes

- Use `MockYTMusicClient` for API mocking (already comprehensive)
- Use `TestFixtures` for creating test data
- Performance tests should remain in XCTest (for `measure {}` blocks)
- UI tests require user permission before running (per AGENTS.md)
