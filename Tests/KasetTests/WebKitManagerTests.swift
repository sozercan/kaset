import Foundation
import Testing
import WebKit
@testable import Kaset

// MARK: - WebKitManagerTests

/// Tests for WebKitManager.
@Suite(.serialized, .tags(.service))
@MainActor
struct WebKitManagerTests {
    var webKitManager: WebKitManager

    init() {
        self.webKitManager = WebKitManager.makeTestInstance()
    }

    @Test("Test instance uses non-persistent data store")
    func instanceUsesNonPersistentDataStore() {
        #expect(self.webKitManager.dataStore.isPersistent == false)
    }

    @Test("Test instance starts without loaded extensions")
    func instanceStartsWithoutLoadedExtensions() {
        #expect(self.webKitManager.isExtensionLoaded == false)
        #expect(self.webKitManager.loadedExtensionCount == 0)
    }

    @Test("Create WebView configuration")
    func createWebViewConfiguration() {
        let configuration = self.webKitManager.createWebViewConfiguration()
        #expect(configuration.websiteDataStore === self.webKitManager.dataStore)
    }

    @Test("Extension host registers playback WebViews as extension-visible tabs")
    @MainActor
    func extensionHostRegistersPlaybackWebViews() {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                let controller = WKWebExtensionController()
                let host = KasetWebExtensionHost(controller: controller)
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.webExtensionController = controller

                let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: configuration)
                let tab = host.register(webView: webView, role: .musicPlayer)

                #expect(tab != nil)
                #expect(host.registeredTabCount == 1)
                #expect(host.openWindows.count == 1)
                #expect(host.focusedWindow != nil)

                // Re-registering the same WebView should activate the existing tab, not create another one.
                _ = host.register(webView: webView, role: .musicPlayer)
                #expect(host.registeredTabCount == 1)

