import SwiftUI

// MARK: - LoginSheet

/// Login sheet presented when authentication is required.
struct LoginSheet: View {
    @Environment(AuthService.self) private var authService
    @Environment(AccountService.self) private var accountService
    @Environment(WebKitManager.self) private var webKitManager
    @Environment(\.dismiss) private var dismiss

    @State private var isCheckingLogin = false
    @State private var didCaptureInitialLoginState = false
    @State private var didCompleteLogin = false
    @State private var loginAttemptID: LoginAttemptID?
    @State private var cookieBackupTransaction: CookieBackupTransaction?
    @State private var preparationTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?
    @State private var loginCheckTask: Task<Void, Never>?
    @State private var cleanupRetryTask: Task<Void, Never>?
    @State private var isRetryingCleanup = false
    @State private var isActive = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            self.headerView

            Divider()

            // Do not create the login WebView until reauthentication has drained
            // old session mutations and established its cookie baseline.
            if self.authService.loginCleanupRequired {
                self.loginCleanupFailureView
            } else if self.didCaptureInitialLoginState {
                LoginWebView(onNavigationToYouTubeMusic: {
                    self.checkForSuccessfulLogin()
                })
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 500, height: 650)
        .onChange(of: self.webKitManager.cookiesDidChange) { _, _ in
            self.checkForSuccessfulLogin()
        }
        .onAppear {
            self.isActive = true
            if self.authService.activeLoginAttemptID == nil,
               self.authService.needsReauth,
               !self.authService.loginCleanupRequired
            {
                self.authService.startLogin()
            }
            self.loginAttemptID = self.authService.activeLoginAttemptID
        }
        .task {
            guard !Task.isCancelled, self.isActive else { return }
            if let preparationTask = self.preparationTask {
                await preparationTask.value
                return
            }

            let preparationTask = Task { @MainActor in
                await self.prepareLoginAttempt()
            }
            self.preparationTask = preparationTask
            await preparationTask.value
            self.preparationTask = nil
        }
        .onDisappear {
            self.isActive = false
            guard !self.didCompleteLogin else { return }

            let loginAttemptID = self.loginAttemptID
            if let transaction = self.cookieBackupTransaction,
               !transaction.revokeCommit()
            {
                self.authService.setLoginCleanupRequired(true)
            }
            let didBeginCancellation = loginAttemptID.map {
                self.authService.beginLoginCancellation(expectedAttemptID: $0)
            } ?? false
            let preparationTask = self.preparationTask
            let pollTask = self.pollTask
            let loginCheckTask = self.loginCheckTask
            let cleanupRetryTask = self.cleanupRetryTask
            preparationTask?.cancel()
            pollTask?.cancel()
            loginCheckTask?.cancel()
            cleanupRetryTask?.cancel()

            Task { @MainActor in
                await preparationTask?.value
                await loginCheckTask?.value
                await pollTask?.value
                await cleanupRetryTask?.value

                if let transaction = self.cookieBackupTransaction {
                    self.cookieBackupTransaction = nil
                    _ = await self.authService.resolveLoginRollbackAfterDraining(
                        expectedAttemptID: loginAttemptID,
                        prepareRollback: {
                            await self.webKitManager.prepareLoginCookieBackupRollback(transaction)
                        },
                        rollback: { forceCleanup in
                            await rollbackLoginCookiesWithFallback(
                                forceCleanup: forceCleanup,
                                authService: self.authService,
                                webKitManager: self.webKitManager,
                                transaction: transaction,
                                expectedAttemptID: loginAttemptID
                            )
                        }
                    )
                } else if didBeginCancellation {
                    _ = await self.authService.resolveLoginRollbackAfterDraining(
                        expectedAttemptID: loginAttemptID,
                        prepareRollback: { true },
                        // No transaction means no cookie state was restored. A
                        // prior durable-cleanup failure must remain quarantined.
                        rollback: { forceCleanup in
                            forceCleanup || self.authService.loginCleanupRequired ? .failed : .rolledBack
                        }
                    )
                }
            }
        }
    }

    private var loginCleanupFailureView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(String(localized: "Sign-In Cleanup Required"))
                .font(.headline)

            Text(
                "Kaset could not safely clear saved sign-in data. Retry before signing in again.",
                comment: "Failed login cleanup explanation"
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 340)

            Button {
                self.retryLoginCleanup()
            } label: {
                if self.isRetryingCleanup || self.authService.isLoginCleanupInProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(String(localized: "Retry"))
                }
            }
            .disabled(self.isRetryingCleanup || self.authService.isLoginCleanupInProgress)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(localized: "Sign in to YouTube Music"))
                    .font(.headline)

                Spacer()

                if self.isCheckingLogin {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                        .frame(width: 13, height: 13)
                }
            }

            Text(String(localized: "Passkey sign-in is not available in this window. Google will ask for your password or another sign-in method instead."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func prepareLoginAttempt() async {
        guard !self.authService.loginCleanupRequired,
              let loginAttemptID = self.loginAttemptID
        else { return }

        if self.authService.needsReauth {
            await self.accountService.prepareForReauthentication()
            guard !Task.isCancelled, self.isActive, self.authService.needsReauth else { return }
            // Routine reauthentication preserves public WebKit storage; only
            // rollback/cleanup failures escalate to a full data-store clear.
            let didClear = await self.webKitManager.clearAuthCookies()
            guard self.authService.activeLoginAttemptID == loginAttemptID else { return }
            guard didClear else {
                _ = await self.authService.clearFailedLoginAfterDraining(
                    expectedAttemptID: loginAttemptID,
                    expectedSignOutSequence: self.authService.signOutSequence,
                    clearCookies: { false }
                )
                return
            }
            self.authService.setLoginCleanupRequired(false)
        }

        let canEvaluateAuthentication = await self.webKitManager.waitForInitialCookieRestore()
        guard self.authService.activeLoginAttemptID == loginAttemptID else { return }
        guard canEvaluateAuthentication else {
            let didClear = await self.authService.clearFailedLoginAfterDraining(
                expectedAttemptID: loginAttemptID,
                expectedSignOutSequence: self.authService.signOutSequence,
                clearCookies: {
                    await self.webKitManager.clearAllData()
                }
            )
            if didClear == true {
                await self.restartLoginAfterCleanup()
            }
            return
        }

        guard !Task.isCancelled,
              self.isActive,
              self.authService.activeLoginAttemptID == loginAttemptID
        else {
            self.cancelAndDismissIfCurrent(loginAttemptID)
            return
        }

        let transaction = await self.webKitManager.beginLoginCookieBackup()
        if transaction == nil, self.webKitManager.loginCookieBackupSetupRequiresCleanup {
            let didClear = await clearFailedLogin(
                authService: self.authService,
                webKitManager: self.webKitManager,
                expectedAttemptID: loginAttemptID
            )
            if didClear == true {
                self.dismiss()
            }
            return
        }
        guard let transaction,
              !Task.isCancelled,
              self.isActive,
              self.authService.activeLoginAttemptID == loginAttemptID
        else {
            guard let transaction else {
                self.cancelAndDismissIfCurrent(loginAttemptID)
                return
            }
            let rollbackResult = await self.authService.resolveLoginRollbackAfterDraining(
                expectedAttemptID: loginAttemptID,
                prepareRollback: {
                    await self.webKitManager.prepareLoginCookieBackupRollback(transaction)
                },
                rollback: { forceCleanup in
                    await rollbackLoginCookiesWithFallback(
                        forceCleanup: forceCleanup,
                        authService: self.authService,
                        webKitManager: self.webKitManager,
                        transaction: transaction,
                        expectedAttemptID: loginAttemptID
                    )
                }
            )
            if rollbackResult == .rolledBack || rollbackResult == .cleared {
                self.dismiss()
            }
            return
        }
        self.cookieBackupTransaction = transaction
        self.didCaptureInitialLoginState = true
        self.startPollingForLogin()
    }

    private func retryLoginCleanup() {
        guard self.cleanupRetryTask == nil,
              !self.authService.isLoginCleanupInProgress
        else { return }
        let expectedAttemptID = self.authService.activeLoginAttemptID
            ?? self.loginAttemptID
            ?? LoginAttemptID(rawValue: 0)
        let expectedSignOutSequence = self.authService.signOutSequence
        self.cleanupRetryTask = Task { @MainActor in
            self.isRetryingCleanup = true
            defer {
                self.isRetryingCleanup = false
                self.cleanupRetryTask = nil
            }

            let didClear = await self.authService.clearFailedLoginAfterDraining(
                expectedAttemptID: expectedAttemptID,
                expectedSignOutSequence: expectedSignOutSequence,
                clearCookies: {
                    await self.webKitManager.clearAllData()
                }
            )
            guard !Task.isCancelled,
                  self.isActive,
                  let didClear
            else { return }
            guard didClear else { return }

            await self.restartLoginAfterCleanup()
        }
    }

    private func restartLoginAfterCleanup() async {
        guard self.isActive else { return }
        if self.authService.activeLoginAttemptID == nil {
            self.authService.startLogin()
        }
        self.loginAttemptID = self.authService.activeLoginAttemptID
        self.didCaptureInitialLoginState = false
        self.didCompleteLogin = false
        self.cookieBackupTransaction = nil
        await self.prepareLoginAttempt()
    }

    /// Starts a periodic task to check for successful login.
    private func startPollingForLogin() {
        guard self.isActive else { return }
        self.pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))

                if !Task.isCancelled {
                    await self.checkForSuccessfulLoginAsync()
                }
            }
        }
    }

    private func checkForSuccessfulLogin() {
        guard self.isActive else { return }
        guard !self.isCheckingLogin, self.loginCheckTask == nil else { return }

        self.loginCheckTask = Task {
            await self.checkForSuccessfulLoginAsync()
            self.loginCheckTask = nil
        }
    }

    private func checkForSuccessfulLoginAsync() async {
        guard !self.isCheckingLogin,
              self.isActive,
              self.didCaptureInitialLoginState,
              let loginAttemptID = self.loginAttemptID,
              let transaction = self.cookieBackupTransaction
        else { return }

        self.isCheckingLogin = true
        defer { self.isCheckingLogin = false }

        // Small delay to allow cookies to settle.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, self.isActive else { return }

        guard await self.webKitManager.getSAPISID() != nil,
              await self.webKitManager.hasLoginCookieSnapshotChanged(transaction)
        else {
            return
        }

        // Allow the rest of the login cookie set to propagate before taking
        // the durable snapshot used across app restarts.
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled, self.isActive else { return }

        let completionGate = LoginCompletionGate(
            webKitManager: self.webKitManager,
            authService: self.authService
        )
        guard await completionGate.complete(
            expectedAttemptID: loginAttemptID,
            transaction: transaction,
            willPublishLogin: {
                self.didCompleteLogin = true
            }
        ) else {
            self.pollTask?.cancel()
            self.loginCheckTask?.cancel()
            self.cookieBackupTransaction = nil
            self.didCompleteLogin = false
            guard !self.authService.loginCleanupRequired else { return }
            if self.authService.activeLoginAttemptID == loginAttemptID {
                self.cancelAndDismissIfCurrent(loginAttemptID)
            } else if self.authService.activeLoginAttemptID == nil {
                self.dismiss()
            }
            return
        }
        guard !Task.isCancelled else { return }

        self.cookieBackupTransaction = nil
        self.pollTask?.cancel()
        self.dismiss()
    }

    private func cancelAndDismissIfCurrent(_ loginAttemptID: LoginAttemptID) {
        guard self.authService.activeLoginAttemptID == loginAttemptID else { return }
        self.authService.cancelLoginIfNeeded(expectedAttemptID: loginAttemptID)
        self.dismiss()
    }
}

