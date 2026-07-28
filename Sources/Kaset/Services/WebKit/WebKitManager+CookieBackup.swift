import Foundation
import WebKit

// MARK: - CookieArchiveBackupAction

enum CookieArchiveBackupAction: Equatable, Sendable {
    case persist(data: Data, cookieCount: Int)
    case invalidate
    case retainExisting

    static func make(from result: CookieArchiveEncodingResult) -> CookieArchiveBackupAction {
        switch result {
        case let .archive(data, cookieCount):
            .persist(data: data, cookieCount: cookieCount)
        case .noPrimarySession:
            .invalidate
        case .failure:
            .retainExisting
        }
    }
}

// MARK: - CookieArchiveSnapshot

struct CookieArchiveSnapshot: Equatable, Sendable {
    let data: Data
    let cookieCount: Int
    let primarySessionValue: String?
    let stabilityFingerprint: Data

    static func == (lhs: CookieArchiveSnapshot, rhs: CookieArchiveSnapshot) -> Bool {
        lhs.stabilityFingerprint == rhs.stabilityFingerprint
    }

    static func make(from cookies: [HTTPCookie]) -> CookieArchiveSnapshot? {
        let validCookies = cookies.filter { KeychainCookieStorage.isValidAuthCookie($0) }
        guard let archive = KeychainCookieStorage.makeArchiveData(from: validCookies) else {
            return nil
        }

        let entries = validCookies
            .map(CookieArchiveStabilityEntry.init(cookie:))
            .sorted { lhs, rhs in
                lhs.sortKey.lexicographicallyPrecedes(rhs.sortKey)
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let stabilityFingerprint = try? encoder.encode(entries) else { return nil }

        let youtubeCookies = WebKitManager.cookies(
            validCookies,
            matching: "youtube.com"
        )
        let secureSessionValue = youtubeCookies.first {
            $0.name == WebKitManager.authCookieName
        }?.value
        let fallbackSessionValue = youtubeCookies.first {
            $0.name == WebKitManager.fallbackAuthCookieName
        }?.value
        return CookieArchiveSnapshot(
            data: archive.data,
            cookieCount: archive.cookieCount,
            primarySessionValue: secureSessionValue ?? fallbackSessionValue,
            stabilityFingerprint: stabilityFingerprint
        )
    }
}

// MARK: - CookieArchiveVerificationState

enum CookieArchiveVerificationState: Sendable {
    case noValidAuthCookies
    case snapshot(CookieArchiveSnapshot)
    case invalid

    static func make(from cookies: [HTTPCookie]) -> CookieArchiveVerificationState {
        let validCookies = cookies.filter { KeychainCookieStorage.isValidAuthCookie($0) }
        guard !validCookies.isEmpty else { return .noValidAuthCookies }
        guard let snapshot = CookieArchiveSnapshot.make(from: validCookies) else { return .invalid }
        return .snapshot(snapshot)
    }

    func matches(_ expected: CookieArchiveVerificationState) -> Bool {
        switch (self, expected) {
        case (.noValidAuthCookies, .noValidAuthCookies):
            true
        case let (.snapshot(actual), .snapshot(expected)):
            actual == expected
        case (.invalid, _), (_, .invalid), (.noValidAuthCookies, .snapshot), (.snapshot, .noValidAuthCookies):
            false
        }
    }
}

// MARK: - CookieArchiveStabilityEntry

private struct CookieArchiveStabilityEntry: Codable, Equatable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresDate: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool
    let isSessionOnly: Bool
    let sameSitePolicy: String?

    init(cookie: HTTPCookie) {
        self.name = cookie.name
        self.value = cookie.value
        self.domain = cookie.domain.lowercased()
        self.path = cookie.path
        self.expiresDate = cookie.expiresDate
        self.isSecure = cookie.isSecure
        self.isHTTPOnly = cookie.isHTTPOnly
        self.isSessionOnly = cookie.isSessionOnly
        self.sameSitePolicy = cookie.sameSitePolicy?.rawValue.lowercased() ?? "none"
    }

    var sortKey: [String] {
        [self.domain, self.path, self.name, self.value]
    }
}

// MARK: - LoginCookieVerificationState

