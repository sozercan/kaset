import SwiftUI

// MARK: - ErrorView

/// Reusable error view with title, message, and optional retry action.
/// Uses native `ContentUnavailableView` for platform-consistent styling.
@available(macOS 14.0, *)
struct ErrorView: View {
    let title: String
    let message: String
    let isRetryable: Bool
    let retryAction: (() -> Void)?

    /// Creates an ErrorView with explicit parameters.
    init(
        title: String = "Unable to load content",
        message: String,
        isRetryable: Bool = true,
        retryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.isRetryable = isRetryable
        self.retryAction = retryAction
    }

    /// Creates an ErrorView from a LoadingError.
    init(
        error: LoadingError,
        retryAction: (() -> Void)? = nil
    ) {
        self.title = error.title
        self.message = error.message
        self.isRetryable = error.isRetryable
        self.retryAction = retryAction
    }

    var body: some View {
        ContentUnavailableView {
            Label(self.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(self.message)
        } actions: {
            if self.isRetryable, let action = self.retryAction {
                Button("Try Again") {
                    action()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

#Preview {
    ErrorView(message: "Something went wrong") {
        // No-op for preview
    }
}
