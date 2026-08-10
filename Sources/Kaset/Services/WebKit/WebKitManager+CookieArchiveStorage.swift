import Foundation

// MARK: - CookieBackupRollbackResult

enum CookieBackupRollbackResult: Equatable, Sendable {
    case rolledBack
    case cleared
    case superseded
    case failed
}

// MARK: - CookieArchiveRollbackState

private struct CookieArchiveRollbackState: Sendable {
    let archiveData: Data?
    let wasRestoreAllowed: Bool
}

// MARK: - CookieArchiveLiveBaseline

enum CookieArchiveLiveBaseline: Sendable {
    case empty
    case archive(Data)
    case persistedArchive
}

// MARK: - CookieBackupCommitFence

private final class CookieBackupCommitFence: @unchecked Sendable {
    private let lock = NSLock()
    private let disableRestore: @Sendable () -> Bool
    private var isRevoked = false

    init(disableRestore: @escaping @Sendable () -> Bool) {
        self.disableRestore = disableRestore
    }

    func revoke() -> Bool {
        self.lock.withLock {
            self.isRevoked = true
            return self.disableRestore()
        }
    }

    func restoreIfActive(_ operation: () -> Bool) -> Bool {
        self.lock.withLock {
            guard !self.isRevoked else { return false }
            return operation()
        }
    }

    var revoked: Bool {
        self.lock.withLock { self.isRevoked }
    }
}

// MARK: - CookieBackupTransaction

/// In-memory rollback handle for one login-cookie persistence attempt.
/// Its archive contents are intentionally inaccessible and unprintable.
struct CookieBackupTransaction: Sendable {
    fileprivate let id: UInt64
    fileprivate let rollbackState: CookieArchiveRollbackState
    fileprivate let previousLiveArchiveData: Data?
    fileprivate let previousLoginCookies: [HTTPCookie]
    fileprivate let restorePolicyGeneration: UInt64
    fileprivate let commitFence: CookieBackupCommitFence
    fileprivate let previousLiveSnapshotFingerprint: Data?

    var hadPreviousArchive: Bool {
        self.rollbackState.archiveData != nil
    }

    var wasPreviouslyRestorable: Bool {
        self.rollbackState.wasRestoreAllowed
    }

    func loginCookiesBeforeAttempt() -> [HTTPCookie] {
        self.previousLoginCookies
    }

    func hasChangedFromPreviousLiveSnapshot(_ snapshot: CookieArchiveSnapshot) -> Bool {
        guard let previousLiveSnapshotFingerprint else { return true }
        return snapshot.stabilityFingerprint != previousLiveSnapshotFingerprint
    }

    func matches(_ other: CookieBackupTransaction) -> Bool {
        self.id == other.id
    }

    @discardableResult
    func revokeCommit() -> Bool {
        self.commitFence.revoke()
    }

    var isCommitRevoked: Bool {
        self.commitFence.revoked
    }

    fileprivate func restoreIfCommitActive(_ operation: () -> Bool) -> Bool {
        self.commitFence.restoreIfActive(operation)
    }
}

// MARK: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable

#if DEBUG
    extension CookieBackupTransaction {
        static func testing(
            id: UInt64 = 1,
            previousLiveSnapshotFingerprint: Data? = nil
        ) -> CookieBackupTransaction {
            CookieBackupTransaction(
                id: id,
                rollbackState: CookieArchiveRollbackState(
                    archiveData: nil,
                    wasRestoreAllowed: false
                ),
                previousLiveArchiveData: nil,
                previousLoginCookies: [],
                restorePolicyGeneration: CookieArchiveRestorePolicy.generation,
                commitFence: CookieBackupCommitFence(disableRestore: { true }),
                previousLiveSnapshotFingerprint: previousLiveSnapshotFingerprint
            )
        }
    }
#endif

// MARK: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable

extension CookieBackupTransaction: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String {
        "<redacted cookie backup transaction>"
    }

    var debugDescription: String {
        self.description
    }

    var customMirror: Mirror {
        Mirror(reflecting: self.description)
    }
}

// MARK: - CookieArchiveRestoreGenerationState