private struct LoginCookieVerificationState: Equatable, Sendable {
    let entries: [CookieArchiveStabilityEntry]

    static func make(
        from cookies: [HTTPCookie],
        expirationCutoff: Date = Date()
    ) -> LoginCookieVerificationState {
        let entries = cookies
            .filter { cookie in
                guard KeychainCookieStorage.isLoginDomainCookie(cookie) else { return false }
                guard let expiresDate = cookie.expiresDate else { return true }
                return expiresDate > expirationCutoff
            }
            .map(CookieArchiveStabilityEntry.init(cookie:))
            .sorted { lhs, rhs in
                lhs.sortKey.lexicographicallyPrecedes(rhs.sortKey)
            }
        return LoginCookieVerificationState(entries: entries)
    }
}

// MARK: - CookieArchiveWriteAttempt

struct CookieArchiveWriteAttempt: Sendable {
    let snapshot: CookieArchiveSnapshot
    let generation: UInt64
}

// MARK: - CookieBackupStabilizationResult

enum CookieBackupStabilizationResult: Equatable {
    case persisted
    case failed
    case cancelled
    case unstable
}

// MARK: - CookieBackupStabilizer

@MainActor
enum CookieBackupStabilizer {
    struct Operations {
        let prepareAttempt: () -> Void
        let makeAttempt: () async -> CookieArchiveWriteAttempt?
        let persist: (CookieArchiveWriteAttempt) async -> CookieArchiveSaveResult
        let readVerificationSnapshot: () async -> CookieArchiveSnapshot?
        let isDirty: () -> Bool
        let canContinue: () -> Bool
    }

    static func persistStableSnapshot(
        maxAttempts: Int,
        operations: Operations
    ) async -> CookieBackupStabilizationResult {
        guard maxAttempts > 0 else { return .unstable }

        for _ in 0 ..< maxAttempts {
            guard operations.canContinue() else { return .cancelled }
            operations.prepareAttempt()

            guard let attempt = await operations.makeAttempt() else {
                return operations.canContinue() ? .failed : .cancelled
            }
            guard operations.canContinue() else { return .cancelled }

            let saveResult = await operations.persist(attempt)
            switch saveResult {
            case .failed:
                return .failed
            case .superseded:
                guard operations.canContinue() else { return .cancelled }
                continue
            case .saved, .alreadyCurrent:
                break
            }

            guard operations.canContinue() else { return .cancelled }
            guard let verificationSnapshot = await operations.readVerificationSnapshot() else {
                return operations.canContinue() ? .failed : .cancelled
            }

            // Give already-enqueued observer callbacks a chance to mark the
            // snapshot dirty, but verify freshness directly instead of treating
            // observer delivery as a synchronization barrier.
            await Task.yield()
            guard operations.canContinue() else { return .cancelled }

            guard let isStable = await self.isStable(
                attempt: attempt.snapshot,
                verification: verificationSnapshot,
                operations: operations
            ) else {
                return operations.canContinue() ? .failed : .cancelled
            }
            if isStable {
                return .persisted
            }
        }

        return .unstable
    }

    private static func isStable(
        attempt: CookieArchiveSnapshot,
        verification: CookieArchiveSnapshot,
        operations: Operations
    ) async -> Bool? {
        guard attempt == verification else { return false }
        guard operations.isDirty() else { return true }
        operations.prepareAttempt()
        guard let postCallbackSnapshot = await operations.readVerificationSnapshot() else {
            return nil
        }
        await Task.yield()
        guard !operations.isDirty() else { return false }
        return attempt == postCallbackSnapshot
    }
}

// MARK: - LiveCookieRollbackResult

private enum LiveCookieRollbackResult {
    case restored
    case superseded
    case failed
}

// MARK: - LoginCookieBackupBaseline

private struct LoginCookieBackupBaseline {
    let liveBaseline: CookieArchiveLiveBaseline
    let authSnapshot: CookieArchiveSnapshot?
    let loginCookies: [HTTPCookie]
}

// MARK: - Forced Cookie Backup

