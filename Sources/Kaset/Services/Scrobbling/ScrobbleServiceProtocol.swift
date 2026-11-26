import Foundation

@MainActor
protocol ScrobbleServiceProtocol: Sendable {
    var serviceName: String { get }

    var authState: ScrobbleAuthState { get }

    func authenticate() async throws

    func disconnect() async

    func updateNowPlaying(_ track: ScrobbleTrack) async throws

    func scrobble(_ tracks: [ScrobbleTrack]) async throws -> [ScrobbleResult]

    func validateSession() async throws -> Bool

    func restoreSession()
}

struct ScrobbleTrack: Codable, Identifiable, Equatable {
    let id: UUID

    let title: String

    let artist: String

    let album: String?

    let duration: TimeInterval?

    let timestamp: Date

    let videoId: String?

    init(from song: Song, timestamp: Date) {
        self.id = UUID()
        self.title = song.title
        self.artist = song.artistsDisplay
        self.album = song.album?.title
        self.duration = song.duration
        self.timestamp = timestamp
        self.videoId = song.videoId
    }

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval? = nil,
        timestamp: Date = Date(),
        videoId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.timestamp = timestamp
        self.videoId = videoId
    }
}

enum ScrobbleAuthState: Equatable {
    case disconnected

    case authenticating

    case connected(username: String)

    case error(String)

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }

    var username: String? {
        if case let .connected(username) = self {
            return username
        }
        return nil
    }
}

enum ScrobbleError: Error, LocalizedError {
    case invalidCredentials

    case sessionExpired

    case rateLimited(retryAfter: TimeInterval?)

    case networkError(underlying: String)

    case serviceUnavailable

    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            "Invalid credentials. Please reconnect your account."
        case .sessionExpired:
            "Session expired. Please reconnect your account."
        case let .rateLimited(retryAfter):
            if let seconds = retryAfter {
                "Rate limited. Try again in \(Int(seconds)) seconds."
            } else {
                "Rate limited. Please try again later."
            }
        case let .networkError(message):
            "Network error: \(message)"
        case .serviceUnavailable:
            "Service temporarily unavailable. Please try again later."
        case let .invalidResponse(message):
            "Invalid response: \(message)"
        }
    }
}

struct ScrobbleResult {
    let track: ScrobbleTrack

    let accepted: Bool

    let correctedArtist: String?

    let correctedTrack: String?

    let errorMessage: String?

    init(
        track: ScrobbleTrack,
        accepted: Bool,
        correctedArtist: String? = nil,
        correctedTrack: String? = nil,
        errorMessage: String? = nil
    ) {
        self.track = track
        self.accepted = accepted
        self.correctedArtist = correctedArtist
        self.correctedTrack = correctedTrack
        self.errorMessage = errorMessage
    }
}
