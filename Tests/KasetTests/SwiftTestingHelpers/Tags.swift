import Foundation
import Testing

/// Custom test tags for categorizing and filtering tests.
///
/// Usage:
/// ```swift
/// @Test("API returns valid response", .tags(.api, .slow))
/// func apiReturnsValidResponse() async throws { ... }
/// ```
///
/// Run filtered tests:
/// - `swift test --filter .api` — Run only API tests
/// - `swift test --skip .slow` — Exclude slow tests
extension Tag {
    /// Tests related to API calls and responses.
    @Tag static var api: Self

    /// Tests related to response parsing.
    @Tag static var parser: Self

    /// Tests related to ViewModels.
    @Tag static var viewModel: Self

    /// Tests related to services (Auth, Player, WebKit, etc.).
    @Tag static var service: Self

    /// Tests related to data models.
    @Tag static var model: Self

    /// Tests that are slow (network, file I/O, etc.).
    @Tag static var slow: Self

    /// Integration tests that require multiple components.
    @Tag static var integration: Self
}