private final class CookieArchiveRestoreGenerationState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func current() -> UInt64 {
        self.lock.withLock { self.generation }
    }

    func invalidate(
        operation: () -> Bool
    ) -> Bool {
        self.lock.withLock {
            self.generation &+= 1
            return operation()
        }
    }

    func performIfCurrent(
        _ expectedGeneration: UInt64,
        operation: () -> Bool
    ) -> Bool {
        self.lock.withLock {
            guard self.generation == expectedGeneration else { return false }
            return operation()
        }
    }
}

// MARK: - CookieArchiveRestoreDecision

enum CookieArchiveRestoreDecision: Equatable, Sendable {
    case allowed
    case denied
    case unavailable
}

// MARK: - CookieArchiveRestorePolicy

enum CookieArchiveRestorePolicy {
    private static let invalidatedKey = "authCookieBackupInvalidated"
    private static let generationState = CookieArchiveRestoreGenerationState()

    static var generation: UInt64 {
        self.generationState.current()
    }

    @discardableResult
    static func invalidateAndAdvanceGeneration() -> Bool {
        self.generationState.invalidate {
            self.setRestoreAllowed(false)
        }
    }

    static func setRestoreAllowed(
        _: Bool,
        ifGenerationMatches expectedGeneration: UInt64,
        operation: () -> Bool
    ) -> Bool {
        self.generationState.performIfCurrent(expectedGeneration) {
            operation()
        }
    }

    static var restoreDecision: CookieArchiveRestoreDecision {
        if UITestConfig.isRunningUnitTests {
            return .allowed
        }
        let invalidationTombstonePresent = UserDefaults.standard.bool(forKey: self.invalidatedKey)
        guard !invalidationTombstonePresent else { return .denied }
        let restorePolicyGeneration = self.generation

        return self.resolveRestoreDecision(
            invalidationTombstonePresent: false,
            storedPolicy: CookieRestorePolicyStorage.loadResult(),
            archiveResult: { KeychainCookieStorage.loadArchiveResult() },
            migrateLegacyArchive: { archiveData in
                self.migrateLegacyArchivePolicy(
                    archiveData,
                    expectedGeneration: restorePolicyGeneration
                )
            }
        )
    }

    static func resolveRestoreDecision(
        invalidationTombstonePresent: Bool,
        storedPolicy: CookieRestorePolicyLoadResult,
        archiveResult: () -> CookieArchiveLoadResult,
        migrateLegacyArchive: (Data) -> CookieArchiveRestoreDecision
    ) -> CookieArchiveRestoreDecision {
        guard !invalidationTombstonePresent else { return .denied }

        switch storedPolicy {
        case .allowed:
            return .allowed
        case .denied:
            return .denied
        case .failure:
            return .unavailable
        case .notFound:
            switch archiveResult() {
            case .notFound:
                return .allowed
            case let .data(archiveData):
                return migrateLegacyArchive(archiveData)
            case .failure:
                return .unavailable
            }
        }
    }

    private static func migrateLegacyArchivePolicy(
        _ archiveData: Data,
        expectedGeneration: UInt64
    ) -> CookieArchiveRestoreDecision {
        self.migrateLegacyArchivePolicy(
            archiveData,
            expectedGeneration: expectedGeneration,
            savePolicy: { CookieRestorePolicyStorage.save(true) }
        )
    }

    static func migrateLegacyArchivePolicy(
        _ archiveData: Data,
        expectedGeneration: UInt64,
        savePolicy: () -> Bool
    ) -> CookieArchiveRestoreDecision {
        guard KeychainCookieStorage.isRestorableArchiveData(archiveData) else {
            return .denied
        }
        let didSave = self.generationState.performIfCurrent(expectedGeneration) {
            guard !UserDefaults.standard.bool(forKey: self.invalidatedKey) else {
                return false
            }
            return savePolicy()
        }
        guard self.generation == expectedGeneration,
              !UserDefaults.standard.bool(forKey: self.invalidatedKey)
        else {
            return .denied
        }
        return didSave ? .allowed : .unavailable
    }

    @discardableResult
    static func setRestoreAllowed(_ allowed: Bool) -> Bool {
        if UITestConfig.isRunningUnitTests {
            return true
        }
        if allowed {
            UserDefaults.standard.removeObject(forKey: self.invalidatedKey)
        } else {
            UserDefaults.standard.set(true, forKey: self.invalidatedKey)
        }
        _ = UserDefaults.standard.synchronize()
        return CookieRestorePolicyStorage.save(allowed)
    }
}

