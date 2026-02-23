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

    // MARK: - Response Parsing (Fix #3: corrected metadata)

    @Test("parseScrobbleResponse reads corrected name from #text, not flag")
    func parseScrobbleResponseCorrectedMetadata() {
        let track = ScrobbleTrack(title: "Original Title", artist: "Original Artist")

        let response: [String: Any] = [
            "scrobbles": [
                "scrobble": [
                    "artist": ["corrected": "1", "#text": "Corrected Artist"],
                    "track": ["corrected": "1", "#text": "Corrected Title"],
                    "ignoredMessage": ["#text": ""],
                ] as [String: Any],
            ] as [String: Any],
        ]

        let results = LastFMService.parseScrobbleResponse(response, tracks: [track])

        #expect(results.count == 1)
        #expect(results[0].accepted)
        #expect(results[0].correctedArtist == "Corrected Artist")
        #expect(results[0].correctedTrack == "Corrected Title")
    }

    @Test("parseScrobbleResponse returns nil corrections when flag is 0")
    func parseScrobbleResponseNoCorrectionWhenFlagZero() {
        let track = ScrobbleTrack(title: "Song", artist: "Artist")

        let response: [String: Any] = [
            "scrobbles": [
                "scrobble": [
                    "artist": ["corrected": "0", "#text": "Artist"],
                    "track": ["corrected": "0", "#text": "Song"],
                    "ignoredMessage": ["#text": ""],
                ] as [String: Any],
            ] as [String: Any],
        ]

        let results = LastFMService.parseScrobbleResponse(response, tracks: [track])

        #expect(results[0].correctedArtist == nil)
        #expect(results[0].correctedTrack == nil)
    }

    @Test("parseScrobbleResponse detects rejected scrobbles via ignoredMessage code")
    func parseScrobbleResponseRejected() {
        let track = ScrobbleTrack(title: "Song", artist: "Artist")

        let response: [String: Any] = [
            "scrobbles": [
                "scrobble": [
                    "artist": ["corrected": "0", "#text": "Artist"],
                    "track": ["corrected": "0", "#text": "Song"],
                    "ignoredMessage": ["#text": "Track was ignored", "code": "1"],
                ] as [String: Any],
            ] as [String: Any],
        ]

        let results = LastFMService.parseScrobbleResponse(response, tracks: [track])

        #expect(!results[0].accepted)
        #expect(results[0].errorMessage == "Track was ignored")
    }

    @Test("parseScrobbleResponse accepts when ignoredMessage code is 0")
    func parseScrobbleResponseAcceptedWithCode0() {
        let track = ScrobbleTrack(title: "Song", artist: "Artist")

        let response: [String: Any] = [
            "scrobbles": [
                "scrobble": [
                    "artist": ["corrected": "0", "#text": "Artist"],
                    "track": ["corrected": "0", "#text": "Song"],
                    "ignoredMessage": ["#text": "", "code": "0"],
                ] as [String: Any],
            ] as [String: Any],
        ]

        let results = LastFMService.parseScrobbleResponse(response, tracks: [track])

        #expect(results[0].accepted)
        #expect(results[0].errorMessage == nil)
    }

    @Test("parseScrobbleResponse rejects when ignoredMessage code is non-zero with empty text")
    func parseScrobbleResponseRejectedEmptyText() {
        let track = ScrobbleTrack(title: "Song", artist: "Artist")

        let response: [String: Any] = [
            "scrobbles": [
                "scrobble": [
                    "artist": ["corrected": "0", "#text": "Artist"],
                    "track": ["corrected": "0", "#text": "Song"],
                    "ignoredMessage": ["#text": "", "code": "2"],
                ] as [String: Any],
            ] as [String: Any],
        ]

        let results = LastFMService.parseScrobbleResponse(response, tracks: [track])

        #expect(!results[0].accepted)
        #expect(results[0].errorMessage?.contains("code 2") == true)
    }

    @Test("parseScrobbleResponse marks all rejected when scrobbles key is missing")
    func parseScrobbleResponseMissingScrobblesKey() {
        let track = ScrobbleTrack(title: "Song", artist: "Artist")

        // Malformed response (e.g., worker error that passed checkForErrors)
        let response: [String: Any] = [
            "status": "ok",
        ]

        let results = LastFMService.parseScrobbleResponse(response, tracks: [track])

        #expect(results.count == 1)
        #expect(!results[0].accepted)
        #expect(results[0].errorMessage?.contains("Malformed") == true)
    }

    @Test("parseScrobbleResponse handles batch with mixed results")
    func parseScrobbleResponseBatch() {
        let tracks = [
            ScrobbleTrack(title: "Accepted Song", artist: "Artist"),
            ScrobbleTrack(title: "Rejected Song", artist: "Artist"),
        ]

        let response: [String: Any] = [
            "scrobbles": [
                "scrobble": [
                    [
                        "artist": ["corrected": "0", "#text": "Artist"],
                        "track": ["corrected": "0", "#text": "Accepted Song"],
                        "ignoredMessage": ["#text": "", "code": "0"],
                    ] as [String: Any],
                    [
                        "artist": ["corrected": "0", "#text": "Artist"],
                        "track": ["corrected": "0", "#text": "Rejected Song"],
                        "ignoredMessage": ["#text": "Artist was ignored", "code": "1"],
                    ] as [String: Any],
                ] as [[String: Any]],
            ] as [String: Any],
        ]

        let results = LastFMService.parseScrobbleResponse(response, tracks: tracks)

        #expect(results.count == 2)
        #expect(results[0].accepted)
        #expect(!results[1].accepted)
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
