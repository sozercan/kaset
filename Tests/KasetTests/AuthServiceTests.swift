import Foundation
import Testing
@testable import Kaset

/// Tests for AuthService.
@Suite(.serialized)
@MainActor
struct AuthServiceTests {
    var authService: AuthService
    var mockWebKitManager: MockWebKitManager

    init() {
        self.mockWebKitManager = MockWebKitManager()
        self.authService = AuthService(webKitManager: self.mockWebKitManager)
    }

    @Test("Initial state is initializing")
    func initialState() {
        #expect(authService.state == .initializing)
        #expect(authService.needsReauth == false)
    }

    @Test("State isInitializing property")
    func isInitializing() {
        #expect(authService.state.isInitializing == true)
        #expect(authService.state.isLoggedIn == false)

        authService.completeLogin(sapisid: "test")
        #expect(authService.state.isInitializing == false)
        #expect(authService.state.isLoggedIn == true)
    }

    @Test("Start login transitions to loggingIn state")
    func startLogin() {
        authService.startLogin()
        #expect(authService.state == .loggingIn)
    }

    @Test("Complete login transitions to loggedIn state")
    func completeLogin() {
        authService.completeLogin(sapisid: "test-sapisid")
        #expect(authService.state == .loggedIn(sapisid: "test-sapisid"))
        #expect(authService.needsReauth == false)
    }

    @Test("Session expired transitions to loggedOut and sets needsReauth")
    func sessionExpired() {
        authService.completeLogin(sapisid: "test-sapisid")
        authService.sessionExpired()

        #expect(authService.state == .loggedOut)
        #expect(authService.needsReauth == true)
    }

    @Test("State isLoggedIn property")
    func stateIsLoggedIn() {
        #expect(authService.state.isLoggedIn == false)

        authService.completeLogin(sapisid: "test")
        #expect(authService.state.isLoggedIn == true)
    }

    @Test("Sign out clears state and calls mock")
    func signOut() async {
        authService.completeLogin(sapisid: "test-sapisid")
        authService.needsReauth = true

        await authService.signOut()

        #expect(authService.state == .loggedOut)
        #expect(authService.needsReauth == false)
        #expect(mockWebKitManager.clearAllDataCalled == true)
    }

    @Test("State equality")
    func stateEquatable() {
        let state1 = AuthService.State.loggedOut
        let state2 = AuthService.State.loggedOut
        #expect(state1 == state2)

        let state3 = AuthService.State.loggedIn(sapisid: "test")
        let state4 = AuthService.State.loggedIn(sapisid: "test")
        #expect(state3 == state4)

        let state5 = AuthService.State.loggedIn(sapisid: "different")
        #expect(state3 != state5)
    }
}