extension WebKitManager {
    /// Starts a rollback-safe persistence transaction before the login WebView
    /// can change authentication cookies.
    func beginLoginCookieBackup() async -> CookieBackupTransaction? {
        guard await self.waitForInitialCookieRestore() else {
            self.loginCookieBackupSetupRequiresCleanup = true
            return nil
        }
        guard !self.isRestoringCookies,
              !self.isClearingAuthCookies,
              !self.authCookieClearCoordinator.isBusy,
              !self.loginCookieBackupSetupRequiresCleanup,
              !self.isPreparingLoginCookieBackup,
              self.activeLoginCookieBackupTransaction == nil,
              self.forcedCookieBackupTask == nil
        else { return nil }
        let expectedOperationGeneration = self.authCookieOperationFence.generation
        self.isPreparingLoginCookieBackup = true
        self.forcedCookieBackupDirty = false
        defer { self.isPreparingLoginCookieBackup = false }
        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = nil

        guard let baseline = await self.captureLoginCookieBackupBaseline(
            expectedOperationGeneration: expectedOperationGeneration
        ) else { return nil }
        guard let transaction = await CookieArchiveWriteQueue.shared.beginLoginTransaction(
            liveBaseline: baseline.liveBaseline,
            previousLoginCookies: baseline.loginCookies,
            previousLiveSnapshotFingerprint: baseline.authSnapshot?.stabilityFingerprint
        ) else {
            if await CookieArchiveWriteQueue.shared
                .consumeLoginTransactionSetupCleanupRequirement()
            {
                self.loginCookieBackupSetupRequiresCleanup = true
                _ = await CookieArchiveWriteQueue.shared.invalidateAndDelete()
            }
            return nil
        }
        let baselineChanged = await self.loginCookieBackupBaselineChanged(baseline)
        guard !self.isClearingAuthCookies,
              self.authCookieOperationFence.isCurrent(expectedOperationGeneration),
              !Task.isCancelled
        else {
            if baselineChanged {
                await self.abandonUnstableLoginCookieBackup(transaction)
            } else if self.isClearingAuthCookies
                || !self.authCookieOperationFence.isCurrent(expectedOperationGeneration)
            {
                _ = await CookieArchiveWriteQueue.shared.abandonLoginTransaction(transaction)
            } else if await CookieArchiveWriteQueue.shared.claimLoginTransactionRollback(transaction) {
                let didRollback = await CookieArchiveWriteQueue.shared
                    .rollbackLoginTransaction(transaction)
                if !didRollback {
                    self.loginCookieBackupSetupRequiresCleanup = true
                    _ = await CookieArchiveWriteQueue.shared.invalidateAndDelete()
                }
            }
            return nil
        }
        guard !baselineChanged else {
            await self.abandonUnstableLoginCookieBackup(transaction)
            return nil
        }

        self.loginCookieBackupSetupRequiresCleanup = false
        self.forcedCookieBackupDirty = false
        self.activeLoginCookieBackupTransaction = transaction
        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = nil
        return transaction
    }

    private func captureLoginCookieBackupBaseline(
        expectedOperationGeneration: UInt64
    ) async -> LoginCookieBackupBaseline? {
        let allLiveCookies = await self.dataStore.httpCookieStore.allCookies()
        guard !self.isClearingAuthCookies,
              self.authCookieOperationFence.isCurrent(expectedOperationGeneration),
              !Task.isCancelled
        else { return nil }

        let authCookies = allLiveCookies.filter(KeychainCookieStorage.isAuthCookie)
        let loginCookies = allLiveCookies.filter(KeychainCookieStorage.isLoginDomainCookie)
        if authCookies.isEmpty {
            return LoginCookieBackupBaseline(
                liveBaseline: .empty,
                authSnapshot: nil,
                loginCookies: loginCookies
            )
        }
        guard let snapshot = CookieArchiveSnapshot.make(from: authCookies) else {
            self.loginCookieBackupSetupRequiresCleanup = true
            return nil
        }
        return LoginCookieBackupBaseline(
            liveBaseline: .archive(snapshot.data),
            authSnapshot: snapshot,
            loginCookies: loginCookies
        )
    }

