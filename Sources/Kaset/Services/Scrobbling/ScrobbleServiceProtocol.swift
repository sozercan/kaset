import Foundation

// MARK: - ScrobbleServiceProtocol

/// Protocol defining the interface for a scrobbling service backend.
/// Enables dependency injection, mocking, and future service implementations (ListenBrainz, Libre.fm).
@MainActor
protocol ScrobbleServiceProtocol: Sendable {
    /// Human-readable name of the scrobbling service (e.g., "Last.fm").
    var serviceName: String { get }

    /// Current authentication state of the service.
    var authState: ScrobbleAuthState { get }

    /// Initiates the authentication flow (e.g., opens browser for Last.fm authorization).
    func authenticate() async throws

    /// Disconnects the service and clears stored credentials.
    func disconnect() async

    /// Sends a "now playing" update for the currently playing track.
    /// This is fire-and-forget; failures are logged but not queued.
    func updateNowPlaying(_ track: ScrobbleTrack) async throws

    /// Submits a batch of scrobbles. Returns results indicating success/failure per track.
    func scrobble(_ tracks: [ScrobbleTrack]) async throws -> [ScrobbleResult]

    /// Validates the current session is still active.
    /// Returns `true` if the session is valid, `false` if re-authentication is needed.
    func validateSession() async throws -> Bool

    /// Restores authentication state from persistent storage (e.g., Keychain).
    /// Called on app launch to resume previous sessions without user interaction.
    func restoreSession()
}

// MARK: - ScrobbleTrack

/// A track prepared for scrobbling, containing the metadata needed by scrobbling services.
struct ScrobbleTrack: Codable, Sendable, Identifiable, Equatable {
    /// Unique identifier for this scrobble entry.
    let id: UUID

    /// Track title.
    let title: String

    /// Primary artist name.
    let artist: String

    /// Album name, if available.
    let album: String?

    /// Track duration in seconds, if known.
    let duration: TimeInterval?

    /// When playback started (used as scrobble timestamp).
    let timestamp: Date

    /// YouTube Music video ID for deduplication.
    let videoId: String?

    /// Creates a ScrobbleTrack from a Song model and playback start time.
    init(from song: Song, timestamp: Date) {
        self.id = UUID()
        self.title = song.title
        self.artist = song.artistsDisplay
        self.album = song.album?.title
        self.duration = song.duration
        self.timestamp = timestamp
        self.videoId = song.videoId
    }

    /// Memberwise initializer for testing and direct construction.
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

// MARK: - ScrobbleAuthState

/// Represents the authentication state of a scrobbling service.
enum ScrobbleAuthState: Equatable, Sendable {
    /// Not connected to the service.
    case disconnected

    /// Authentication is in progress (e.g., waiting for user to authorize in browser).
    case authenticating

    /// Successfully connected with the given username.
    case connected(username: String)

    /// An error occurred during authentication or session validation.
    case error(String)

    /// Whether the service is currently connected.
    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// The connected username, if any.
    var username: String? {
        if case let .connected(username) = self { return username }
        return nil
    }
}

// MARK: - ScrobbleError

/// Errors that can occur during scrobbling operations.
enum ScrobbleError: Error, LocalizedError, Sendable {
    /// Invalid credentials or session key.
    case invalidCredentials

    /// Session has expired and needs re-authentication.
    case sessionExpired

    /// Rate limited by the service. Retry after the specified interval.
    case rateLimited(retryAfter: TimeInterval?)

    /// Network error during communication.
    case networkError(underlying: String)

    /// Service is temporarily unavailable.
    case serviceUnavailable

    /// Invalid or unexpected response from the service.
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

// MARK: - ScrobbleResult

/// Result of a single scrobble submission.
struct ScrobbleResult: Sendable {
    /// The track that was submitted.
    let track: ScrobbleTrack

    /// Whether the scrobble was accepted by the service.
    let accepted: Bool

    /// Corrected artist name, if the service corrected it.
    let correctedArtist: String?

    /// Corrected track title, if the service corrected it.
    let correctedTrack: String?

    /// Error message if the scrobble was rejected.
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