// MARK: - Failed Login Cleanup

@MainActor
private func rollbackLoginCookiesWithFallback(
    forceCleanup: Bool,
    authService: any AuthServiceProtocol,
    webKitManager: any WebKitManagerProtocol,
    transaction: CookieBackupTransaction,
    expectedAttemptID: LoginAttemptID?
) async -> CookieBackupRollbackResult {
    if forceCleanup {
        return await webKitManager.clearAllData() ? .cleared : .failed
    }
    return switch await webKitManager.rollbackLoginCookieBackup(transaction) {
    case .rolledBack:
        .rolledBack
    case .cleared:
        .cleared
    case .superseded:
        if let expectedAttemptID,
           authService.activeLoginAttemptID == expectedAttemptID
        {
            await webKitManager.clearAllData() ? .cleared : .failed
        } else {
            .superseded
        }
    case .failed:
        await webKitManager.clearAllData() ? .cleared : .failed
    }
}

@MainActor
private func clearFailedLogin(
    authService: any AuthServiceProtocol,
    webKitManager: any WebKitManagerProtocol,
    expectedAttemptID: LoginAttemptID
) async -> Bool? {
    await authService.clearFailedLoginAfterDraining(
        expectedAttemptID: expectedAttemptID,
        expectedSignOutSequence: authService.signOutSequence,
        clearCookies: {
            await webKitManager.clearAllData()
        }
    )
}

