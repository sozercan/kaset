import Foundation
import Testing
@testable import Kaset

@Suite("WebKit cookie restoration", .serialized, .tags(.service))
@MainActor
struct WebKitCookieRestoreTests {
    @Test("Clearing one manager's data leaves another manager's cookie archive intact")
    func clearingOneManagerPreservesAnotherManagersArchive() async {
        let archiveOwner = WebKitManager.makeTestInstance()
        let clearingManager = WebKitManager.makeTestInstance()
        let archiveData = Data("archived-cookies".utf8)

        let generation = await archiveOwner.cookieArchiveQueue.reserveGeneration()
        let saveResult = await archiveOwner.cookieArchiveQueue.save(
            archiveData: archiveData,
            cookieCount: 1,
            generation: generation
        )
        #expect(saveResult == .saved)

        _ = await clearingManager.clearAllData()

        #expect(await archiveOwner.cookieArchiveQueue.persistedArchiveData() == archiveData)
        #expect(await clearingManager.cookieArchiveQueue.persistedArchiveData() == nil)
    }

    @Test("Persisted archive replaces stale live authentication cookies")
    func persistedArchiveReplacesStaleLiveCookies() async throws {
        let expectedCookie = try #require(HTTPCookie(properties: [
            .name: "__Secure-3PAPISID",
            .value: "isolated-restore-session",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        let staleCookie = try #require(HTTPCookie(properties: [
            .name: "SAPISID",
            .value: "stale-session",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        let staleGAIA = try #require(HTTPCookie(properties: [
            .name: "LSID",
            .value: "stale-gaia-session",
            .domain: ".google.com",
            .path: "/",
        ]))
        let publicPreference = try #require(HTTPCookie(properties: [
            .name: "PREF",
            .value: "preserve-public-state",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        let webKitManager = WebKitManager.makeTestInstance()
        let archive = try #require(KeychainCookieStorage.makeArchiveData(from: [expectedCookie]))

        _ = await webKitManager.clearAllData()
        let generation = await webKitManager.cookieArchiveQueue.reserveGeneration()
        #expect(await webKitManager.cookieArchiveQueue.save(
            archiveData: archive.data,
            cookieCount: archive.cookieCount,
            generation: generation
        ).isPersisted)
        await webKitManager.dataStore.httpCookieStore.setCookie(staleCookie)
        await webKitManager.dataStore.httpCookieStore.setCookie(staleGAIA)
        await webKitManager.dataStore.httpCookieStore.setCookie(publicPreference)

        let restored = await webKitManager.restoreAuthCookiesFromBackup(
            expectedGeneration: webKitManager.authCookieOperationFence.generation
        )
        let cookies = await webKitManager.dataStore.httpCookieStore.allCookies()
        _ = await webKitManager.clearAllData()

        #expect(restored)
        #expect(cookies.first { $0.name == "__Secure-3PAPISID" }?.value == "isolated-restore-session")
        #expect(cookies.contains { $0.name == "SAPISID" } == false)
        #expect(cookies.contains { $0.name == "LSID" } == false)
        #expect(cookies.first { $0.name == "PREF" }?.value == "preserve-public-state")
    }

    @Test("Authentication cookie clearing removes login-session state and preserves preferences")
    func authenticationCookieClearingPreservesPreferences() async throws {
        let loginCookie = try #require(HTTPCookie(properties: [
            .name: "LSID",
            .value: "mock-login-session",
            .domain: ".google.com",
            .path: "/",
        ]))
        let preferenceCookie = try #require(HTTPCookie(properties: [
            .name: "PREF",
            .value: "public-preference",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        var cookies = [loginCookie, preferenceCookie]

        let result = await LiveAuthCookieStoreClearer.clear(
            operations: LiveAuthCookieStoreClearer.Operations(
                readCookies: { cookies },
                deleteCookie: { deletedCookie in
                    cookies.removeAll { cookie in
                        cookie.name == deletedCookie.name
                            && cookie.domain == deletedCookie.domain
                            && cookie.path == deletedCookie.path
                    }
                },
                removeAllCookies: {
                    cookies = []
                }
            )
        )

        #expect(result.didClear)
        #expect(!result.usedCookieStoreFallback)
        #expect(!cookies.contains { $0.name == "LSID" })
        #expect(cookies.first { $0.name == "PREF" }?.value == "public-preference")
    }

    @Test("Cookie restore policy treats explicit invalidation as authoritative")
    func cookieRestorePolicyTreatsInvalidationAsAuthoritative() {
        var archiveReadCount = 0

        let decision = CookieArchiveRestorePolicy.resolveRestoreDecision(
            invalidationTombstonePresent: true,
            storedPolicy: .allowed,
            archiveResult: {
                archiveReadCount += 1
                return .data(Data([0x01]))
            },
            migrateLegacyArchive: { _ in
                archiveReadCount += 1
                return .allowed
            }
        )

        #expect(decision == .denied)
        #expect(archiveReadCount == 0)
    }

    @Test("Missing restore policy migrates a valid legacy archive")
    func missingRestorePolicyMigratesValidLegacyArchive() throws {
        let cookie = try #require(HTTPCookie(properties: [
            .name: "SAPISID",
            .value: "legacy-session",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        let archive = try #require(KeychainCookieStorage.makeArchiveData(from: [cookie]))
        var migratedArchives: [Data] = []

        let decision = CookieArchiveRestorePolicy.resolveRestoreDecision(
            invalidationTombstonePresent: false,
            storedPolicy: .notFound,
            archiveResult: { .data(archive.data) },
            migrateLegacyArchive: { archiveData in
                migratedArchives.append(archiveData)
                return KeychainCookieStorage.isRestorableArchiveData(archiveData)
                    ? .allowed
                    : .denied
            }
        )

        #expect(decision == .allowed)
        #expect(migratedArchives == [archive.data])
        #expect(!KeychainCookieStorage.isRestorableArchiveData(Data([0x01])))
    }

    @Test("Legacy restore-policy migration rejects a stale generation")
    func legacyRestorePolicyMigrationRejectsStaleGeneration() throws {
        let cookie = try #require(HTTPCookie(properties: [
            .name: "SAPISID",
            .value: "legacy-session",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        let archive = try #require(KeychainCookieStorage.makeArchiveData(from: [cookie]))
        let staleGeneration = CookieArchiveRestorePolicy.generation
        _ = CookieArchiveRestorePolicy.invalidateAndAdvanceGeneration()
        var saveCount = 0

        let decision = CookieArchiveRestorePolicy.migrateLegacyArchivePolicy(
            archive.data,
            expectedGeneration: staleGeneration,
            savePolicy: {
                saveCount += 1
                return true
            }
        )

        #expect(decision == .denied)
        #expect(saveCount == 0)
    }

    @Test("Cookie restore policy distinguishes denial from temporary unavailability")
    func cookieRestorePolicyDistinguishesUnavailableState() {
        #expect(CookieArchiveRestorePolicy.resolveRestoreDecision(
            invalidationTombstonePresent: false,
            storedPolicy: .allowed,
            archiveResult: { .failure },
            migrateLegacyArchive: { _ in .denied }
        ) == .allowed)
        #expect(CookieArchiveRestorePolicy.resolveRestoreDecision(
            invalidationTombstonePresent: false,
            storedPolicy: .denied,
            archiveResult: { .notFound },
            migrateLegacyArchive: { _ in .allowed }
        ) == .denied)
        #expect(CookieArchiveRestorePolicy.resolveRestoreDecision(
            invalidationTombstonePresent: false,
            storedPolicy: .failure,
            archiveResult: { .notFound },
            migrateLegacyArchive: { _ in .allowed }
        ) == .unavailable)
        #expect(CookieArchiveRestorePolicy.resolveRestoreDecision(
            invalidationTombstonePresent: false,
            storedPolicy: .notFound,
            archiveResult: { .notFound },
            migrateLegacyArchive: { _ in .denied }
        ) == .allowed)
        #expect(CookieArchiveRestorePolicy.resolveRestoreDecision(
            invalidationTombstonePresent: false,
            storedPolicy: .notFound,
            archiveResult: { .data(Data([0x01])) },
            migrateLegacyArchive: { _ in .denied }
        ) == .denied)
        #expect(CookieArchiveRestorePolicy.resolveRestoreDecision(
            invalidationTombstonePresent: false,
            storedPolicy: .notFound,
            archiveResult: { .data(Data([0x01])) },
            migrateLegacyArchive: { _ in .unavailable }
        ) == .unavailable)
        #expect(CookieArchiveRestorePolicy.resolveRestoreDecision(
            invalidationTombstonePresent: false,
            storedPolicy: .notFound,
            archiveResult: { .failure },
            migrateLegacyArchive: { _ in .allowed }
        ) == .unavailable)
    }

    @Test("Cookie restore policy storage rejects malformed representations")
    func cookieRestorePolicyStorageRejectsMalformedRepresentations() {
        #expect(CookieRestorePolicyStorage.decode(Data([0])) == .denied)
        #expect(CookieRestorePolicyStorage.decode(Data([1])) == .allowed)
        #expect(CookieRestorePolicyStorage.decode(Data()) == .failure)
        #expect(CookieRestorePolicyStorage.decode(Data([2])) == .failure)
        #expect(CookieRestorePolicyStorage.decode(Data([1, 0])) == .failure)
    }

    @Test("Login baseline preparation fences observed cookie changes")
    func loginBaselinePreparationFencesCookieChanges() {
        let webKitManager = WebKitManager.makeTestInstance()
        webKitManager.isPreparingLoginCookieBackup = true
        webKitManager.forcedCookieBackupDirty = false

        webKitManager.handleObservedCookieChange(
            in: webKitManager.dataStore.httpCookieStore
        )

        #expect(webKitManager.forcedCookieBackupDirty)
        #expect(webKitManager.cookieDebounceTask == nil)
        webKitManager.isPreparingLoginCookieBackup = false
    }

    @Test("Failed restore quarantine clears login state and preserves preferences")
    func failedRestoreQuarantineClearsLoginState() async throws {
        let primaryCookie = try #require(HTTPCookie(properties: [
            .name: "SAPISID",
            .value: "partial-session",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        let loginCookie = try #require(HTTPCookie(properties: [
            .name: "LSID",
            .value: "partial-login-state",
            .domain: ".google.com",
            .path: "/",
        ]))
        let preferenceCookie = try #require(HTTPCookie(properties: [
            .name: "PREF",
            .value: "preserve-public-state",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        let webKitManager = WebKitManager.makeTestInstance()

        _ = await webKitManager.clearAllData()
        await webKitManager.dataStore.httpCookieStore.setCookie(primaryCookie)
        await webKitManager.dataStore.httpCookieStore.setCookie(loginCookie)
        await webKitManager.dataStore.httpCookieStore.setCookie(preferenceCookie)
        let restorePolicyGeneration = CookieArchiveRestorePolicy.generation

        let didQuarantine = await webKitManager.quarantineFailedAuthCookieRestore(
            expectedGeneration: webKitManager.authCookieOperationFence.generation
        )
        let cookies = await webKitManager.dataStore.httpCookieStore.allCookies()
        _ = await webKitManager.clearAllData()

        #expect(didQuarantine)
        #expect(CookieArchiveRestorePolicy.generation > restorePolicyGeneration)
        #expect(!cookies.contains { $0.name == "SAPISID" })
        #expect(!cookies.contains { $0.name == "LSID" })
        #expect(cookies.first { $0.name == "PREF" }?.value == "preserve-public-state")
    }

    @Test("Login transaction snapshot identity includes refreshed companion cookies")
    func loginTransactionSnapshotIdentityIncludesCookieMetadata() throws {
        let primaryCookie = try #require(HTTPCookie(properties: [
            .name: "SAPISID",
            .value: "stable-primary-value",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        let baselineCompanion = try #require(HTTPCookie(properties: [
            .name: "SID",
            .value: "baseline-companion",
            .domain: ".google.com",
            .path: "/",
        ]))
        let refreshedCompanion = try #require(HTTPCookie(properties: [
            .name: "SID",
            .value: "refreshed-companion",
            .domain: ".google.com",
            .path: "/",
        ]))
        let baselineSnapshot = try #require(CookieArchiveSnapshot.make(
            from: [primaryCookie, baselineCompanion]
        ))
        let refreshedSnapshot = try #require(CookieArchiveSnapshot.make(
            from: [primaryCookie, refreshedCompanion]
        ))
        let transaction = CookieBackupTransaction.testing(
            previousLiveSnapshotFingerprint: baselineSnapshot.stabilityFingerprint
        )

        #expect(baselineSnapshot.primarySessionValue == refreshedSnapshot.primarySessionValue)
        #expect(!transaction.hasChangedFromPreviousLiveSnapshot(baselineSnapshot))
        #expect(transaction.hasChangedFromPreviousLiveSnapshot(refreshedSnapshot))
        #expect(WebKitManager.loginCookieBaselineMatches(
            expectedAuthSnapshot: baselineSnapshot,
            expectedLoginCookies: [primaryCookie, baselineCompanion],
            currentCookies: [primaryCookie, baselineCompanion]
        ))
        #expect(!WebKitManager.loginCookieBaselineMatches(
            expectedAuthSnapshot: baselineSnapshot,
            expectedLoginCookies: [primaryCookie, baselineCompanion],
            currentCookies: [primaryCookie, refreshedCompanion]
        ))
    }
}
