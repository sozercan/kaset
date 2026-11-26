import SwiftUI

@available(macOS 14.0, *)
struct ErrorView: View {
    let title: String
    let message: String
    let isRetryable: Bool
    let retryAction: (() -> Void)?

    init(
        title: String = String(localized: "Unable to load content"),
        message: String,
        isRetryable: Bool = true,
        retryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.isRetryable = isRetryable
        self.retryAction = retryAction
    }

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
                Button(String(localized: "Try Again")) {
                    action()
                }
                .compatGlassProminentButton()
            }
        }
    }
}

#Preview {
    ErrorView(message: "Something went wrong") {}
}
