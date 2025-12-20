import XCTest
@testable import YouTubeMusic

/// Tests for AuthService.
@MainActor
final class AuthServiceTests: XCTestCase {
    var authService: AuthService!

    override func setUp() async throws {
        authService = AuthService()
    }

    override func tearDown() async throws {
        authService = nil
    }

    func testInitialState() {
        XCTAssertEqual(authService.state, .loggedOut)
        XCTAssertFalse(authService.needsReauth)
    }

    func testStartLogin() {
        authService.startLogin()
        XCTAssertEqual(authService.state, .loggingIn)
    }

    func testCompleteLogin() {
        authService.completeLogin(sapisid: "test-sapisid")
        XCTAssertEqual(authService.state, .loggedIn(sapisid: "test-sapisid"))
        XCTAssertFalse(authService.needsReauth)
    }

    func testSessionExpired() {
        authService.completeLogin(sapisid: "test-sapisid")
        authService.sessionExpired()

        XCTAssertEqual(authService.state, .loggedOut)
        XCTAssertTrue(authService.needsReauth)
    }

    func testStateIsLoggedIn() {
        XCTAssertFalse(authService.state.isLoggedIn)

        authService.completeLogin(sapisid: "test")
        XCTAssertTrue(authService.state.isLoggedIn)
    }

    func testSignOut() async {
        authService.completeLogin(sapisid: "test-sapisid")
        authService.needsReauth = true

        await authService.signOut()

        XCTAssertEqual(authService.state, .loggedOut)
        XCTAssertFalse(authService.needsReauth)
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
