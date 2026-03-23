import Foundation

// MARK: - LoadingState

/// Shared loading state for ViewModels.
enum LoadingState: Sendable {
    case idle
    case loading
    case loaded
    case loadingMore
    case error(LoadingError)
}

// MARK: - LoadingError

/// Wraps error information for display in views.
/// Provides user-friendly messages and retry capability.
struct LoadingError: Sendable {
    let title: String
    let message: String
    let isRetryable: Bool
    let underlyingError: (any Error)?

    /// Creates a LoadingError from any Error.
    init(from error: any Error) {
        if let ytError = error as? YTMusicError {
            self.title = ytError.userFriendlyTitle
            self.message = ytError.userFriendlyMessage
            self.isRetryable = ytError.isRetryable
            self.underlyingError = ytError
        } else if (error as NSError).domain == NSURLErrorDomain {
            self.title = "Connection Error"
            self.message = "Unable to connect. Please check your internet connection."
            self.isRetryable = true
            self.underlyingError = error
        } else {
            self.title = "Error"
            self.message = error.localizedDescription
            self.isRetryable = true
            self.underlyingError = error
        }
    }

    /// Creates a LoadingError with a simple message.
    init(message: String, isRetryable: Bool = true) {
        self.title = "Error"
        self.message = message
        self.isRetryable = isRetryable
        self.underlyingError = nil
    }

    /// Creates a LoadingError with title and message.
    init(title: String, message: String, isRetryable: Bool = true) {
        self.title = title
        self.message = message
        self.isRetryable = isRetryable
        self.underlyingError = nil
    }
}

// MARK: - LoadingState + Equatable

extension LoadingState: Equatable {
    static func == (lhs: LoadingState, rhs: LoadingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.loaded, .loaded), (.loadingMore, .loadingMore):
            true
        case let (.error(lhsError), .error(rhsError)):
            lhsError.message == rhsError.message
        default:
            false
        }
    }
}