                // Rebuilding the playback WebView for the same role should replace the tab's target,
                // not leave a stale ghost tab behind.
                let replacementWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: configuration)
                _ = host.register(webView: replacementWebView, role: .musicPlayer)
                #expect(host.registeredTabCount == 1)
            }
        #endif
    }

    @Test("Extension window does not invent an active tab after deactivation")
    @MainActor
    func extensionWindowDoesNotInventActiveTab() async throws {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                let tempDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("KasetWebExtensionWindowTests-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tempDirectory) }

                let manifest: [String: Any] = [
                    "manifest_version": 3,
                    "name": "Window Active Tab Test",
                    "description": "Test extension",
                    "version": "1.0",
                ]
                let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
                try manifestData.write(to: tempDirectory.appendingPathComponent("manifest.json"))

                let webExtension = try await WKWebExtension(resourceBaseURL: tempDirectory)
                let context = WKWebExtensionContext(for: webExtension)

                let window = KasetWebExtensionWindow()
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: configuration)
                let tab = KasetWebExtensionTab(role: .youtubeWatch, webView: webView)
                window.append(tab)

                #expect(window.activeTab(for: context) != nil)

                window.activeTab = nil

                #expect(window.activeTab(for: context) == nil)
            }
        #endif
    }

    @Test("Content script match patterns are extracted for permission grants")
    @MainActor
    func contentScriptMatchPatternsAreExtracted() {
        #if compiler(>=5.9)
            if #available(macOS 15.4, *) {
                let manifest: [AnyHashable: Any] = [
                    "content_scripts": [
                        [
                            "matches": [
                                "https://*.youtube.com/*",
                                "https://www.youtube-nocookie.com/embed/*",
                                "https://*.youtube.com/*",
                            ],
                        ],
                    ],
                ]

                let patterns = WebKitManager.contentScriptMatchPatterns(from: manifest).map(\.string).sorted()

                #expect(patterns == [
                    "https://*.youtube.com/*",
                    "https://www.youtube-nocookie.com/embed/*",
                ])
            }
        #endif
    }

    @Test("Session switch WebView configuration excludes extensions")
    func createSessionSwitchWebViewConfiguration() {
        let configuration = self.webKitManager.createSessionSwitchWebViewConfiguration()
        #expect(configuration.websiteDataStore === self.webKitManager.dataStore)

        #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                #expect(configuration.webExtensionController == nil)
            }
        #endif
    }

    @Test("Origin constant")
    func originConstant() {
        #expect(WebKitManager.origin == "https://music.youtube.com")
    }

    @Test("Auth cookie name")
    func authCookieName() {
        #expect(WebKitManager.authCookieName == "__Secure-3PAPISID")
    }

    @Test("Get all cookies")
    func getAllCookies() async {
        let cookies = await self.webKitManager.getAllCookies()
        #expect(cookies.isEmpty)
    }

    @Test("Cookie header for domain")
    func cookieHeaderForDomain() async {
        // May be nil if no cookies are set
        // Just verify it doesn't crash
        _ = await self.webKitManager.cookieHeader(for: "youtube.com")
    }

    @Test("Has auth cookies")
    func hasAuthCookies() async {
        let hasAuth = await self.webKitManager.hasAuthCookies()
        #expect(hasAuth == false)
    }

    @Test("Authentication cookie clears coalesce while one is in flight")
    func authenticationCookieClearsCoalesce() async {
        let coordinator = AuthCookieClearCoordinator()
        let started = AsyncGate()
        let release = AsyncGate()
        let operationCount = LockedCounter()

        let first = Task { @MainActor in
            await coordinator.run(scope: .authenticationCookies) {
                operationCount.increment()
                await started.open()
                await release.wait()
                return true
            }
        }
        await started.wait()
        let second = Task { @MainActor in
            await coordinator.run(scope: .authenticationCookies) {
                Issue.record("A coalesced authentication clear ran twice")
                return false
            }
        }
        await Task.yield()
        await release.open()

        #expect(await first.value)
        #expect(await second.value)
        #expect(operationCount.count == 1)
        #expect(!coordinator.isBusy)
    }

    @Test("All-data clear waits for and escalates an authentication-only clear")
    func allDataClearEscalatesAfterAuthenticationClear() async {
        let coordinator = AuthCookieClearCoordinator()
        let started = AsyncGate()
        let release = AsyncGate()
        let authClearCount = LockedCounter()
        let allDataClearCount = LockedCounter()

        let authClear = Task { @MainActor in
            await coordinator.run(scope: .authenticationCookies) {
                authClearCount.increment()
                await started.open()
                await release.wait()
                return true
            }
        }
        await started.wait()
        let allDataClear = Task { @MainActor in
            await coordinator.run(scope: .allWebsiteData) {
                allDataClearCount.increment()
                return true
            }
        }
        let secondAllDataClear = Task { @MainActor in
            await coordinator.run(scope: .allWebsiteData) {
                Issue.record("A queued all-data clear ran twice")
                return false
            }
        }
        await Task.yield()
        #expect(allDataClearCount.isEmpty)
        await release.open()

        #expect(await authClear.value)
        #expect(await allDataClear.value)
        #expect(await secondAllDataClear.value)
        #expect(authClearCount.count == 1)
        #expect(allDataClearCount.count == 1)
        #expect(!coordinator.isBusy)
    }

    @Test("Login cookie transactions are rejected while authentication cookies are clearing")
    func loginCookieTransactionsAreRejectedDuringClear() async {
        self.webKitManager.isClearingAuthCookies = true

        let transaction = await self.webKitManager.beginLoginCookieBackup()

        #expect(transaction == nil)
    }

    @Test("Stale rollback preparation preserves a replacement restore policy")
    func staleRollbackPreparationPreservesReplacementRestorePolicy() async {
        let staleTransaction = CookieBackupTransaction.testing(id: 9001)
        let replacementTransaction = CookieBackupTransaction.testing(id: 9002)
        self.webKitManager.activeLoginCookieBackupTransaction = replacementTransaction
        let restorePolicyGeneration = CookieArchiveRestorePolicy.generation

        let prepared = await self.webKitManager.prepareLoginCookieBackupRollback(
            staleTransaction
        )

        #expect(prepared)
        #expect(CookieArchiveRestorePolicy.generation == restorePolicyGeneration)
        #expect(self.webKitManager.activeLoginCookieBackupTransaction?.matches(
            replacementTransaction
        ) == true)
    }

    @Test("Sticky auth-cookie deletion escalates to clearing the cookie data store")
    func stickyAuthCookieDeletionEscalates() async throws {
        let authCookie = try #require(HTTPCookie(properties: [
            .name: "SAPISID",
            .value: "mock-token",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        var cookies = [authCookie]
        var deleteCount = 0
        var fallbackCount = 0

        let result = await LiveAuthCookieStoreClearer.clear(
            operations: LiveAuthCookieStoreClearer.Operations(
                readCookies: { cookies },
                deleteCookie: { _ in
                    deleteCount += 1
                    // Simulate a sticky or immediately recreated cookie.
                },
                removeAllCookies: {
                    fallbackCount += 1
                    cookies = []
                }
            )
        )

        #expect(result.didClear)
        #expect(result.usedCookieStoreFallback)
        #expect(deleteCount == 3)
        #expect(fallbackCount == 1)
    }

    @Test("Cookie archive write coordinator skips duplicate pending saves and retries after failure")
    func cookieArchiveWriteCoordinatorRetriesAfterFailure() {
        let coordinator = CookieArchiveWriteCoordinator()
        let archive = Data([0x01, 0x02, 0x03])

        #expect(coordinator.beginSaveIfNeeded(archive) == true)
        #expect(coordinator.beginSaveIfNeeded(archive) == false)

        coordinator.finishSave(archive, success: false)

        #expect(coordinator.beginSaveIfNeeded(archive) == true)
    }

    @Test("Cookie archive write coordinator skips archives already persisted")
    func cookieArchiveWriteCoordinatorSkipsPersistedArchive() {
        let coordinator = CookieArchiveWriteCoordinator()
        let archive = Data([0x04, 0x05, 0x06])

        coordinator.seedPersistedArchive(archive)

        #expect(coordinator.beginSaveIfNeeded(archive) == false)
    }

    @Test("Auth cookie operation fence invalidates an in-flight startup restore")
    func authCookieOperationFenceInvalidatesRestore() {
        var fence = AuthCookieOperationFence()
        let restoreGeneration = fence.generation

        fence.invalidate()

        #expect(!fence.isCurrent(restoreGeneration))
        #expect(fence.isCurrent(fence.generation))
    }

    @Test("Cookie archive generation tracker rejects superseded snapshots")
    func cookieArchiveGenerationTrackerRejectsSupersededSnapshots() {
        var tracker = CookieArchiveGenerationTracker()

        let first = tracker.reserveGeneration()
        let second = tracker.reserveGeneration()

        #expect(first < second)
        #expect(!tracker.isLatest(first))
        #expect(tracker.isLatest(second))
    }

    @Test("Cookie archive queue prevents an older snapshot from overwriting a newer one")
    func cookieArchiveQueueRejectsSupersededWrite() async {
        let storage = InMemoryCookieArchiveStorage()
        let queue = CookieArchiveWriteQueue(storage: storage.interface)
        let olderGeneration = await queue.reserveGeneration()
        let newerGeneration = await queue.reserveGeneration()
        let olderArchive = Data([0x10])
        let newerArchive = Data([0x20])

        let olderResult = await queue.save(
            archiveData: olderArchive,
            cookieCount: 1,
            generation: olderGeneration
        )
        let newerResult = await queue.save(
            archiveData: newerArchive,
            cookieCount: 1,
            generation: newerGeneration
        )

        #expect(olderResult == .superseded)
        #expect(newerResult == .saved)
        #expect(storage.persistedData == newerArchive)
        #expect(storage.saveCount == 1)
    }

    @Test("Empty auth snapshots invalidate only at the latest generation")
    func emptyAuthSnapshotsInvalidateOnlyWhenLatest() async {
        let initialArchive = Data([0x2F])
        let storage = InMemoryCookieArchiveStorage(initialData: initialArchive)
        let queue = CookieArchiveWriteQueue(storage: storage.interface)
        let staleGeneration = await queue.reserveGeneration()
        let latestGeneration = await queue.reserveGeneration()

        #expect(await queue.invalidateAndDeleteIfLatest(
            generation: staleGeneration
        ) == .superseded)
        #expect(storage.persistedData == initialArchive)
        #expect(await queue.isRestoreAllowed())

        #expect(await queue.invalidateAndDeleteIfLatest(
            generation: latestGeneration
        ) == .saved)
        #expect(storage.persistedData == nil)
        #expect(await queue.isRestoreAllowed() == false)
    }

    @Test("Cookie archive invalidation rejects a previously reserved write")
    func cookieArchiveInvalidationRejectsReservedWrite() async {
        let initialArchive = Data([0x30])
        let storage = InMemoryCookieArchiveStorage(initialData: initialArchive)
        let queue = CookieArchiveWriteQueue(storage: storage.interface)
        let reservedGeneration = await queue.reserveGeneration()

        let didInvalidate = await queue.invalidateAndDelete()
        let staleResult = await queue.save(
            archiveData: initialArchive,
            cookieCount: 1,
            generation: reservedGeneration
        )

        #expect(didInvalidate)
        #expect(staleResult == .superseded)
        #expect(storage.persistedData == nil)
        #expect(storage.deleteCount == 1)
        #expect(storage.saveCount == 0)
    }

    @Test("Cookie archive invalidation reports persistent deletion failure")
    func cookieArchiveInvalidationReportsDeletionFailure() async {
        let initialArchive = Data([0x40])
        let storage = InMemoryCookieArchiveStorage(
            initialData: initialArchive,
            deleteResult: false
        )
        let queue = CookieArchiveWriteQueue(storage: storage.interface)

        let didInvalidate = await queue.invalidateAndDelete()

        #expect(!didInvalidate)
        #expect(storage.persistedData == initialArchive)
        #expect(await queue.isRestoreAllowed() == false)
    }

    @Test("Cookie archive invalidation includes the debug export")
    func cookieArchiveInvalidationIncludesDebugExport() async {
        let storage = InMemoryCookieArchiveStorage(
            initialData: Data([0x44]),
            debugDeleteResult: false,
            exportsDebugArchive: true
        )
        let queue = CookieArchiveWriteQueue(storage: storage.interface)

        let didInvalidate = await queue.invalidateAndDelete()

        #expect(!didInvalidate)
        #expect(storage.persistedData == nil)
        #expect(storage.debugDeleteCount == 1)
        #expect(await queue.isRestoreAllowed() == false)
    }

    @Test("Synchronous sign-out invalidation revokes older login transactions")
    func signOutInvalidationRevokesOlderLoginTransactions() async throws {
        let storage = InMemoryCookieArchiveStorage(
            initialData: Data([0x42]),
            restoreAllowed: true
        )
        let queue = CookieArchiveWriteQueue(storage: storage.interface)
        let transaction = try #require(await queue.beginLoginTransaction())

        _ = CookieArchiveRestorePolicy.invalidateAndAdvanceGeneration()

        #expect(await queue.finalizeLoginTransaction(transaction) == false)
        #expect(await queue.claimLoginTransactionRollback(transaction))
        #expect(await queue.rollbackLoginTransaction(transaction) == false)
        #expect(storage.persistedData == Data([0x42]))
        #expect(await queue.isRestoreAllowed() == false)
    }

    @Test("Login transaction setup reports failed restore-policy rollback")
    func loginTransactionSetupReportsPolicyRollbackFailure() async {
        let storage = InMemoryCookieArchiveStorage(
            initialData: Data([0x43]),
            restoreAllowed: true,
            setRestoreAllowedResults: [false, false]
        )
        let queue = CookieArchiveWriteQueue(storage: storage.interface)

        #expect(await queue.beginLoginTransaction() == nil)
        #expect(await queue.consumeLoginTransactionSetupCleanupRequirement())
        #expect(await queue.consumeLoginTransactionSetupCleanupRequirement() == false)
    }

    @Test("Login transaction setup accepts successful restore-policy rollback")
    func loginTransactionSetupAcceptsPolicyRollback() async {
        let storage = InMemoryCookieArchiveStorage(
            initialData: Data([0x44]),
            restoreAllowed: true,
            setRestoreAllowedResults: [false, true]
        )
        let queue = CookieArchiveWriteQueue(storage: storage.interface)

        #expect(await queue.beginLoginTransaction() == nil)
        #expect(await queue.consumeLoginTransactionSetupCleanupRequirement() == false)
        #expect(await queue.isRestoreAllowed())
    }

    @Test("Login transaction ownership distinguishes active, rollback, and released states")
    func loginTransactionOwnershipTracksLifecycle() async throws {
        let storage = InMemoryCookieArchiveStorage(initialData: Data([0x45]))
        let queue = CookieArchiveWriteQueue(storage: storage.interface)
        let transaction = try #require(await queue.beginLoginTransaction())

        #expect(await queue.loginTransactionOwnership(transaction) == .active)
        #expect(await queue.claimLoginTransactionRollback(transaction))
        #expect(await queue.loginTransactionOwnership(transaction) == .rollingBack)
        #expect(await queue.rollbackLoginTransaction(transaction))
        #expect(await queue.loginTransactionOwnership(transaction) == .none)
    }

    @Test("Empty live login baseline removes stale archive and preserves restore policy")
    func emptyLiveBaselineRemovesStaleArchiveOnRollback() async throws {
        let staleArchive = Data([0x44])
        let candidateArchive = Data([0x45])
        let storage = InMemoryCookieArchiveStorage(
            initialData: staleArchive,
            restoreAllowed: true
        )
        let queue = CookieArchiveWriteQueue(storage: storage.interface)
        let transaction = try #require(await queue.beginLoginTransaction(
            liveBaseline: .empty
        ))
        let generation = await queue.reserveGeneration()
        #expect(await queue.save(
            archiveData: candidateArchive,
            cookieCount: 1,
            generation: generation
        ).isPersisted)

        #expect(transaction.revokeCommit())
        #expect(await queue.finalizeLoginTransaction(transaction) == false)
        #expect(await queue.claimLoginTransactionRollback(transaction))
        #expect(await queue.rollbackLoginTransaction(transaction))
        #expect(storage.persistedData == nil)
        #expect(await queue.isRestoreAllowed())
    }

    @Test("Login cookie transaction rollback restores the prior archive and restore policy")
    func loginCookieTransactionRollbackRestoresPriorState() async throws {
        let initialArchive = Data([0x45])
        let candidateArchive = Data([0x46])
        let storage = InMemoryCookieArchiveStorage(initialData: initialArchive)
        let queue = CookieArchiveWriteQueue(storage: storage.interface)
        let transaction = try #require(await queue.beginLoginTransaction())

        #expect(await queue.isRestoreAllowed() == false)
        let generation = await queue.reserveGeneration()
        #expect(await queue.save(
            archiveData: candidateArchive,
            cookieCount: 1,
            generation: generation
        ).isPersisted)

        #expect(await queue.claimLoginTransactionRollback(transaction))
        #expect(await queue.rollbackLoginTransaction(transaction))
        #expect(storage.persistedData == initialArchive)
        #expect(await queue.isRestoreAllowed())
    }

    @Test("Login cookie transaction commit makes only the prepared archive restorable")
    func loginCookieTransactionCommitMakesCandidateRestorable() async throws {
        let candidateArchive = Data([0x47])
        let storage = InMemoryCookieArchiveStorage(
            initialData: nil,
            restoreAllowed: false
        )
        let queue = CookieArchiveWriteQueue(storage: storage.interface)
        let transaction = try #require(await queue.beginLoginTransaction())
        let generation = await queue.reserveGeneration()
        #expect(await queue.save(
            archiveData: candidateArchive,
            cookieCount: 1,
            generation: generation
        ).isPersisted)

        #expect(await queue.isRestoreAllowed() == false)
        #expect(await queue.finalizeLoginTransaction(transaction))
        #expect(storage.persistedData == candidateArchive)
        #expect(await queue.isRestoreAllowed())
    }

    @Test("Cookie archive stability includes SameSite policy")
    func cookieArchiveStabilityIncludesSameSitePolicy() throws {
        let laxCookie = try #require(HTTPCookie(properties: [
            .name: "SAPISID",
            .value: "mock-token",
            .domain: ".youtube.com",
            .path: "/",
            .sameSitePolicy: "Lax",
        ]))
        let strictCookie = try #require(HTTPCookie(properties: [
            .name: "SAPISID",
            .value: "mock-token",
            .domain: ".youtube.com",
            .path: "/",
            .sameSitePolicy: "Strict",
        ]))

        let laxSnapshot = try #require(CookieArchiveSnapshot.make(from: [laxCookie]))
        let strictSnapshot = try #require(CookieArchiveSnapshot.make(from: [strictCookie]))

        #expect(laxSnapshot != strictSnapshot)
    }

    @Test("Rollback accepts an already-current prior archive")
    func rollbackAcceptsAlreadyCurrentArchive() async throws {
        let initialArchive = Data([0x4A])
        let storage = InMemoryCookieArchiveStorage(
            initialData: initialArchive,
            saveResult: false,
            restoreAllowed: true
        )
        let queue = CookieArchiveWriteQueue(storage: storage.interface)
        let transaction = try #require(await queue.beginLoginTransaction())

        #expect(await queue.claimLoginTransactionRollback(transaction))
        #expect(await queue.rollbackLoginTransaction(transaction))
        #expect(storage.persistedData == initialArchive)
        #expect(await queue.isRestoreAllowed())
    }

    @Test("Failed login rollback keeps candidate archive non-restorable")
    func failedLoginRollbackKeepsRestoreDisabled() async throws {
        let candidateArchive = Data([0x48])
        let storage = InMemoryCookieArchiveStorage(
            initialData: nil,
            deleteResult: false,
            restoreAllowed: true
        )
        let queue = CookieArchiveWriteQueue(storage: storage.interface)
        let transaction = try #require(await queue.beginLoginTransaction())
        let generation = await queue.reserveGeneration()
        #expect(await queue.save(
            archiveData: candidateArchive,
            cookieCount: 1,
            generation: generation
        ).isPersisted)

        #expect(await queue.claimLoginTransactionRollback(transaction))
        #expect(await queue.rollbackLoginTransaction(transaction) == false)
        #expect(storage.persistedData == candidateArchive)
        #expect(await queue.isRestoreAllowed() == false)
    }

    @Test("Overlapping login cookie transactions are rejected")
    func overlappingLoginCookieTransactionsAreRejected() async throws {
        let storage = InMemoryCookieArchiveStorage(initialData: Data([0x49]))
        let queue = CookieArchiveWriteQueue(storage: storage.interface)
        let first = try #require(await queue.beginLoginTransaction())

        #expect(await queue.beginLoginTransaction() == nil)
        #expect(await queue.claimLoginTransactionRollback(first))
        #expect(await queue.rollbackLoginTransaction(first))
        #expect(storage.persistedData == Data([0x49]))
        #expect(await queue.isRestoreAllowed())
    }

    @Test("Empty auth-cookie rollback snapshots verify successfully")
    func emptyAuthCookieRollbackSnapshotsVerifySuccessfully() {
        let expected = CookieArchiveVerificationState.make(from: [])
        let actual = CookieArchiveVerificationState.make(from: [])

        #expect(actual.matches(expected))
    }

    @Test("Forced backup requires two consecutive matching snapshots")
    func forcedBackupRequiresConsecutiveMatchingSnapshots() async {
        let first = Self.cookieArchiveSnapshot(marker: 0x50)
        let second = Self.cookieArchiveSnapshot(marker: 0x60)
        var snapshots = [first, second, second, second]
        var generation: UInt64 = 0
        var persistedSnapshots: [CookieArchiveSnapshot] = []

        let result = await CookieBackupStabilizer.persistStableSnapshot(
            maxAttempts: 3,
            operations: CookieBackupStabilizer.Operations(
                prepareAttempt: {},
                makeAttempt: {
                    generation &+= 1
                    return CookieArchiveWriteAttempt(
                        snapshot: snapshots.removeFirst(),
                        generation: generation
                    )
                },
                persist: { attempt in
                    persistedSnapshots.append(attempt.snapshot)
                    return .saved
                },
                readVerificationSnapshot: {
                    snapshots.removeFirst()
                },
                isDirty: { false },
                canContinue: { true }
            )
        )

        #expect(result == .persisted)
        #expect(persistedSnapshots.count == 2)
        #expect(persistedSnapshots.last == second)
    }

    @Test("Forced backup reports persistence failure without claiming stability")
    func forcedBackupReportsPersistenceFailure() async {
        let snapshot = Self.cookieArchiveSnapshot(marker: 0x70)

        let result = await CookieBackupStabilizer.persistStableSnapshot(
            maxAttempts: 3,
            operations: CookieBackupStabilizer.Operations(
                prepareAttempt: {},
                makeAttempt: {
                    CookieArchiveWriteAttempt(snapshot: snapshot, generation: 1)
                },
                persist: { _ in .failed },
                readVerificationSnapshot: { snapshot },
                isDirty: { false },
                canContinue: { true }
            )
        )

        #expect(result == .failed)
    }

    private static func cookieArchiveSnapshot(marker: UInt8) -> CookieArchiveSnapshot {
        let data = Data([marker])
        return CookieArchiveSnapshot(
            data: data,
            cookieCount: 1,
            primarySessionValue: "mock-token",
            stabilityFingerprint: data
        )
    }

    @Test("Extension resource URL resolves relative paths against the extension base URL")
    func extensionResourceURLUsesExtensionBaseURL() throws {
        let baseURL = try #require(URL(string: "webkit-extension://example-extension/"))
        let resolvedURL = WebKitManager.extensionResourceURL(
            relativePath: "/pages/options.html",
            baseURL: baseURL
        )

        #expect(resolvedURL?.absoluteString == "webkit-extension://example-extension/pages/options.html")
    }

    @Test("Extension resource URL rejects absolute external paths")
    func extensionResourceURLRejectsAbsoluteURLs() throws {
        let baseURL = try #require(URL(string: "webkit-extension://example-extension/"))
        let resolvedURL = WebKitManager.extensionResourceURL(
            relativePath: "https://example.com/options.html",
            baseURL: baseURL
        )

        #expect(resolvedURL == nil)
    }

    // MARK: - DATASYNC_ID Identity Matching

    @Test("Brand DATASYNC_ID matches when first half equals brand pageId")
    func dataSyncIdMatchesBrand() {
        // "<delegatedSessionId>||<userSessionId>" — delegated half is the brand.
        let dataSyncId = "111111111111111111111||108880000000000000000"
        #expect(WebKitManager.dataSyncId(dataSyncId, matches: "111111111111111111111") == true)
    }

    @Test("Brand DATASYNC_ID does not match a different brand pageId")
    func dataSyncIdRejectsWrongBrand() {
        let dataSyncId = "111111111111111111111||108880000000000000000"
        #expect(WebKitManager.dataSyncId(dataSyncId, matches: "999999999999999999999") == false)
    }

    @Test("Primary DATASYNC_ID (empty delegated half) matches nil brand")
    func dataSyncIdMatchesPrimary() {
        // Primary is "<userSessionId>||" — empty delegated (first) half.
        let dataSyncId = "108880000||"
        #expect(WebKitManager.dataSyncId(dataSyncId, matches: nil) == true)
    }

    @Test("Primary DATASYNC_ID does not match a brand expectation")
    func dataSyncIdPrimaryRejectsBrand() {
        let dataSyncId = "108880000||"
        #expect(WebKitManager.dataSyncId(dataSyncId, matches: "111111111111111111111") == false)
    }

    @Test("Brand DATASYNC_ID does not satisfy a primary (nil) expectation")
    func dataSyncIdBrandRejectsPrimary() {
        let dataSyncId = "111111111111111111111||108880000000000000000"
        #expect(WebKitManager.dataSyncId(dataSyncId, matches: nil) == false)
    }

    @Test("Blank/unread DATASYNC_ID never falsely verifies as primary")
    func dataSyncIdBlankIsNotPrimary() {
        // The page JS returns "" (or a bare "||") before ytcfg populates; an
        // unread page must NOT be treated as a verified primary session.
        #expect(WebKitManager.dataSyncId("", matches: nil) == false)
        #expect(WebKitManager.dataSyncId("||", matches: nil) == false)
        #expect(WebKitManager.dataSyncId("", matches: "111111111111111111111") == false)
        #expect(WebKitManager.dataSyncId("garbage-no-separator", matches: nil) == false)
    }
}

