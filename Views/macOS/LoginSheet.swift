import SwiftUI

/// Login sheet presented when authentication is required.
@available(macOS 26.0, *)
struct LoginSheet: View {
    @Environment(AuthService.self) private var authService
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(\.dismiss) private var dismiss

    @State private var isCheckingLogin = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // WebView
            LoginWebView(onNavigationToYouTubeMusic: {
                checkForSuccessfulLogin()
            })
        }
        .frame(width: 500, height: 650)
        .onChange(of: webKitManager.cookiesDidChange) { _, _ in
            checkForSuccessfulLogin()
        }
        .onAppear {
            startPollingForLogin()
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in to YouTube Music")
                    .font(.headline)

                Text("Use your Google account to access your library and personalized recommendations.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isCheckingLogin {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding()
    }

    /// Starts a periodic task to check for successful login.
    private func startPollingForLogin() {
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))

                if !Task.isCancelled {
                    await checkForSuccessfulLoginAsync()
                }
            }
        }
    }

    private func checkForSuccessfulLogin() {
        guard !isCheckingLogin else { return }

        Task {
            await checkForSuccessfulLoginAsync()
        }
    }

    private func checkForSuccessfulLoginAsync() async {
        guard !isCheckingLogin else { return }

        isCheckingLogin = true

        // Small delay to allow cookies to settle
        try? await Task.sleep(for: .milliseconds(300))

        if let sapisid = await webKitManager.getSAPISID() {
            authService.completeLogin(sapisid: sapisid)
            pollTask?.cancel()
            dismiss()
        }

        isCheckingLogin = false
    }
}

#Preview {
    LoginSheet()
        .environment(AuthService())
        .environment(WebKitManager.shared)
}
