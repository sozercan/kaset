import Foundation
import WebKit

// MARK: - CookieRestoreResult

enum CookieRestoreResult: Equatable, Sendable {
    case ready
    case unavailable
    case failed
}

// MARK: - Startup Cookie Restoration

extension WebKitManager {
    var canPersistAuthCookies: Bool {
        self.initialCookieRestoreResult == .ready
            && !self.isRestoringCookies
            && !self.isClearingAuthCookies
    }

    func startInitialCookieRestore() {
        guard self.initialCookieRestoreTask == nil,
              !self.isClearingAuthCookies,
              !self.authCookieClearCoordinator.isBusy
        else { return }

        self.initialCookieRestoreResult = .unavailable
        let pendingBackup = self.cookieDebounceTask
        let forcedBackup = self.forcedCookieBackupTask
        pendingBackup?.cancel()
        forcedBackup?.cancel()
        self.cookieDebounceTask = nil
        let restoreGeneration = self.authCookieOperationFence.generation
        self.initialCookieRestoreTask = Task { @MainActor in
            await pendingBackup?.value
            _ = await forcedBackup?.value
            let result = await self.restoreAuthCookiesFromBackup(
                expectedGeneration: restoreGeneration
            )
            self.initialCookieRestoreResult = result
            self.initialCookieRestoreTask = nil
            return result
        }
    }

    /// Joins the current restore, or retries a previous non-destructive storage failure.
    func waitForInitialCookieRestore() async -> CookieRestoreResult {
        if self.initialCookieRestoreTask == nil, self.initialCookieRestoreResult == .unavailable {
            self.startInitialCookieRestore()
        }
        if let restoreTask = self.initialCookieRestoreTask {
            return await restoreTask.value
        }
        return self.initialCookieRestoreResult
    }

    /// Restores auth cookies from the configured archive storage to WebKit.
    /// Handles migration from legacy file-based storage on first run.
    func restoreAuthCookiesFromBackup(expectedGeneration: UInt64) async -> CookieRestoreResult {
        self.isRestoringCookies = true
        defer { self.isRestoringCookies = false }

        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return .failed }

