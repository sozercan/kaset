import Foundation

// MARK: - DiscordPresencePayload

/// Represents the rich presence activity payload sent to Discord.
struct DiscordPresencePayload: Codable, Equatable, Sendable {
    /// Activity type (Listening = 2, Watching = 3).
    var type: Int

    /// Primary details line (e.g. song/video title).
    var details: String?

    /// Secondary state line (e.g. artist and album).
    var state: String?

    /// Timestamps for progress bar.
    var timestamps: Timestamps?

    /// Assets for artwork display.
    var assets: Assets?

    /// Interactive buttons (e.g. "Listen on YouTube Music").
    var buttons: [Button]?

    struct Timestamps: Codable, Equatable, Sendable {
        /// Playback start Unix epoch timestamp in milliseconds.
        var start: Int?

        /// Expected playback end Unix epoch timestamp in milliseconds.
        var end: Int?
    }

    struct Assets: Codable, Equatable, Sendable {
        /// Large image asset key or external HTTPS image URL.
        var large_image: String?

        /// Text tooltip for large image.
        var large_text: String?

        /// Small image asset key or external HTTPS image URL.
        var small_image: String?

        /// Text tooltip for small image.
        var small_text: String?
    }

    struct Button: Codable, Equatable, Sendable {
        /// Visible button label.
        var label: String

        /// URL opened when clicking the button.
        var url: String
    }
}

// MARK: - DiscordPresenceState

/// Status of the Discord connection.
enum DiscordPresenceState: Equatable, Sendable {
    /// Presence is disabled or disconnected.
    case disconnected

    /// Actively connecting (with optional attempt number 1...5).
    case connecting(attempt: Int)

    /// Connected and ready to receive presence updates.
    case connected

    /// Connection failed with description (after max retries or immediate failure).
    case error(String)

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = self {
            return true
        }
        return false
    }
}

// MARK: - DiscordPresenceServiceProtocol

/// Interface for Discord Presence transport implementations (Local IPC and Remote Gateway).
@MainActor
protocol DiscordPresenceServiceProtocol: Sendable {
    /// Current connection state.
    var state: DiscordPresenceState { get }

    /// Connects to Discord with exponential retry logic.
    func connect() async

    /// Disconnects from Discord.
    func disconnect() async

    /// Updates the active presence activity payload.
    func updatePresence(_ payload: DiscordPresencePayload?) async throws

    /// Clears the active presence.
    func clearPresence() async
}