// MARK: - Synchronous Restoration Invalidation

extension WebKitManager {
    @discardableResult
    func invalidateAuthCookieRestoration() -> Bool {
        CookieArchiveRestorePolicy.invalidateAndAdvanceGeneration()
    }
}

// MARK: - CookieArchiveStorage

struct CookieArchiveStorage: Sendable {
    let save: @Sendable (Data, Int) -> Bool
    let load: @Sendable () -> Data?
    let delete: @Sendable () -> Bool
    let restoreDecision: @Sendable () -> CookieArchiveRestoreDecision
    let setRestoreAllowed: @Sendable (Bool) -> Bool
    let exportsDebugArchive: Bool
    let deleteDebugArchive: @Sendable () -> Bool

    init(
        save: @escaping @Sendable (Data, Int) -> Bool,
        load: @escaping @Sendable () -> Data?,
        delete: @escaping @Sendable () -> Bool,
        restoreDecision: @escaping @Sendable () -> CookieArchiveRestoreDecision = { .allowed },
        setRestoreAllowed: @escaping @Sendable (Bool) -> Bool = { _ in true },
        exportsDebugArchive: Bool = false,
        deleteDebugArchive: @escaping @Sendable () -> Bool = { true }
    ) {
        self.save = save
        self.load = load
        self.delete = delete
        self.restoreDecision = restoreDecision
        self.setRestoreAllowed = setRestoreAllowed
        self.exportsDebugArchive = exportsDebugArchive
        self.deleteDebugArchive = deleteDebugArchive
    }

    static let live = CookieArchiveStorage(
        save: { data, cookieCount in
            KeychainCookieStorage.saveArchiveData(data, cookieCount: cookieCount)
        },
        load: { KeychainCookieStorage.loadArchiveData() },
        delete: { KeychainCookieStorage.deleteCookies() },
        restoreDecision: { CookieArchiveRestorePolicy.restoreDecision },
        setRestoreAllowed: { CookieArchiveRestorePolicy.setRestoreAllowed($0) },
        exportsDebugArchive: true,
        deleteDebugArchive: {
            LegacyCookieMigration.deleteLegacyFileIfPresent()
        }
    )
}

// MARK: - CookieArchiveGenerationTracker

struct CookieArchiveGenerationTracker {
    private var nextGeneration: UInt64 = 0
    private(set) var latestReservedGeneration: UInt64 = 0

    mutating func reserveGeneration() -> UInt64 {
        self.nextGeneration &+= 1
        self.latestReservedGeneration = self.nextGeneration
        return self.nextGeneration
    }

    func isLatest(_ generation: UInt64) -> Bool {
        generation == self.latestReservedGeneration
    }
}

// MARK: - CookieBackupTransactionOwnership

enum CookieBackupTransactionOwnership: Equatable, Sendable {
    case active
    case rollingBack
    case none
}

// MARK: - CookieArchiveWriteQueue

