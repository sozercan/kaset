import Foundation
import os

/// Centralized logging for the Kaset app.
nonisolated enum DiagnosticsLogger {
    /// Logger for authentication-related events.
    nonisolated static let auth = Logger(subsystem: "com.sertacozercan.Kaset", category: "Auth")

    /// Logger for API-related events.
    nonisolated static let api = Logger(subsystem: "com.sertacozercan.Kaset", category: "API")

    /// Logger for WebKit-related events.
    nonisolated static let webKit = Logger(subsystem: "com.sertacozercan.Kaset", category: "WebKit")

    /// Logger for player-related events.
    nonisolated static let player = Logger(subsystem: "com.sertacozercan.Kaset", category: "Player")

    /// Logger for UI-related events.
    nonisolated static let ui = Logger(subsystem: "com.sertacozercan.Kaset", category: "UI")

    /// Logger for notification-related events.
    nonisolated static let notification = Logger(subsystem: "com.sertacozercan.Kaset", category: "Notification")

    /// Logger for AI/Foundation Models-related events.
    nonisolated static let ai = Logger(subsystem: "com.sertacozercan.Kaset", category: "AI")

    /// Logger for haptic feedback-related events.
    nonisolated static let haptic = Logger(subsystem: "com.sertacozercan.Kaset", category: "Haptic")

    /// Logger for network connectivity-related events.
    nonisolated static let network = Logger(subsystem: "com.sertacozercan.Kaset", category: "Network")

    /// Logger for updater/general app events.
    nonisolated static let updater = Logger(subsystem: "com.sertacozercan.Kaset", category: "Updater")

    /// Logger for app lifecycle and URL handling events.
    nonisolated static let app = Logger(subsystem: "com.sertacozercan.Kaset", category: "App")
}