    private func loginCookieBackupBaselineChanged(
        _ baseline: LoginCookieBackupBaseline
    ) async -> Bool {
        var baselineChanged = true
        for _ in 0 ..< 3 {
            self.forcedCookieBackupDirty = false
            let verificationCookies = await self.dataStore.httpCookieStore.allCookies()
            baselineChanged = !Self.loginCookieBaselineMatches(
                expectedAuthSnapshot: baseline.authSnapshot,
                expectedLoginCookies: baseline.loginCookies,
                currentCookies: verificationCookies
            )
            if baselineChanged || !self.forcedCookieBackupDirty {
                break
            }
        }
        return baselineChanged
    }

    private func abandonUnstableLoginCookieBackup(
        _ transaction: CookieBackupTransaction
    ) async {
        let didAbandon = await CookieArchiveWriteQueue.shared
            .abandonLoginTransaction(transaction)
        self.loginCookieBackupSetupRequiresCleanup = true
        if !didAbandon {
            _ = await CookieArchiveWriteQueue.shared.invalidateAndDelete()
        }
    }

    static func loginCookieBaselineMatches(
        expectedAuthSnapshot: CookieArchiveSnapshot?,
        expectedLoginCookies: [HTTPCookie],
        currentCookies: [HTTPCookie]
    ) -> Bool {
        let currentAuthCookies = currentCookies.filter(KeychainCookieStorage.isAuthCookie)
        let currentAuthSnapshot = CookieArchiveSnapshot.make(from: currentAuthCookies)
        let authSnapshotMatches = expectedAuthSnapshot?.stabilityFingerprint
            == currentAuthSnapshot?.stabilityFingerprint
        let expectedLoginState = LoginCookieVerificationState.make(from: expectedLoginCookies)
        let currentLoginState = LoginCookieVerificationState.make(from: currentCookies)
        return authSnapshotMatches && expectedLoginState == currentLoginState
    }

    func isLoginCookieBackupActive(_ transaction: CookieBackupTransaction) async -> Bool {
        let queueOwnsTransaction = await CookieArchiveWriteQueue.shared
            .isActiveLoginTransaction(transaction)
        return self.isCurrentLoginCookieBackup(transaction) && queueOwnsTransaction
    }

    func hasLoginCookieSnapshotChanged(_ transaction: CookieBackupTransaction) async -> Bool {
        guard self.isCurrentLoginCookieBackup(transaction),
              !Task.isCancelled,
              let snapshot = await self.currentCookieArchiveSnapshot()
        else { return false }
        return transaction.hasChangedFromPreviousLiveSnapshot(snapshot)
    }

    /// Captures and persists a fresh stable snapshot while the transaction keeps
    /// startup restoration disabled.
    func refreshLoginCookieBackup(_ transaction: CookieBackupTransaction) async -> Bool {
        guard self.isCurrentLoginCookieBackup(transaction) else { return false }
        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = nil
        let didPersist = await self.forceBackupCookies()
        return didPersist && self.isCurrentLoginCookieBackup(transaction)
    }

    @discardableResult
    func commitLoginCookieBackup(
        _ transaction: CookieBackupTransaction
    ) async -> String? {
        for _ in 0 ..< 5 {
            guard self.isCurrentLoginCookieBackup(transaction),
                  !transaction.isCommitRevoked,
                  !Task.isCancelled
            else {
                return nil
            }
            guard let attempt = await self.makeCurrentCookieArchiveWriteAttempt(),
                  let committedSessionValue = attempt.snapshot.primarySessionValue
            else {
                return nil
            }
            let saveResult = await self.persistCookieArchiveAttempt(attempt)
            guard saveResult.isPersisted,
                  self.isCurrentLoginCookieBackup(transaction),
                  !Task.isCancelled,
                  let verificationSnapshot = await self.currentCookieArchiveSnapshot(),
                  !Task.isCancelled,
                  attempt.snapshot == verificationSnapshot
            else {
                continue
            }
            guard self.isCurrentLoginCookieBackup(transaction),
                  !Task.isCancelled,
                  let postCommitSnapshot = await self.currentCookieArchiveSnapshot(),
                  attempt.snapshot == postCommitSnapshot
            else {
                _ = await CookieArchiveWriteQueue.shared
                    .disableLoginTransactionRestore(transaction)
                return nil
            }
            return committedSessionValue
        }

        self.logger.error("Authentication cookies changed repeatedly during login commit")
        return nil
    }