/// Serializes live WebKit cookie snapshots and discards snapshots superseded
/// before they reach storage. Blocking file/Keychain work runs on this actor,
/// never on `MainActor`.
actor CookieArchiveWriteQueue {
    static let shared = CookieArchiveWriteQueue(storage: .live)

    private var generationTracker = CookieArchiveGenerationTracker()
    private var nextTransactionID: UInt64 = 0
    private var activeTransactionID: UInt64?
    private var rollingBackTransactionID: UInt64?
    private var loginTransactionSetupRequiresCleanup = false
    private let storage: CookieArchiveStorage

    init(storage: CookieArchiveStorage) {
        self.storage = storage
    }

    func reserveGeneration() -> UInt64 {
        self.generationTracker.reserveGeneration()
    }

    func restoreDecision() -> CookieArchiveRestoreDecision {
        self.storage.restoreDecision()
    }

    func isRestoreAllowed() -> Bool {
        self.storage.restoreDecision() == .allowed
    }

    func persistedArchiveData() -> Data? {
        self.storage.load()
    }

    func consumeLoginTransactionSetupCleanupRequirement() -> Bool {
        let requiresCleanup = self.loginTransactionSetupRequiresCleanup
        self.loginTransactionSetupRequiresCleanup = false
        return requiresCleanup
    }

    func isActiveLoginTransaction(_ transaction: CookieBackupTransaction) -> Bool {
        self.activeTransactionID == transaction.id
    }

    func loginTransactionOwnership(
        _ transaction: CookieBackupTransaction
    ) -> CookieBackupTransactionOwnership {
        if self.activeTransactionID == transaction.id {
            return .active
        }
        if self.rollingBackTransactionID == transaction.id {
            return .rollingBack
        }
        return .none
    }

    func beginLoginTransaction(
        liveBaseline: CookieArchiveLiveBaseline = .persistedArchive,
        previousLoginCookies: [HTTPCookie] = [],
        previousLiveSnapshotFingerprint: Data? = nil
    ) -> CookieBackupTransaction? {
        guard self.activeTransactionID == nil,
              self.rollingBackTransactionID == nil
        else { return nil }
        self.loginTransactionSetupRequiresCleanup = false
        self.nextTransactionID &+= 1
        let restorePolicyGeneration = CookieArchiveRestorePolicy.generation
        let wasRestoreAllowed = self.storage.restoreDecision() == .allowed
        let persistedArchiveData = self.storage.load()
        let capturedLiveArchiveData: Data? = switch liveBaseline {
        case .empty:
            nil
        case let .archive(data):
            data
        case .persistedArchive:
            persistedArchiveData
        }
        let rollbackArchiveData = wasRestoreAllowed
            ? capturedLiveArchiveData
            : persistedArchiveData
        let disableRestore = self.storage.setRestoreAllowed
        let transaction = CookieBackupTransaction(
            id: self.nextTransactionID,
            rollbackState: CookieArchiveRollbackState(
                archiveData: rollbackArchiveData,
                wasRestoreAllowed: wasRestoreAllowed
            ),
            previousLiveArchiveData: capturedLiveArchiveData,
            previousLoginCookies: previousLoginCookies,
            restorePolicyGeneration: restorePolicyGeneration,
            commitFence: CookieBackupCommitFence(
                disableRestore: {
                    disableRestore(false)
                }
            ),
            previousLiveSnapshotFingerprint: previousLiveSnapshotFingerprint
        )
        self.activeTransactionID = transaction.id
        _ = self.generationTracker.reserveGeneration()
        guard transaction.restorePolicyGeneration == CookieArchiveRestorePolicy.generation else {
            self.activeTransactionID = nil
            return nil
        }
        guard self.storage.setRestoreAllowed(false) else {
            let didRestorePriorPolicy = CookieArchiveRestorePolicy.setRestoreAllowed(
                wasRestoreAllowed,
                ifGenerationMatches: transaction.restorePolicyGeneration,
                operation: {
                    self.storage.setRestoreAllowed(wasRestoreAllowed)
                }
            )
            self.loginTransactionSetupRequiresCleanup = !didRestorePriorPolicy
            self.activeTransactionID = nil
            return nil
        }
        return transaction
    }

    @discardableResult
    func disableLoginTransactionRestore(_ transaction: CookieBackupTransaction) -> Bool {
        guard self.activeTransactionID == transaction.id else { return false }
        return self.storage.setRestoreAllowed(false)
    }

    @discardableResult
    func finalizeLoginTransaction(_ transaction: CookieBackupTransaction) -> Bool {
        guard self.activeTransactionID == transaction.id,
              !Task.isCancelled,
              transaction.restorePolicyGeneration == CookieArchiveRestorePolicy.generation
        else {
            _ = self.storage.setRestoreAllowed(false)
            return false
        }
        guard transaction.restoreIfCommitActive({
            CookieArchiveRestorePolicy.setRestoreAllowed(
                true,
                ifGenerationMatches: transaction.restorePolicyGeneration,
                operation: {
                    self.storage.setRestoreAllowed(true)
                }
            )
        }) else {
            _ = self.storage.setRestoreAllowed(false)
            return false
        }
        #if DEBUG
            if self.storage.exportsDebugArchive {
                if let archiveData = self.storage.load() {
                    DebugCookieFileExporter.exportAuthCookiesArchiveData(archiveData)
                } else {
                    DebugCookieFileExporter.deleteExport()
                }
            }
        #endif
        self.activeTransactionID = nil
        return true
    }

    @discardableResult
    func claimLoginTransactionRollback(_ transaction: CookieBackupTransaction) -> Bool {
        guard self.activeTransactionID == transaction.id else { return false }
        self.activeTransactionID = nil
        self.rollingBackTransactionID = transaction.id
        _ = self.generationTracker.reserveGeneration()
        return true
    }

    @discardableResult
    func failLoginTransactionRollback(_ transaction: CookieBackupTransaction) -> Bool {
        guard self.rollingBackTransactionID == transaction.id else { return false }
        self.rollingBackTransactionID = nil
        _ = self.generationTracker.reserveGeneration()
        return self.storage.setRestoreAllowed(false)
    }

    @discardableResult
    func rollbackLoginTransaction(_ transaction: CookieBackupTransaction) -> Bool {
        guard self.rollingBackTransactionID == transaction.id else { return false }

        let didRestoreArchive: Bool = if let archiveData = transaction.rollbackState.archiveData {
            self.storage.save(archiveData, 0)
                || self.storage.load() == archiveData
        } else {
            self.storage.delete()
        }
        guard didRestoreArchive else {
            _ = self.storage.setRestoreAllowed(false)
            self.rollingBackTransactionID = nil
            return false
        }

        let didRestorePolicy = CookieArchiveRestorePolicy.setRestoreAllowed(
            transaction.rollbackState.wasRestoreAllowed,
            ifGenerationMatches: transaction.restorePolicyGeneration,
            operation: {
                self.storage.setRestoreAllowed(
                    transaction.rollbackState.wasRestoreAllowed
                )
            }
        )
        if !didRestorePolicy {
            _ = self.storage.setRestoreAllowed(false)
        }
        #if DEBUG
            if self.storage.exportsDebugArchive {
                if didRestorePolicy,
                   transaction.rollbackState.wasRestoreAllowed,
                   let archiveData = transaction.rollbackState.archiveData
                {
                    DebugCookieFileExporter.exportAuthCookiesArchiveData(archiveData)
                } else {
                    DebugCookieFileExporter.deleteExport()
                }
            }
        #endif
        self.rollingBackTransactionID = nil
        return didRestorePolicy
    }

    @discardableResult
    func abandonLoginTransaction(_ transaction: CookieBackupTransaction) -> Bool {
        let ownsTransaction = self.activeTransactionID == transaction.id
            || self.rollingBackTransactionID == transaction.id
        guard ownsTransaction else { return false }
        self.activeTransactionID = nil
        self.rollingBackTransactionID = nil
        _ = self.generationTracker.reserveGeneration()
        return self.storage.setRestoreAllowed(false)
    }

    func invalidateAndDeleteIfLatest(
        generation: UInt64
    ) -> CookieArchiveSaveResult {
        guard self.generationTracker.isLatest(generation),
              self.activeTransactionID == nil,
              self.rollingBackTransactionID == nil
        else {
            return .superseded
        }

        let didInvalidateRestore = self.storage.setRestoreAllowed(false)
        let didDelete = self.storage.delete()
        let didDeleteDebugArchive = !self.storage.exportsDebugArchive
            || self.storage.deleteDebugArchive()
        return didInvalidateRestore && didDelete && didDeleteDebugArchive
            ? .saved
            : .failed
    }

    @discardableResult
    func invalidateAndDelete() -> Bool {
        self.activeTransactionID = nil
        self.rollingBackTransactionID = nil
        _ = self.generationTracker.reserveGeneration()
        let didInvalidateRestore = self.storage.setRestoreAllowed(false)
        let didDelete = self.storage.delete()
        let didDeleteDebugArchive = !self.storage.exportsDebugArchive
            || self.storage.deleteDebugArchive()
        return didInvalidateRestore && didDelete && didDeleteDebugArchive
    }

    func save(
        archiveData: Data,
        cookieCount: Int,
        generation: UInt64
    ) -> CookieArchiveSaveResult {
        guard self.generationTracker.isLatest(generation) else {
            return .superseded
        }

        let didSave = self.storage.save(archiveData, cookieCount)
        let result: CookieArchiveSaveResult = if didSave {
            .saved
        } else if self.storage.load() == archiveData {
            .alreadyCurrent
        } else {
            .failed
        }

        #if DEBUG
            if result.isPersisted,
               self.storage.exportsDebugArchive,
               self.activeTransactionID == nil,
               self.rollingBackTransactionID == nil
            {
                DebugCookieFileExporter.exportAuthCookiesArchiveData(archiveData)
            }
        #endif
        return result
    }
}
