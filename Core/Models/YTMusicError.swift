import Foundation

// MARK: - YTMusicError

/// Unified error type for YouTube Music operations.
enum YTMusicError: LocalizedError, Sendable {
    /// Authentication has expired or is invalid.
    case authExpired
    /// No authentication credentials available.
    case notAuthenticated
    /// Network request failed.
    case networkError(underlying: Error)
    /// Failed to parse API response.
    case parseError(message: String)
    /// API returned an error.
    case apiError(message: String, code: Int?)
    /// Playback error.
    case playbackError(message: String)
    /// Unknown error.
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .authExpired:
            return "Your session has expired. Please sign in again."
        case .notAuthenticated:
            return "You're not signed in. Please sign in to continue."
        case let .networkError(underlying):
            return "Network error: \(underlying.localizedDescription)"
        case let .parseError(message):
            return "Failed to parse response: \(message)"
        case let .apiError(message, code):
            if let code {
                return "API error (\(code)): \(message)"
            }
            return "API error: \(message)"
        case let .playbackError(message):
            return "Playback error: \(message)"
        case let .unknown(message):
            return message
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .authExpired, .notAuthenticated:
            "Sign in to your YouTube Music account."
        case .networkError:
            "Check your internet connection and try again."
        case .parseError, .apiError:
            "Try again. If the problem persists, the service may be temporarily unavailable."
        case .playbackError:
            "Try playing a different track."
        case .unknown:
            "Try again later."
        }
    }

    /// Whether this error should trigger a re-authentication flow.
    var requiresReauth: Bool {
        switch self {
        case .authExpired, .notAuthenticated:
            true
        default:
            false
        }
    }
}

// MARK: CustomDebugStringConvertible

// Make the underlying error's description accessible for logging
extension YTMusicError: CustomDebugStringConvertible {
    var debugDescription: String {
        switch self {
        case let .networkError(underlying):
            "YTMusicError.networkError(\(underlying))"
        default:
            self.errorDescription ?? String(describing: self)
        }
    }
}
