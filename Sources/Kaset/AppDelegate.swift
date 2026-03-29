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

    /// Reference to the main window for reliable reopen behavior.
    /// Using strong reference to prevent deallocation when window is hidden.
    private var mainWindow: NSWindow?

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

        // Register for system sleep/wake notifications
        self.registerForSleepWakeNotifications()

        // Restore saved queue if available
        self.playerService?.restoreQueueFromPersistence()
    }

    func applicationWillTerminate(_: Notification) {
        // Save queue for persistence on next launch
        self.playerService?.saveQueueForPersistence()
        DiagnosticsLogger.player.info("Application will terminate - saved queue for persistence")
    }

    /// Registers for system sleep and wake notifications to handle playback appropriately.
    private func registerForSleepWakeNotifications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        notificationCenter.addObserver(
            self,
            selector: #selector(self.systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        notificationCenter.addObserver(
            self,
            selector: #selector(self.systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    /// Tracks whether audio was playing before system sleep (for resume on wake).
    private var wasPlayingBeforeSleep: Bool = false

    @objc private func systemWillSleep(_: Notification) {
        // Remember playback state and pause before sleep
        self.wasPlayingBeforeSleep = self.playerService?.isPlaying ?? false
        if self.wasPlayingBeforeSleep {
            DiagnosticsLogger.player.info("System going to sleep, pausing playback")
            SingletonPlayerWebView.shared.pause()
        }
    }

    @objc private func systemDidWake(_: Notification) {
        // Optionally resume playback after wake if it was playing before sleep
        // Note: We don't auto-resume by default as it could be surprising
        // Just log the wake event for now
        DiagnosticsLogger.player.info("System woke from sleep, wasPlayingBeforeSleep: \(self.wasPlayingBeforeSleep)")
    }

    func applicationDidBecomeActive(_: Notification) {
        // When app becomes active (e.g., dock icon clicked), ensure main window is visible.
        // This handles the case where video window is visible but main window is hidden.
        self.showMainWindowIfNeeded()
    }

    private func setupWindowDelegate() {
        for window in NSApplication.shared.windows where window.canBecomeMain {
            // Skip if this is the video window (has specific identifier)
            if window.identifier?.rawValue == AccessibilityID.VideoWindow.container {
                continue
            }
            window.delegate = self
            // Enable automatic window frame persistence using autosave name
            // This ensures window size/position is restored across app launches
            if window.frameAutosaveName.isEmpty {
                window.setFrameAutosaveName("KasetMainWindow")
            }
            // Store reference to main window for reliable reopen
            self.mainWindow = window
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
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        // Show main window when dock icon is clicked
        self.showMainWindowIfNeeded()
        return true
    }

    /// Shows the main window if it's not visible.
    private func showMainWindowIfNeeded() {
        // Try stored reference first
        if let mainWindow {
            if !mainWindow.isVisible {
                mainWindow.makeKeyAndOrderFront(nil)
            }
            return
        }

        // Fallback: find main window by frameAutosaveName
        for window in NSApplication.shared.windows where window.frameAutosaveName == "KasetMainWindow" {
            self.mainWindow = window
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }

        // Last resort: find any main-capable window that's not the video window
        for window in NSApplication.shared.windows where window.canBecomeMain {
            if window.identifier?.rawValue == AccessibilityID.VideoWindow.container {
                continue
            }
            self.mainWindow = window
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
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
