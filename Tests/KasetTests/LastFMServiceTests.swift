import Foundation
import Testing
@testable import Kaset

// MARK: - LastFMServiceTests

@Suite("LastFMService", .serialized, .tags(.service))
@MainActor
struct LastFMServiceTests {
    // MARK: - Initialization

    @Test("Initial state is disconnected")
    func initialState() throws {
        let service = try LastFMService(
            credentialStore: KeychainCredentialStore(servicePrefix: "test.lastfm.\(UUID().uuidString)"),
            workerBaseURL: #require(URL(string: "https://test.workers.dev"))
        )
        #expect(service.authState == .disconnected)
        #expect(service.serviceName == "Last.fm")
    }

    @Test("Restores session from credential store")
    func restoreSession() throws {
        let prefix = "test.lastfm.\(UUID().uuidString)"
        let store = KeychainCredentialStore(servicePrefix: prefix)

        // Pre-populate credentials
        try store.saveLastFMSessionKey("test-session-key")
        try store.saveLastFMUsername("testuser")

        let service = try LastFMService(
            credentialStore: store,
            workerBaseURL: #require(URL(string: "https://test.workers.dev"))
        )
        service.restoreSession()

        #expect(service.authState == .connected(username: "testuser"))

        // Cleanup
        store.removeLastFMCredentials()
    }

    @Test("RestoreSession with no credentials stays disconnected")
    func restoreSessionNoCredentials() throws {
        let store = KeychainCredentialStore(servicePrefix: "test.lastfm.\(UUID().uuidString)")
        let service = try LastFMService(
            credentialStore: store,
            workerBaseURL: #require(URL(string: "https://test.workers.dev"))
        )
        service.restoreSession()

        #expect(service.authState == .disconnected)
    }

    // MARK: - Disconnect

    @Test("Disconnect clears auth state")
    func disconnect() async throws {
        let prefix = "test.lastfm.\(UUID().uuidString)"
        let store = KeychainCredentialStore(servicePrefix: prefix)

        try store.saveLastFMSessionKey("test-key")
        try store.saveLastFMUsername("testuser")

        let service = try LastFMService(
            credentialStore: store,
            workerBaseURL: #require(URL(string: "https://test.workers.dev"))
        )
        service.restoreSession()
        #expect(service.authState.isConnected)

        await service.disconnect()

        #expect(service.authState == .disconnected)
        #expect(store.getLastFMSessionKey() == nil)
        #expect(store.getLastFMUsername() == nil)
    }

    // MARK: - ScrobbleError

    @Test("ScrobbleError has localized descriptions")
    func errorDescriptions() throws {
        let errors: [ScrobbleError] = [
            .invalidCredentials,
            .sessionExpired,
            .rateLimited(retryAfter: 30),
            .rateLimited(retryAfter: nil),
            .networkError(underlying: "timeout"),
            .serviceUnavailable,
            .invalidResponse("bad json"),
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(try !#require(error.errorDescription?.isEmpty))
        }
    }

    @Test("ScrobbleError rateLimited includes retry time")
    func rateLimitedDescription() {
        let error = ScrobbleError.rateLimited(retryAfter: 30)
        #expect(error.errorDescription?.contains("30") == true)
    }

    // MARK: - ScrobbleAuthState

    @Test("ScrobbleAuthState isConnected")
    func authStateIsConnected() {
        #expect(ScrobbleAuthState.disconnected.isConnected == false)
        #expect(ScrobbleAuthState.authenticating.isConnected == false)
        #expect(ScrobbleAuthState.connected(username: "test").isConnected == true)
        #expect(ScrobbleAuthState.error("fail").isConnected == false)
    }

    @Test("ScrobbleAuthState username")
    func authStateUsername() {
        #expect(ScrobbleAuthState.disconnected.username == nil)
        #expect(ScrobbleAuthState.authenticating.username == nil)
        #expect(ScrobbleAuthState.connected(username: "testuser").username == "testuser")
        #expect(ScrobbleAuthState.error("fail").username == nil)
    }

    // MARK: - Scrobble without session throws

    @Test("Scrobble without session throws sessionExpired")
    func scrobbleWithoutSession() async throws {
        let service = try LastFMService(
            credentialStore: KeychainCredentialStore(servicePrefix: "test.lastfm.\(UUID().uuidString)"),
            workerBaseURL: #require(URL(string: "https://test.workers.dev"))
        )

        do {
            _ = try await service.scrobble([
                ScrobbleTrack(title: "Test", artist: "Artist"),
            ])
            Issue.record("Expected sessionExpired error")
        } catch let error as ScrobbleError {
            #expect(error == .sessionExpired)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("UpdateNowPlaying without session throws sessionExpired")
    func nowPlayingWithoutSession() async throws {
        let service = try LastFMService(
            credentialStore: KeychainCredentialStore(servicePrefix: "test.lastfm.\(UUID().uuidString)"),
            workerBaseURL: #require(URL(string: "https://test.workers.dev"))
        )

        do {
            try await service.updateNowPlaying(
                ScrobbleTrack(title: "Test", artist: "Artist")
            )
            Issue.record("Expected sessionExpired error")
        } catch let error as ScrobbleError {
            #expect(error == .sessionExpired)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - Empty scrobble batch

    @Test("Scrobble empty array returns empty results")
    func scrobbleEmptyArray() async throws {
        let prefix = "test.lastfm.\(UUID().uuidString)"
        let store = KeychainCredentialStore(servicePrefix: prefix)
        try store.saveLastFMSessionKey("test-key")
        try store.saveLastFMUsername("testuser")

        let service = try LastFMService(
            credentialStore: store,
            workerBaseURL: #require(URL(string: "https://test.workers.dev"))
        )
        service.restoreSession()

        let results = try await service.scrobble([])
        #expect(results.isEmpty)

        // Cleanup
        store.removeLastFMCredentials()
    }

    // MARK: - ValidateSession without credentials

    @Test("ValidateSession returns false without session key")
    func validateSessionNoKey() async throws {
        let service = try LastFMService(
            credentialStore: KeychainCredentialStore(servicePrefix: "test.lastfm.\(UUID().uuidString)"),
            workerBaseURL: #require(URL(string: "https://test.workers.dev"))
        )

        let valid = try await service.validateSession()
        #expect(valid == false)
    }
}

// MARK: - ScrobbleError + Equatable

extension ScrobbleError: Equatable {
    public static func == (lhs: ScrobbleError, rhs: ScrobbleError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidCredentials, .invalidCredentials):
            true
        case (.sessionExpired, .sessionExpired):
            true
        case (.serviceUnavailable, .serviceUnavailable):
            true
        case let (.rateLimited(a), .rateLimited(b)):
            a == b
        case let (.networkError(a), .networkError(b)):
            a == b
        case let (.invalidResponse(a), .invalidResponse(b)):
            a == b
        default:
            false
        }
    }
}
