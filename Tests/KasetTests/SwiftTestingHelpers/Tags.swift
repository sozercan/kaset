import Testing

// MARK: - Custom Test Tags

/// Custom test tags for categorizing and filtering tests.
///
/// Tags enable running subsets of tests based on category, which is useful for:
/// - Running only fast tests during development
/// - Skipping slow tests in pre-commit hooks
/// - Running category-specific tests in CI pipelines
///
/// ## Usage in Tests
///
/// Apply tags to individual tests:
/// ```swift
/// @Test("API returns valid response", .tags(.api))
/// func apiReturnsValidResponse() async throws { ... }
/// ```
///
/// Apply tags to entire suites:
/// ```swift
/// @Suite("HomeResponseParser", .tags(.parser))
/// struct HomeResponseParserTests { ... }
/// ```
///
/// Combine multiple tags:
/// ```swift
/// @Test("Slow network test", .tags(.api, .slow))
/// func slowNetworkTest() async throws { ... }
/// ```
///
/// ## Command Line Filtering
///
/// Run tests with specific tags:
/// ```bash
/// # Run only API tests
/// xcodebuild test -scheme Kaset -only-testing:KasetTests --test-iterations 1 \
///   -test-tag .api
///
/// # Run only parser tests
/// xcodebuild test -scheme Kaset -only-testing:KasetTests --test-iterations 1 \
///   -test-tag .parser
///
/// # Run only ViewModel tests
/// xcodebuild test -scheme Kaset -only-testing:KasetTests --test-iterations 1 \
///   -test-tag .viewModel
/// ```
///
/// Exclude tests with specific tags:
/// ```bash
/// # Exclude slow tests
/// xcodebuild test -scheme Kaset -only-testing:KasetTests --test-iterations 1 \
///   -skip-test-tag .slow
///
/// # Exclude integration tests
/// xcodebuild test -scheme Kaset -only-testing:KasetTests --test-iterations 1 \
///   -skip-test-tag .integration
/// ```
///
/// ## Xcode Test Navigator
///
/// In Xcode's Test Navigator (Cmd+6), click the tag icon to group tests by tag.
/// This provides a visual way to see all tests in a category.
///
/// ## Tag Categories in This Project
///
/// | Tag | Description | Example Files |
/// |-----|-------------|---------------|
/// | `.api` | API client, network, retry logic | `YTMusicClientTests`, `RetryPolicyTests` |
/// | `.parser` | Response parsing | `HomeResponseParserTests`, `SearchResponseParserTests` |
/// | `.viewModel` | ViewModel logic | `HomeViewModelTests`, `SearchViewModelTests` |
/// | `.service` | Service layer | `AuthServiceTests`, `PlayerServiceTests` |
/// | `.model` | Data models | `ModelTests`, `LikeStatusTests` |
/// | `.slow` | Tests taking >1s | Performance tests, integration tests |
/// | `.integration` | Multi-component tests | End-to-end scenarios |
///
extension Tag {
    /// Tests related to API calls, network requests, and responses.
    ///
    /// Use for: `YTMusicClient`, retry policies, HTTP handling.
    @Tag static var api: Self

    /// Tests related to response parsing.
    ///
    /// Use for: `HomeResponseParser`, `SearchResponseParser`, `PlaylistParser`, etc.
    @Tag static var parser: Self

    /// Tests related to ViewModels.
    ///
    /// Use for: `HomeViewModel`, `SearchViewModel`, `LibraryViewModel`, etc.
    @Tag static var viewModel: Self

    /// Tests related to services (Auth, Player, WebKit, etc.).
    ///
    /// Use for: `AuthService`, `PlayerService`, `WebKitManager`.
    @Tag static var service: Self

    /// Tests related to data models.
    ///
    /// Use for: `Song`, `Playlist`, `Album`, `Artist`, enums, extensions.
    @Tag static var model: Self

    /// Tests that are slow (network, file I/O, etc.).
    ///
    /// These tests may be skipped during rapid development cycles.
    /// Use `swift test --skip .slow` to exclude them.
    @Tag static var slow: Self

    /// Integration tests that require multiple components.
    ///
    /// These tests verify end-to-end scenarios across services.
    @Tag static var integration: Self
}
