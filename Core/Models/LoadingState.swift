import Foundation

// MARK: - LoadingState

/// Shared loading state for ViewModels.
enum LoadingState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case loadingMore
    case error(String)
}
