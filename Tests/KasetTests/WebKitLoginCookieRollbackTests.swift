import Foundation
import Testing
@testable import Kaset

@Suite("WebKit login cookie rollback", .serialized, .tags(.service))
@MainActor
struct WebKitLoginCookieRollbackTests {
    @Test("Login rollback restores the complete Google and YouTube cookie jar")
    func restoresCompleteSignInCookieJar() async throws {
        let baselineAPI = try #require(HTTPCookie(properties: [
            .name: "SAPISID",
            .value: "baseline-api-session",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        let baselineGAIA = try #require(HTTPCookie(properties: [
            .name: "LSID",
            .value: "baseline-gaia-session",
            .domain: ".google.com",
            .path: "/",
        ]))
        let unrelatedCookie = try #require(HTTPCookie(properties: [
            .name: "unrelated",
            .value: "preserve-me",
            .domain: ".example.com",
            .path: "/",
        ]))
        let candidateAPI = try #require(HTTPCookie(properties: [
            .name: "SAPISID",
            .value: "candidate-api-session",
            .domain: ".youtube.com",
            .path: "/",
        ]))
        let candidateGAIA = try #require(HTTPCookie(properties: [
            .name: "LSID",
            .value: "candidate-gaia-session",
            .domain: ".google.com",
            .path: "/",
        ]))
        let candidateExtra = try #require(HTTPCookie(properties: [
            .name: "ACCOUNT_CHOOSER",
            .value: "candidate-only",
            .domain: ".google.com",
            .path: "/",
        ]))
        let webKitManager = WebKitManager.makeTestInstance()

        _ = await webKitManager.clearAllData()
        await webKitManager.dataStore.httpCookieStore.setCookie(baselineAPI)
        await webKitManager.dataStore.httpCookieStore.setCookie(baselineGAIA)
        await webKitManager.dataStore.httpCookieStore.setCookie(unrelatedCookie)
        guard let transaction = await webKitManager.beginLoginCookieBackup() else {
            _ = await webKitManager.clearAllData()
            Issue.record("Expected an in-memory login cookie transaction")
            return
        }

        await webKitManager.dataStore.httpCookieStore.setCookie(candidateAPI)
        await webKitManager.dataStore.httpCookieStore.setCookie(candidateGAIA)
        await webKitManager.dataStore.httpCookieStore.setCookie(candidateExtra)

        #expect(await webKitManager.prepareLoginCookieBackupRollback(transaction))
        let rollbackResult = await webKitManager.rollbackLoginCookieBackup(transaction)
        let cookies = await webKitManager.dataStore.httpCookieStore.allCookies()
        _ = await webKitManager.clearAllData()

        #expect(rollbackResult == .rolledBack)
        #expect(cookies.first { $0.name == "SAPISID" }?.value == "baseline-api-session")
        #expect(cookies.first { $0.name == "LSID" }?.value == "baseline-gaia-session")
        #expect(cookies.contains { $0.name == "ACCOUNT_CHOOSER" } == false)
        #expect(cookies.first { $0.name == "unrelated" }?.value == "preserve-me")
    }
}