        // Wait a moment for WebKit to fully initialize
        try? await Task.sleep(for: .milliseconds(100))
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return .failed }

        switch await self.cookieArchiveQueue.restoreDecision() {
        case .allowed:
            break
        case .denied:
            self.logger.info("Cookie backup restoration is disabled after explicit invalidation")
            let didDeletePersistedCookies = await self.cookieArchiveQueue.invalidateAndDelete()
            guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return .failed }
            let didClearLiveCookies = await self.clearLiveLoginSessionCookies(
                expectedGeneration: expectedGeneration
            )
            return didDeletePersistedCookies && didClearLiveCookies ? .ready : .failed
        case .unavailable:
            self.logger.error("Cookie restore policy could not be read; preserving live cookies and the archive for retry")
            return .unavailable
        }

        // Migrate from legacy file-based storage if needed (one-time operation).
        // Perform file I/O off the main actor.
        _ = await Task(priority: .utility) {
            LegacyCookieMigration.migrateIfNeeded()
        }.value
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return .failed }

        let existingCookies = await self.dataStore.httpCookieStore.allCookies()
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return .failed }
        self.logger.info("WebKit has \(existingCookies.count) cookies on startup")

        // Archive I/O runs on the injected storage queue, never on the main actor.
        let archiveResult = await self.cookieArchiveQueue.loadArchiveResult()
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return .failed }

        switch archiveResult {
        case .failure:
            self.logger.error("Cookie backup storage could not be read; preserving live cookies and the archive for retry")
            return .unavailable
        case .notFound:
            // Explicit invalidation persists a denied restore policy before it
            // deletes the archive. An allowed policy with no archive is not an
            // authoritative sign-out signal and may coexist with a live login.
            self.logger.info("No cookies found in archive storage; preserving the live WebKit session")
            return .ready
        case let .data(archiveData):
            // The persisted archive is the source of truth for login-session
            // state. Preserve unrelated Google/YouTube preference cookies.
            guard await self.clearLiveLoginSessionCookies(
                expectedGeneration: expectedGeneration
            ) else { return .failed }
            let didRestore = await self.restoreArchivedAuthCookies(
                archiveData,
                expectedGeneration: expectedGeneration
            )
            return didRestore ? .ready : .failed
        }
    }

    private func restoreArchivedAuthCookies(
        _ archiveData: Data,
        expectedGeneration: UInt64
    ) async -> Bool {
        let keychainCookies = KeychainCookieStorage.decodeCookies(from: archiveData)
        guard !keychainCookies.isEmpty else {
            self.logger.error("Cookie archive contained no restorable authentication cookies")
            _ = await self.quarantineFailedAuthCookieRestore(
                expectedGeneration: expectedGeneration
            )
            return false
        }
        let expectedState = CookieArchiveVerificationState.make(from: keychainCookies)
        guard case .snapshot = expectedState else {
            self.logger.error("Cookie archive could not produce a verifiable authentication snapshot")
            _ = await self.quarantineFailedAuthCookieRestore(
                expectedGeneration: expectedGeneration
            )
            return false
        }
        let expectedPrimarySession = keychainCookies.contains { cookie in
            KeychainCookieStorage.isValidAuthCookie(cookie)
                && (cookie.name == "SAPISID" || cookie.name == "__Secure-3PAPISID")
        }
        guard expectedPrimarySession else {
            self.logger.error("Cookie archive does not contain a primary authentication cookie")
            _ = await self.quarantineFailedAuthCookieRestore(
                expectedGeneration: expectedGeneration
            )
            return false
        }

        #if DEBUG
            await self.cookieArchiveQueue.exportDebugArchiveIfEnabled(archiveData)
        #endif

        self.logger.info("Restoring \(keychainCookies.count) auth cookies from Keychain")
        for cookie in keychainCookies {
            guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return false }
            await self.dataStore.httpCookieStore.setCookie(cookie)
        }
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return false }

        let cookies = await self.dataStore.httpCookieStore.allCookies()
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return false }
        let restoredState = CookieArchiveVerificationState.make(from: cookies)
        let didRestore = restoredState.matches(expectedState)
        guard didRestore else {
            self.logger.error("✗ Failed to restore auth cookies - Keychain data may be corrupted")
            _ = await self.quarantineFailedAuthCookieRestore(
                expectedGeneration: expectedGeneration
            )
            return false
        }
        self.logger.info("✓ Auth cookies restored from Keychain (\(cookies.count) total cookies)")

        return true
    }

    func quarantineFailedAuthCookieRestore(expectedGeneration: UInt64) async -> Bool {
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else {
            return false
        }
        let didInvalidateRestore = self.invalidateAuthCookieRestoration()
        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else {
            return false
        }
        let didClearLiveCookies = await self.clearLiveLoginSessionCookies(
            expectedGeneration: expectedGeneration
        )
        if !didInvalidateRestore || !didClearLiveCookies {
            self.logger.error("Failed to fully quarantine an invalid authentication-cookie restore")
        }
        return didInvalidateRestore && didClearLiveCookies
    }

    private func clearLiveLoginSessionCookies(expectedGeneration: UInt64) async -> Bool {
        for _ in 0 ..< 3 {
            guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return false }
            let liveCookies = await self.dataStore.httpCookieStore.allCookies()
            for cookie in liveCookies where KeychainCookieStorage.isLoginSessionCookie(cookie) {
                await self.dataStore.httpCookieStore.deleteCookie(cookie)
            }
            guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return false }
            let remainingCookies = await self.dataStore.httpCookieStore.allCookies()
            if !remainingCookies.contains(where: KeychainCookieStorage.isLoginSessionCookie) {
                return true
            }
            await Task.yield()
        }

        guard self.canContinueAuthCookieOperation(expectedGeneration: expectedGeneration) else { return false }
        self.logger.error("Could not clear live login-session cookies from WebKit")
        return false
    }

    private func canContinueAuthCookieOperation(expectedGeneration: UInt64) -> Bool {
        !Task.isCancelled && self.authCookieOperationFence.isCurrent(expectedGeneration)
    }
}
