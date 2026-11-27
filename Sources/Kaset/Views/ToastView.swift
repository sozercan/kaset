import SwiftUI

struct ToastView: View {
    let message: String

    var isError: Bool = false

    var onDismiss: (() -> Void)?

    var body: some View {
        CompatGlassContainer(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: self.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(self.isError ? .red : .blue)

                Text(self.message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer(minLength: 0)

                if let dismiss = self.onDismiss {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Dismiss"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minWidth: 250, maxWidth: 400)
            .compatGlass(in: .rect(cornerRadius: 10))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        }
        .compatGlassTransition(.materialize)
        .accessibilityIdentifier(AccessibilityID.Toast.container)
    }
}

struct AccountErrorToast: View {
    @Environment(AccountService.self) private var accountService

    @State private var isVisible = false
    @State private var dismissTask: Task<Void, Never>?

    private let autoDismissDelay: Duration = .seconds(4)

    var body: some View {
        Group {
            if self.isVisible, let error = accountService.lastError {
                ToastView(
                    message: self.errorMessage(for: error),
                    isError: true,
                    onDismiss: { self.dismiss() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: self.isVisible)
        .onChange(of: self.accountService.errorSequence) { _, _ in
            if self.accountService.lastError != nil {
                self.show()
            }
        }
    }

    private func errorMessage(for error: Error) -> String {
        if let ytError = error as? YTMusicError {
            return ytError.localizedDescription
        }
        if self.accountService.lastErrorWasFetch {
            return String(localized: "Failed to load accounts. Please try again.")
        }
        return String(localized: "Failed to switch account. Please try again.")
    }

    private func show() {
        self.dismissTask?.cancel()

        self.isVisible = true

        self.dismissTask = Task {
            try? await Task.sleep(for: self.autoDismissDelay)
            if !Task.isCancelled {
                await MainActor.run {
                    self.dismiss()
                }
            }
        }
    }

    private func dismiss() {
        self.isVisible = false
        self.accountService.clearError()
        self.dismissTask?.cancel()
        self.dismissTask = nil
    }
}

extension AccessibilityID {
    enum Toast {
        static let container = "toast.container"
    }
}

#Preview("Error Toast") {
    ToastView(message: "Failed to switch account. Please try again.", isError: true) {
        DiagnosticsLogger.ui.debug("Toast dismissed")
    }
    .padding()
}

#Preview("Info Toast") {
    ToastView(message: "Account switched successfully", isError: false)
        .padding()
}
