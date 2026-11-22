import Foundation

enum YTMusicError: LocalizedError {
    case authExpired
    case notAuthenticated
    case networkError(underlying: Error)
    case parseError(message: String)
    case apiError(message: String, code: Int?)
    case playbackError(message: String)
    case invalidInput(String)
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
        case let .invalidInput(message):
            return "Invalid input: \(message)"
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
        case .invalidInput:
            "Please check the input and try again."
        case .unknown:
            "Try again later."
        }
    }

    var requiresReauth: Bool {
        switch self {
        case .authExpired, .notAuthenticated:
            true
        default:
            false
        }
    }

    var isRetryable: Bool {
        switch self {
        case .authExpired, .notAuthenticated:
            return false
        case .networkError:
            return true
        case let .apiError(_, code):
            if let code {
                return code >= 500
            }
            return true
        case .parseError:
            return false
        case .playbackError:
            return true
        case .invalidInput:
            return false
        case .unknown:
            return true
        }
    }

    var userFriendlyTitle: String {
        switch self {
        case .authExpired, .notAuthenticated:
            "Authentication Required"
        case .networkError:
            "Connection Error"
        case .apiError:
            "Server Error"
        case .parseError:
            "Data Error"
        case .playbackError:
            "Playback Error"
        case .invalidInput:
            "Invalid Input"
        case .unknown:
            "Error"
        }
    }

    var userFriendlyMessage: String {
        switch self {
        case .authExpired:
            "Your session has expired. Please sign in again."
        case .notAuthenticated:
            "Please sign in to access this content."
        case .networkError:
            "Unable to connect. Please check your internet connection."
        case let .apiError(_, code):
            if let code {
                "Something went wrong (Error \(code))."
            } else {
                "Something went wrong. Please try again."
            }
        case .parseError:
            "Unable to load content. Please try again."
        case .playbackError:
            "Unable to play this track. Try a different one."
        case let .invalidInput(message):
            message
        case let .unknown(message):
            message
        }
    }
}

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