// MARK: - LoginCompletionGate

@MainActor
struct LoginCompletionGate {
    let webKitManager: any WebKitManagerProtocol
    let authService: any AuthServiceProtocol

    func complete(
        expectedAttemptID: LoginAttemptID,
        transaction: CookieBackupTransaction,
        willPublishLogin: @escaping @MainActor @Sendable () -> Void = {}
    ) async -> Bool {
        guard !Task.isCancelled,
              self.authService.activeLoginAttemptID == expectedAttemptID
        else {
            await self.rollbackOrInvalidate(
                transaction,
                expectedAttemptID: expectedAttemptID
            )
            return false
        }

        let didComplete = await self.authService.completeLoginAfterDraining(
            expectedAttemptID: expectedAttemptID,
            persistBeforeCommit: {
                guard !Task.isCancelled,
                      let committedSessionValue = await self.webKitManager
                      .commitLoginCookieBackup(transaction)
                else { return nil }
                return committedSessionValue
            },
            persistFinalSession: {
                guard !Task.isCancelled,
                      let finalSessionValue = await self.webKitManager
                      .finalizeLoginCookieBackup(transaction)
                else { return nil }
                return finalSessionValue
            },
            willPublishLogin: willPublishLogin
        )
        guard didComplete else {
            await self.rollbackOrInvalidate(
                transaction,
                expectedAttemptID: expectedAttemptID
            )
            return false
        }
        return true
    }

    private func rollbackOrInvalidate(
        _ transaction: CookieBackupTransaction,
        expectedAttemptID: LoginAttemptID
    ) async {
        _ = await self.authService.resolveLoginRollbackAfterDraining(
            expectedAttemptID: expectedAttemptID,
            prepareRollback: {
                await self.webKitManager.prepareLoginCookieBackupRollback(transaction)
            },
            rollback: { forceCleanup in
                await rollbackLoginCookiesWithFallback(
                    forceCleanup: forceCleanup,
                    authService: self.authService,
                    webKitManager: self.webKitManager,
                    transaction: transaction,
                    expectedAttemptID: expectedAttemptID
                )
            }
        )
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService)
    LoginSheet()
        .environment(authService)
        .environment(AccountService(ytMusicClient: client, authService: authService))
        .environment(WebKitManager.shared)
}
