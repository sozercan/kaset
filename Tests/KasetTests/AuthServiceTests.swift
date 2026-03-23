import Foundation
import Testing
@testable import Kaset

/// Tests for AuthService.
@Suite("AuthService", .serialized, .tags(.service))
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
        #expect(self.authService.state == .initializing)
        #expect(self.authService.needsReauth == false)
    }

    @Test("State isInitializing property")
    func isInitializing() {
        #expect(self.authService.state.isInitializing == true)
        #expect(self.authService.state.isLoggedIn == false)

        self.authService.completeLogin(sapisid: "test")
        #expect(self.authService.state.isInitializing == false)
        #expect(self.authService.state.isLoggedIn == true)
    }

    @Test("Start login transitions to loggingIn state")
    func startLogin() {
        self.authService.startLogin()
        #expect(self.authService.state == .loggingIn)
    }

    @Test("Complete login transitions to loggedIn state")
    func completeLogin() {
        self.authService.completeLogin(sapisid: "test-sapisid")
        #expect(self.authService.state == .loggedIn(sapisid: "test-sapisid"))
        #expect(self.authService.needsReauth == false)
    }

    @Test("Session expired transitions to loggedOut and sets needsReauth")
    func sessionExpired() {
        self.authService.completeLogin(sapisid: "test-sapisid")
        self.authService.sessionExpired()

        #expect(self.authService.state == .loggedOut)
        #expect(self.authService.needsReauth == true)
    }

    @Test("State isLoggedIn property")
    func stateIsLoggedIn() {
        #expect(self.authService.state.isLoggedIn == false)

        self.authService.completeLogin(sapisid: "test")
        #expect(self.authService.state.isLoggedIn == true)
    }

    @Test("Sign out clears state and calls mock")
    func signOut() async {
        self.authService.completeLogin(sapisid: "test-sapisid")
        self.authService.needsReauth = true

        await self.authService.signOut()

        #expect(self.authService.state == .loggedOut)
        #expect(self.authService.needsReauth == false)
        #expect(self.mockWebKitManager.clearAllDataCalled == true)
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
