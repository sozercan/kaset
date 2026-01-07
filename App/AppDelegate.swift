import AppKit
import UserNotifications

// MARK: - AppDelegate

/// App delegate to control application lifecycle behavior.
/// Keeps the app running when windows are closed so audio playback continues.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Reference to the PlayerService for dock menu actions.
    /// Set by KasetApp after initialization.
    weak var playerService: PlayerService?

    func applicationDidFinishLaunching(_: Notification) {
        // Set up notification center delegate to show notifications in foreground
        UNUserNotificationCenter.current().delegate = self

        // In UI test mode, activate the app to bring window to foreground
        if UITestConfig.isUITestMode {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        // Set up window delegate to intercept close and hide instead
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            self.setupWindowDelegate()
        }
    }

    private func setupWindowDelegate() {
        for window in NSApplication.shared.windows where window.canBecomeMain {
            window.delegate = self
            // Enable automatic window frame persistence using autosave name
            // This ensures window size/position is restored across app launches
            if window.frameAutosaveName.isEmpty {
                window.setFrameAutosaveName("KasetMainWindow")
            }
        }
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let playPauseItem = NSMenuItem(
            title: "Play/Pause",
            action: #selector(dockMenuPlayPause),
            keyEquivalent: ""
        )
        playPauseItem.target = self
        menu.addItem(playPauseItem)

        let nextItem = NSMenuItem(
            title: "Next Track",
            action: #selector(dockMenuNext),
            keyEquivalent: ""
        )
        nextItem.target = self
        menu.addItem(nextItem)

        let previousItem = NSMenuItem(
            title: "Previous Track",
            action: #selector(dockMenuPrevious),
            keyEquivalent: ""
        )
        previousItem.target = self
        menu.addItem(previousItem)

        return menu
    }

    @objc private func dockMenuPlayPause() {
        guard let playerService else {
            // Fallback to direct WebView control if PlayerService not available
            SingletonPlayerWebView.shared.playPause()
            return
        }
        Task {
            await playerService.playPause()
        }
    }

    @objc private func dockMenuNext() {
        guard let playerService else {
            // Fallback to direct WebView control if PlayerService not available
            SingletonPlayerWebView.shared.next()
            return
        }
        Task {
            await playerService.next()
        }
    }

    @objc private func dockMenuPrevious() {
        guard let playerService else {
            // Fallback to direct WebView control if PlayerService not available
            SingletonPlayerWebView.shared.previous()
            return
        }
        Task {
            await playerService.previous()
        }
    }

    /// Keep app running when the window is closed (for background audio).
    /// Use Cmd+Q to fully quit.
    /// In UI test mode, terminate normally to avoid process conflicts.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        UITestConfig.isUITestMode
    }

    /// Handle reopen (clicking dock icon) when all windows are closed.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Reopen the main window if it was closed
            for window in NSApplication.shared.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }
}

// MARK: NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    /// Intercept window close and hide instead, keeping WebView alive for background audio.
    /// In UI test mode, close normally to avoid process conflicts.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // In UI test mode, allow normal close behavior
        if UITestConfig.isUITestMode {
            return true
        }

        // Hide the window instead of closing it
        sender.orderOut(nil)
        return false // Don't actually close
    }
}

// MARK: UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Show notifications even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner and play sound (if any) even when app is in foreground
        completionHandler([.banner])
    }
}
