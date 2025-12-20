import AppKit
import SwiftUI

/// Main entry point for the Kaset macOS application.
@available(macOS 26.0, *)
@main
struct KasetApp: App {
    /// App delegate for lifecycle management (background playback).
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var authService = AuthService()
    @State private var webKitManager = WebKitManager.shared
    @State private var playerService = PlayerService()
    @State private var ytMusicClient: YTMusicClient?

    init() {
        let auth = AuthService()
        let webkit = WebKitManager.shared
        _authService = State(initialValue: auth)
        _webKitManager = State(initialValue: webkit)
        _ytMusicClient = State(initialValue: YTMusicClient(authService: auth, webKitManager: webkit))
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(authService)
                .environment(webKitManager)
                .environment(playerService)
                .task {
                    // Check if user is already logged in from previous session
                    await authService.checkLoginStatus()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Sign Out") {
                    Task {
                        await authService.signOut()
                    }
                }
                .disabled(authService.state == .loggedOut)
            }
        }
    }
}
