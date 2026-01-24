import Foundation
import os

/// Centralized logging for the Kaset app.
enum DiagnosticsLogger {
    /// Logger for authentication-related events.
    static let auth = Logger(subsystem: "com.sertacozercan.Kaset", category: "Auth")

    /// Logger for API-related events.
    static let api = Logger(subsystem: "com.sertacozercan.Kaset", category: "API")

    /// Logger for WebKit-related events.
    static let webKit = Logger(subsystem: "com.sertacozercan.Kaset", category: "WebKit")

    /// Logger for player-related events.
    static let player = Logger(subsystem: "com.sertacozercan.Kaset", category: "Player")

    /// Logger for UI-related events.
    static let ui = Logger(subsystem: "com.sertacozercan.Kaset", category: "UI")

    /// Logger for notification-related events.
    static let notification = Logger(subsystem: "com.sertacozercan.Kaset", category: "Notification")

    /// Logger for AI/Foundation Models-related events.
    static let ai = Logger(subsystem: "com.sertacozercan.Kaset", category: "AI")

    /// Logger for haptic feedback-related events.
    static let haptic = Logger(subsystem: "com.sertacozercan.Kaset", category: "Haptic")

    /// Logger for network connectivity-related events.
    static let network = Logger(subsystem: "com.sertacozercan.Kaset", category: "Network")

    /// Logger for updater/general app events.
    static let updater = Logger(subsystem: "com.sertacozercan.Kaset", category: "Updater")

    /// Logger for app lifecycle and URL handling events.
    static let app = Logger(subsystem: "com.sertacozercan.Kaset", category: "App")

    /// Logger for AppleScript scripting events.
    static let scripting = Logger(subsystem: "com.sertacozercan.Kaset", category: "Scripting")
}