    func finalizeLoginCookieBackup(
        _ transaction: CookieBackupTransaction
    ) async -> String? {
        guard self.isCurrentLoginCookieBackup(transaction),
              !Task.isCancelled,
              await CookieArchiveWriteQueue.shared
              .disableLoginTransactionRestore(transaction),
              await self.commitLoginCookieBackup(transaction) != nil
        else {
            return nil
        }
        if self.forcedCookieBackupDirty {
            guard let refreshedSnapshot = await self.refreshPersistedSnapshot(),
                  transaction.hasChangedFromPreviousLiveSnapshot(refreshedSnapshot)
            else {
                return nil
            }
        }
        guard self.isCurrentLoginCookieBackup(transaction),
              !Task.isCancelled
        else { return nil }

        // Persist and re-read one last stable snapshot while restoration remains
        // disabled. Finalization enables restoration as its last atomic step, so
        // cancellation can never make an unconfirmed login restorable.
        guard let postFinalizeSnapshot = await self.refreshPersistedSnapshot(),
              transaction.hasChangedFromPreviousLiveSnapshot(postFinalizeSnapshot),
              let postFinalizeSessionValue = postFinalizeSnapshot.primarySessionValue,
              self.isCurrentLoginCookieBackup(transaction),
              !Task.isCancelled
        else { return nil }

        let didFinalize = await CookieArchiveWriteQueue.shared.finalizeLoginTransaction(transaction)
        guard didFinalize,
              self.isCurrentLoginCookieBackup(transaction),
              !self.forcedCookieBackupDirty,
              !Task.isCancelled
        else {
            if didFinalize {
                _ = self.invalidateAuthCookieRestoration()
                self.activeLoginCookieBackupTransaction = nil
            }
            return nil
        }

        self.activeLoginCookieBackupTransaction = nil
        return postFinalizeSessionValue
    }

    private func refreshPersistedSnapshot() async -> CookieArchiveSnapshot? {
        for _ in 0 ..< 3 {
            self.forcedCookieBackupDirty = false
            guard await self.forceBackupCookies(),
                  let archiveData = await CookieArchiveWriteQueue.shared.persistedArchiveData()
            else {
                return nil
            }
            guard !self.forcedCookieBackupDirty else { continue }
            let cookies = KeychainCookieStorage.decodeCookies(from: archiveData)
            return CookieArchiveSnapshot.make(from: cookies)
        }
        return nil
    }

    func prepareLoginCookieBackupRollback(
        _ transaction: CookieBackupTransaction
    ) async -> Bool {
        guard self.isCurrentLoginCookieBackup(transaction) else {
            return true
        }
        if await CookieArchiveWriteQueue.shared.disableLoginTransactionRestore(transaction) {
            return true
        }
        guard self.isCurrentLoginCookieBackup(transaction) else {
            return true
        }
        return self.invalidateAuthCookieRestoration()
    }

