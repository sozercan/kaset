import Foundation
@testable import Kaset

@MainActor
final class MockScrobbleService: ScrobbleServiceProtocol {
    let serviceName = "Mock"

    var authState: ScrobbleAuthState = .disconnected

    private(set) var authenticateCalled = false
    private(set) var disconnectCalled = false
    private(set) var restoreSessionCalled = false
    private(set) var nowPlayingTracks: [ScrobbleTrack] = []
    private(set) var scrobbledBatches: [[ScrobbleTrack]] = []
    private(set) var validateSessionCalled = false

    var shouldThrowOnAuthenticate: Error?
    var shouldThrowOnNowPlaying: Error?
    var shouldThrowOnScrobble: Error?
    var beforeNowPlayingReturn: (@Sendable (ScrobbleTrack) async -> Void)?
    var scrobbleResults: [ScrobbleResult]?
    var validateSessionResult: Bool = true

    func authenticate() async throws {
        self.authenticateCalled = true
        if let error = self.shouldThrowOnAuthenticate {
            throw error
        }
        self.authState = .connected(username: "mockuser")
    }

    func disconnect() async {
        self.disconnectCalled = true
        self.authState = .disconnected
    }

    func restoreSession() {
        self.restoreSessionCalled = true
    }

    func updateNowPlaying(_ track: ScrobbleTrack) async throws {
        if let beforeNowPlayingReturn {
            await beforeNowPlayingReturn(track)
        }
        try Task.checkCancellation()
        self.nowPlayingTracks.append(track)
        if let error = self.shouldThrowOnNowPlaying {
            throw error
        }
    }

    func scrobble(_ tracks: [ScrobbleTrack]) async throws -> [ScrobbleResult] {
        self.scrobbledBatches.append(tracks)
        if let error = self.shouldThrowOnScrobble {
            throw error
        }
        if let results = self.scrobbleResults {
            return results
        }
        return tracks.map { ScrobbleResult(track: $0, accepted: true) }
    }

    func validateSession() async throws -> Bool {
        self.validateSessionCalled = true
        return self.validateSessionResult
    }

    func reset() {
        self.authenticateCalled = false
        self.disconnectCalled = false
        self.restoreSessionCalled = false
        self.nowPlayingTracks = []
        self.scrobbledBatches = []
        self.validateSessionCalled = false
        self.shouldThrowOnAuthenticate = nil
        self.shouldThrowOnNowPlaying = nil
        self.shouldThrowOnScrobble = nil
        self.beforeNowPlayingReturn = nil
        self.scrobbleResults = nil
        self.validateSessionResult = true
        self.authState = .disconnected
    }

    var totalScrobbledTracks: Int {
        self.scrobbledBatches.reduce(0) { $0 + $1.count }
    }
}
