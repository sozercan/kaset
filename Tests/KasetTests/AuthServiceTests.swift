import XCTest
@testable import Kaset

/// Tests for AuthService.
@MainActor
final class AuthServiceTests: XCTestCase {
    var authService: AuthService!
    var mockWebKitManager: MockWebKitManager!

    override func setUp() async throws {
        self.mockWebKitManager = MockWebKitManager()
        self.authService = AuthService(webKitManager: self.mockWebKitManager)
    }

    override func tearDown() async throws {
        self.authService = nil
        self.mockWebKitManager = nil
    }

    func testInitialState() {
        XCTAssertEqual(self.authService.state, .initializing)
        XCTAssertFalse(self.authService.needsReauth)
    }

    func testIsInitializing() {
        XCTAssertTrue(self.authService.state.isInitializing)
        XCTAssertFalse(self.authService.state.isLoggedIn)

        self.authService.completeLogin(sapisid: "test")
        XCTAssertFalse(self.authService.state.isInitializing)
        XCTAssertTrue(self.authService.state.isLoggedIn)
    }

    func testStartLogin() {
        self.authService.startLogin()
        XCTAssertEqual(self.authService.state, .loggingIn)
    }

    func testCompleteLogin() {
        self.authService.completeLogin(sapisid: "test-sapisid")
        XCTAssertEqual(self.authService.state, .loggedIn(sapisid: "test-sapisid"))
        XCTAssertFalse(self.authService.needsReauth)
    }

    func testSessionExpired() {
        self.authService.completeLogin(sapisid: "test-sapisid")
        self.authService.sessionExpired()

        XCTAssertEqual(self.authService.state, .loggedOut)
        XCTAssertTrue(self.authService.needsReauth)
    }

    func testStateIsLoggedIn() {
        XCTAssertFalse(self.authService.state.isLoggedIn)

        self.authService.completeLogin(sapisid: "test")
        XCTAssertTrue(self.authService.state.isLoggedIn)
    }

    func testSignOut() async {
        self.authService.completeLogin(sapisid: "test-sapisid")
        self.authService.needsReauth = true

        await self.authService.signOut()

        XCTAssertEqual(self.authService.state, .loggedOut)
        XCTAssertFalse(self.authService.needsReauth)
        // Verify mock was called (not real WebKit/Keychain)
        XCTAssertTrue(self.mockWebKitManager.clearAllDataCalled)
    }

    func testStateEquatable() {
        let state1 = AuthService.State.loggedOut
        let state2 = AuthService.State.loggedOut
        XCTAssertEqual(state1, state2)

        let state3 = AuthService.State.loggedIn(sapisid: "test")
        let state4 = AuthService.State.loggedIn(sapisid: "test")
        XCTAssertEqual(state3, state4)

        let state5 = AuthService.State.loggedIn(sapisid: "different")
        XCTAssertNotEqual(state3, state5)
    }
}
