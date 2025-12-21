import Foundation
import Observation

// MARK: - PresentableError

/// Represents an error to be displayed to the user.
struct PresentableError: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let message: String
    let retryAction: (@Sendable () async -> Void)?
    let dismissAction: (@Sendable () -> Void)?

    init(
        title: String,
        message: String,
        retryAction: (@Sendable () async -> Void)? = nil,
        dismissAction: (@Sendable () -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.retryAction = retryAction
        self.dismissAction = dismissAction
    }

    /// Creates a PresentableError from a YTMusicError.
    static func from(_ error: YTMusicError, retryAction: (@Sendable () async -> Void)? = nil) -> PresentableError {
        switch error {
        case .notAuthenticated:
            return PresentableError(
                title: "Not Signed In",
                message: "Please sign in to access this content.",
                retryAction: nil
            )

        case .authExpired:
            return PresentableError(
                title: "Session Expired",
                message: "Your session has expired. Please sign in again.",
                retryAction: nil
            )

        case .networkError:
            return PresentableError(
                title: "Connection Error",
                message: "Unable to connect. Please check your internet connection.",
                retryAction: retryAction
            )

        case let .apiError(_, code):
            let errorCode = code.map { " (Error \($0))" } ?? ""
            return PresentableError(
                title: "Server Error",
                message: "Something went wrong\(errorCode).",
                retryAction: retryAction
            )

        case .parseError:
            return PresentableError(
                title: "Data Error",
                message: "Unable to load content. Please try again.",
                retryAction: retryAction
            )

        case .playbackError:
            return PresentableError(
                title: "Playback Error",
                message: "Unable to play this track. Try a different one.",
                retryAction: nil
            )

        case let .unknown(message):
            return PresentableError(
                title: "Error",
                message: message,
                retryAction: retryAction
            )
        }
    }

    /// Creates a PresentableError from any Error.
    static func from(_ error: Error, retryAction: (@Sendable () async -> Void)? = nil) -> PresentableError {
        if let ytError = error as? YTMusicError {
            return self.from(ytError, retryAction: retryAction)
        }

        if (error as NSError).domain == NSURLErrorDomain {
            return PresentableError(
                title: "Connection Error",
                message: "Unable to connect. Please check your internet connection.",
                retryAction: retryAction
            )
        }

        return PresentableError(
            title: "Error",
            message: error.localizedDescription,
            retryAction: retryAction
        )
    }
}

// MARK: - ErrorPresenter

/// Service for presenting errors to the user in a consistent manner.
@MainActor
@Observable
final class ErrorPresenter {
    /// Shared instance for app-wide error presentation.
    static let shared = ErrorPresenter()

    /// The currently presented error, if any.
    private(set) var currentError: PresentableError?

    /// Whether an error is currently being shown.
    var isShowingError: Bool {
        self.currentError != nil
    }

    private let logger = DiagnosticsLogger.ui

    private init() {}

    /// Presents an error to the user.
    func present(_ error: PresentableError) {
        self.logger.warning("Presenting error: \(error.title) - \(error.message)")
        self.currentError = error
    }

    /// Presents a YTMusicError to the user.
    func present(_ error: YTMusicError, retryAction: (@Sendable () async -> Void)? = nil) {
        self.present(.from(error, retryAction: retryAction))
    }

    /// Presents any Error to the user.
    func present(_ error: Error, retryAction: (@Sendable () async -> Void)? = nil) {
        self.present(.from(error, retryAction: retryAction))
    }

    /// Dismisses the current error.
    func dismiss() {
        let action = self.currentError?.dismissAction
        self.currentError = nil
        action?()
    }

    /// Retries the current error's action and dismisses the error.
    func retry() async {
        guard let retryAction = currentError?.retryAction else {
            self.dismiss()
            return
        }

        self.dismiss()
        await retryAction()
    }
}