    func rollbackLoginCookieBackup(
        _ transaction: CookieBackupTransaction
    ) async -> CookieBackupRollbackResult {
        guard self.isCurrentLoginCookieBackup(transaction) else {
            return .superseded
        }
        guard await CookieArchiveWriteQueue.shared.claimLoginTransactionRollback(transaction) else {
            let ownership = await CookieArchiveWriteQueue.shared
                .loginTransactionOwnership(transaction)
            return ownership == .none ? .failed : .superseded
        }

        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = nil
        let wasClearingAuthCookies = self.isClearingAuthCookies
        self.isClearingAuthCookies = true
        defer {
            if self.isCurrentLoginCookieBackup(transaction) {
                self.isClearingAuthCookies = wasClearingAuthCookies
            }
        }

        let expirationCutoff = Date()
        let previousCookies = transaction.loginCookiesBeforeAttempt().filter { cookie in
            guard let expiresDate = cookie.expiresDate else { return true }
            return expiresDate > expirationCutoff
        }
        let expectedState = LoginCookieVerificationState.make(
            from: previousCookies,
            expirationCutoff: expirationCutoff
        )
        switch await self.restoreLiveCookies(
            previousCookies,
            expectedState: expectedState,
            expirationCutoff: expirationCutoff,
            transaction: transaction
        ) {
        case .restored:
            break
        case .superseded:
            return .superseded
        case .failed:
            return await self.failLoginCookieBackupRollback(
                transaction,
                restoringClearingStateTo: wasClearingAuthCookies
            )
        }

        let didRollback = await CookieArchiveWriteQueue.shared.rollbackLoginTransaction(transaction)
        guard self.isCurrentLoginCookieBackup(transaction) else { return .superseded }
        guard didRollback else {
            self.isClearingAuthCookies = wasClearingAuthCookies
            self.activeLoginCookieBackupTransaction = nil
            self.logger.error("Could not restore the prior cookie backup after login cancellation")
            return .failed
        }

        let postRollbackCookies = await self.dataStore.httpCookieStore.allCookies()
        guard self.isCurrentLoginCookieBackup(transaction) else { return .superseded }
        let postRollbackState = LoginCookieVerificationState.make(
            from: postRollbackCookies,
            expirationCutoff: expirationCutoff
        )
        guard postRollbackState == expectedState else {
            _ = await CookieArchiveWriteQueue.shared.invalidateAndDelete()
            self.isClearingAuthCookies = wasClearingAuthCookies
            self.activeLoginCookieBackupTransaction = nil
            self.logger.error("Authentication cookies changed during login rollback")
            return .failed
        }

        self.isClearingAuthCookies = wasClearingAuthCookies
        self.activeLoginCookieBackupTransaction = nil
        return .rolledBack
    }

    private func restoreLiveCookies(
        _ previousCookies: [HTTPCookie],
        expectedState: LoginCookieVerificationState,
        expirationCutoff: Date,
        transaction: CookieBackupTransaction
    ) async -> LiveCookieRollbackResult {
        for _ in 0 ..< 3 {
            let currentCookies = await self.dataStore.httpCookieStore.allCookies()
            guard self.isCurrentLoginCookieBackup(transaction) else { return .superseded }
            for cookie in currentCookies where KeychainCookieStorage.isLoginDomainCookie(cookie) {
                await self.dataStore.httpCookieStore.deleteCookie(cookie)
                guard self.isCurrentLoginCookieBackup(transaction) else { return .superseded }
            }
            for cookie in previousCookies {
                await self.dataStore.httpCookieStore.setCookie(cookie)
                guard self.isCurrentLoginCookieBackup(transaction) else { return .superseded }
            }
            await Task.yield()
            let verificationCookies = await self.dataStore.httpCookieStore.allCookies()
            let verificationState = LoginCookieVerificationState.make(
                from: verificationCookies,
                expirationCutoff: expirationCutoff
            )
            if verificationState == expectedState {
                return .restored
            }
        }
        return .failed
    }

    private func failLoginCookieBackupRollback(
        _ transaction: CookieBackupTransaction,
        restoringClearingStateTo wasClearingAuthCookies: Bool
    ) async -> CookieBackupRollbackResult {
        _ = await CookieArchiveWriteQueue.shared.failLoginTransactionRollback(transaction)
        self.isClearingAuthCookies = wasClearingAuthCookies
        self.activeLoginCookieBackupTransaction = nil
        return .failed
    }

    private func isCurrentLoginCookieBackup(_ transaction: CookieBackupTransaction) -> Bool {
        self.activeLoginCookieBackupTransaction?.matches(transaction) == true
    }

    /// Forces an immediate save of a stable YouTube/Google cookie snapshot.
    func forceBackupCookies() async -> Bool {
        guard !self.isClearingAuthCookies else { return false }

        if let forcedCookieBackupTask {
            // A later caller establishes a newer freshness boundary even if
            // WebKit has not delivered its cookie-change callback yet.
            self.forcedCookieBackupDirty = true
            return await forcedCookieBackupTask.value
        }

        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.forcedCookieBackupTask = nil }

            let result = await CookieBackupStabilizer.persistStableSnapshot(
                maxAttempts: 5,
                operations: CookieBackupStabilizer.Operations(
                    prepareAttempt: {
                        self.forcedCookieBackupDirty = false
                    },
                    makeAttempt: {
                        await self.makeCurrentCookieArchiveWriteAttempt()
                    },
                    persist: { attempt in
                        await self.persistCookieArchiveAttempt(attempt)
                    },
                    readVerificationSnapshot: {
                        await self.currentCookieArchiveSnapshot()
                    },
                    isDirty: {
                        self.forcedCookieBackupDirty
                    },
                    canContinue: {
                        !Task.isCancelled && !self.isClearingAuthCookies
                    }
                )
            )

