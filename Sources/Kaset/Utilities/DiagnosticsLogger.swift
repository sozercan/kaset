import Foundation
import os

enum DiagnosticsLogger {
    static let auth = Logger(subsystem: "com.sertacozercan.Kaset", category: "Auth")

    static let api = Logger(subsystem: "com.sertacozercan.Kaset", category: "API")

    static let webKit = Logger(subsystem: "com.sertacozercan.Kaset", category: "WebKit")

    static let player = Logger(subsystem: "com.sertacozercan.Kaset", category: "Player")

    static let ui = Logger(subsystem: "com.sertacozercan.Kaset", category: "UI")

    static let notification = Logger(subsystem: "com.sertacozercan.Kaset", category: "Notification")

    static let ai = Logger(subsystem: "com.sertacozercan.Kaset", category: "AI")

    static let haptic = Logger(subsystem: "com.sertacozercan.Kaset", category: "Haptic")

    static let network = Logger(subsystem: "com.sertacozercan.Kaset", category: "Network")

    static let updater = Logger(subsystem: "com.sertacozercan.Kaset", category: "Updater")

    static let app = Logger(subsystem: "com.sertacozercan.Kaset", category: "App")

    static let scripting = Logger(subsystem: "com.sertacozercan.Kaset", category: "Scripting")

    static let appIntents = Logger(subsystem: "com.sertacozercan.Kaset", category: "AppIntents")

    static let airplay = Logger(subsystem: "com.sertacozercan.Kaset", category: "AirPlay")

    static let scrobbling = Logger(subsystem: "com.sertacozercan.Kaset", category: "Scrobbling")

    static let extensions = Logger(subsystem: "com.sertacozercan.Kaset", category: "Extensions")

    static let history = Logger(subsystem: "com.sertacozercan.Kaset", category: "History")

    static let equalizer = Logger(subsystem: "com.sertacozercan.Kaset", category: "Equalizer")
}
