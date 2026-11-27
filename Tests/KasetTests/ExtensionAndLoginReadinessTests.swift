import Foundation
import Testing
@testable import Kaset

@Suite("Extension lifecycle & login cookie readiness")
@MainActor
struct ExtensionAndLoginReadinessTests {
    @Test("Restart helper arguments avoid shell interpolation for special paths")
    func restartHelperArgumentsAreSafe() {
        let specialURL = URL(fileURLWithPath: "/Applications/Kaset's \"Beta\" $(id)/Kaset.app")
        let args = ExtensionsSettingsView.restartHelperArguments(pid: 4242, bundleURL: specialURL)

        #expect(args.count == 5)
        #expect(args[0] == "-c")
        #expect(!args[1].contains(specialURL.path))
        #expect(args[1].contains("kill -0"))
        #expect(args[3] == "4242")
        #expect(args[4] == specialURL.path)
    }

    @Test("Login cookie readiness waits for spread-out delivery and respects attempt replacement")
    func loginCookieReadinessObserver() async throws {
        let webKitManager = MockWebKitManager()
        let authService = AuthService(webKitManager: webKitManager)
        authService.startLogin()
        let attemptID = try #require(authService.activeLoginAttemptID)
        let transaction = try await #require(webKitManager.beginLoginCookieBackup())

        let observer = LoginCookieReadinessObserver(
            webKitManager: webKitManager,
            authService: authService
        )

        let firstCookie = try #require(HTTPCookie(properties: [
            .domain: ".youtube.com",
            .path: "/",
            .name: "SAPISID",
            .value: "test-cookie",
        ]))
        let secondCookie = try #require(HTTPCookie(properties: [
            .domain: ".youtube.com",
            .path: "/",
            .name: "SID",
            .value: "test-sid",
        ]))
        let thirdCookie = try #require(HTTPCookie(properties: [
            .domain: ".youtube.com",
            .path: "/",
            .name: "HSID",
            .value: "test-hsid",
        ]))

        webKitManager.getSAPISIDGate = { @MainActor in
            switch webKitManager.getSAPISIDCallCount {
            case 1:
                webKitManager.sapisidValue = "test-cookie"
                webKitManager.loginCookieSnapshotChanged = true
                webKitManager.allCookies = [firstCookie]
            case 2:
                webKitManager.allCookies = [firstCookie, secondCookie]
            case 3:
                webKitManager.allCookies = [firstCookie, secondCookie, thirdCookie]
            default:
                break
            }
        }

        let ready = await observer.waitUntilReady(
            expectedAttemptID: attemptID,
            transaction: transaction,
            timeout: .seconds(2),
            pollInterval: .milliseconds(5)
        )
        #expect(ready == true)
        #expect(webKitManager.getSAPISIDCallCount == 4)
        #expect(webKitManager.allCookies.count == 3)
        webKitManager.getSAPISIDGate = nil

        authService.cancelLoginIfNeeded(expectedAttemptID: attemptID)
        authService.startLogin()
        let secondAttemptID = try #require(authService.activeLoginAttemptID)
        let baseCalls = webKitManager.getSAPISIDCallCount
        webKitManager.getSAPISIDGate = { @MainActor in
            if webKitManager.getSAPISIDCallCount == baseCalls + 2 {
                authService.cancelLoginIfNeeded(expectedAttemptID: secondAttemptID)
                authService.startLogin()
            }
        }
        let staleReady = await observer.waitUntilReady(
            expectedAttemptID: secondAttemptID,
            transaction: transaction,
            timeout: .milliseconds(500),
            pollInterval: .milliseconds(5)
        )
        webKitManager.getSAPISIDGate = nil
        #expect(staleReady == false)
        #expect(webKitManager.getSAPISIDCallCount == baseCalls + 2)
    }
}
