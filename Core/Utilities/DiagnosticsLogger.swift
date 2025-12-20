import Foundation
import os

/// Centralized logging for the YouTube Music app.
enum DiagnosticsLogger {
    /// Logger for authentication-related events.
    static let auth = Logger(subsystem: "com.example.YouTubeMusic", category: "Auth")

    /// Logger for API-related events.
    static let api = Logger(subsystem: "com.example.YouTubeMusic", category: "API")

    /// Logger for WebKit-related events.
    static let webKit = Logger(subsystem: "com.example.YouTubeMusic", category: "WebKit")

    /// Logger for player-related events.
    static let player = Logger(subsystem: "com.example.YouTubeMusic", category: "Player")

    /// Logger for UI-related events.
    static let ui = Logger(subsystem: "com.example.YouTubeMusic", category: "UI")
}