// MARK: - InMemoryCookieArchiveStorage

private final class InMemoryCookieArchiveStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private let deleteResult: Bool
    private let saveResult: Bool
    private let debugDeleteResult: Bool
    private let exportsDebugArchive: Bool
    private var restoreAllowed: Bool
    private var setRestoreAllowedResults: [Bool]
    private var storedSaveCount = 0
    private var storedDeleteCount = 0
    private var storedDebugDeleteCount = 0

    init(
        initialData: Data? = nil,
        deleteResult: Bool = true,
        saveResult: Bool = true,
        debugDeleteResult: Bool = true,
        exportsDebugArchive: Bool = false,
        restoreAllowed: Bool = true,
        setRestoreAllowedResults: [Bool] = []
    ) {
        self.data = initialData
        self.deleteResult = deleteResult
        self.saveResult = saveResult
        self.debugDeleteResult = debugDeleteResult
        self.exportsDebugArchive = exportsDebugArchive
        self.restoreAllowed = restoreAllowed
        self.setRestoreAllowedResults = setRestoreAllowedResults
    }

    var interface: CookieArchiveStorage {
        CookieArchiveStorage(
            save: { [self] data, _ in
                self.lock.withLock {
                    self.storedSaveCount += 1
                    if self.saveResult {
                        self.data = data
                    }
                }
                return self.saveResult
            },
            load: { [self] in
                self.lock.withLock { self.data }
            },
            delete: { [self] in
                self.lock.withLock {
                    self.storedDeleteCount += 1
                    if self.deleteResult {
                        self.data = nil
                    }
                }
                return self.deleteResult
            },
            restoreDecision: { [self] in
                self.lock.withLock { self.restoreAllowed ? .allowed : .denied }
            },
            setRestoreAllowed: { [self] allowed in
                self.lock.withLock {
                    let result = self.setRestoreAllowedResults.isEmpty
                        ? true
                        : self.setRestoreAllowedResults.removeFirst()
                    if result {
                        self.restoreAllowed = allowed
                    }
                    return result
                }
            },
            exportsDebugArchive: self.exportsDebugArchive,
            deleteDebugArchive: { [self] in
                self.lock.withLock {
                    self.storedDebugDeleteCount += 1
                }
                return self.debugDeleteResult
            }
        )
    }

    var persistedData: Data? {
        self.lock.withLock { self.data }
    }

    var saveCount: Int {
        self.lock.withLock { self.storedSaveCount }
    }

    var deleteCount: Int {
        self.lock.withLock { self.storedDeleteCount }
    }

    var debugDeleteCount: Int {
        self.lock.withLock { self.storedDebugDeleteCount }
    }
}