            switch result {
            case .persisted:
                // A callback that lands after the stabilizer's final read remains
                // dirty; fail closed so the caller retries instead of erasing it.
                return !self.forcedCookieBackupDirty
            case .cancelled:
                return false
            case .failed:
                self.logger.error("Forced cookie backup failed")
                return false
            case .unstable:
                self.logger.error("Forced cookie backup did not reach a stable snapshot")
                return false
            }
        }
        self.forcedCookieBackupTask = task
        return await task.value
    }

    private func makeCurrentCookieArchiveWriteAttempt() async -> CookieArchiveWriteAttempt? {
        let generation = await CookieArchiveWriteQueue.shared.reserveGeneration()
        guard let snapshot = await self.currentCookieArchiveSnapshot() else { return nil }
        return CookieArchiveWriteAttempt(snapshot: snapshot, generation: generation)
    }

    private func currentCookieArchiveSnapshot() async -> CookieArchiveSnapshot? {
        let cookies = await self.dataStore.httpCookieStore.allCookies()
        let authCookies = cookies.filter(KeychainCookieStorage.isAuthCookie)
        return CookieArchiveSnapshot.make(from: authCookies)
    }

    private func persistCookieArchiveAttempt(
        _ attempt: CookieArchiveWriteAttempt
    ) async -> CookieArchiveSaveResult {
        await CookieArchiveWriteQueue.shared.save(
            archiveData: attempt.snapshot.data,
            cookieCount: attempt.snapshot.cookieCount,
            generation: attempt.generation
        )
    }
}

// MARK: - WebKitManager + WKHTTPCookieStoreObserver

extension WebKitManager: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in
            self.handleObservedCookieChange(in: cookieStore)
        }
    }

    func handleObservedCookieChange(in cookieStore: WKHTTPCookieStore) {
        self.recordCookieChange()

        guard !self.isRestoringCookies, !self.isClearingAuthCookies else { return }
        if self.isPreparingLoginCookieBackup
            || self.activeLoginCookieBackupTransaction != nil
            || self.forcedCookieBackupTask != nil
        {
            self.forcedCookieBackupDirty = true
            return
        }

        // WebKit fires once per individual cookie change, so debounce the backup.
        self.cookieDebounceTask?.cancel()
        self.cookieDebounceTask = Task {
            do {
                try await Task.sleep(for: Self.cookieDebounceInterval)
            } catch is CancellationError {
                return
            } catch {
                self.logger.warning("Unexpected error during cookie debounce: \(error.localizedDescription)")
            }

            guard !Task.isCancelled else { return }
            await self.performCookieBackup(cookieStore: cookieStore)
        }
    }

    private func performCookieBackup(cookieStore: WKHTTPCookieStore) async {
        guard !self.isClearingAuthCookies else { return }
        let generation = await CookieArchiveWriteQueue.shared.reserveGeneration()
        let cookies = await cookieStore.allCookies()
        guard !Task.isCancelled, !self.isClearingAuthCookies else { return }
        let authCookies = cookies.filter(KeychainCookieStorage.isAuthCookie)
        let action = CookieArchiveBackupAction.make(
            from: KeychainCookieStorage.makeArchiveResult(from: authCookies)
        )
        switch action {
        case .invalidate:
            let result = await CookieArchiveWriteQueue.shared.invalidateAndDeleteIfLatest(
                generation: generation
            )
            if result == .failed {
                self.logger.error("Could not invalidate an empty authentication-cookie snapshot")
            }
        case .retainExisting:
            self.logger.error("Retaining the last authentication-cookie archive after serialization failure")
        case let .persist(data, cookieCount):
            guard !Task.isCancelled, !self.isClearingAuthCookies else { return }
            _ = await CookieArchiveWriteQueue.shared.save(
                archiveData: data,
                cookieCount: cookieCount,
                generation: generation
            )
        }
    }
}
