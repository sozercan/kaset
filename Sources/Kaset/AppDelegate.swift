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
    weak var scrobblingCoordinator: ScrobblingCoordinator?

    /// Reference to the main window for reliable reopen behavior.
    /// Using strong reference to prevent deallocation when window is hidden.
    private var mainWindow: NSWindow?

    /// Tracks when the app is quitting so we can allow window closures.
    private var isTerminating = false
    private var isPreparingTermination = false

    func applicationDidFinishLaunching(_: Notification) {
        DiagnosticsLogger.app.info("AppDelegate: applicationDidFinishLaunching")
        // Set up notification center delegate to show notifications in foreground
        if !UITestConfig.isRunningUnitTests {
            UNUserNotificationCenter.current().delegate = self
        }

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

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        self.isTerminating = true
        guard let scrobblingCoordinator else { return .terminateNow }
        guard !self.isPreparingTermination else { return .terminateLater }

        self.isPreparingTermination = true
        Task { @MainActor in
            await scrobblingCoordinator.prepareForTermination()
            self.playerService?.saveQueueForPersistence()
            application.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

    func applicationDidResignActive(_: Notification) {
        // WebKit freezes the page's requestAnimationFrame loop in the background, so the
        // media-key override (nexttrack/previoustrack) is no longer re-applied and YouTube
        // can reclaim it. Drive re-assertion from a native timer instead.
        SingletonPlayerWebView.shared.beginBackgroundMediaControlReassertion()
    }

    func applicationDidBecomeActive(_: Notification) {
        // Foreground: the page's requestAnimationFrame loop resumes ownership of the
        // override. Stop the native timer and re-assert once immediately.
        SingletonPlayerWebView.shared.endBackgroundMediaControlReassertion()
        SingletonPlayerWebView.shared.reassertMediaControlOverride()
        // When app becomes active (e.g., dock icon clicked), ensure main window is visible.
        // This handles the case where video window is visible but main window is hidden.
        if self.isSwitchedToMiniPlayer {
            if #available(macOS 26.0, *) {
                MiniPlayerWindowController.shared.orderFrontIfVisible()
            }
            return
        }
        self.showMainWindowIfNeeded()
    }

    private func setupWindowDelegate() {
        DiagnosticsLogger.app.info("AppDelegate: setupWindowDelegate starting")
        for window in NSApplication.shared.windows where window.canBecomeMain {
            // Skip auxiliary/player and non-primary scene windows; only the regular app window should be hidden-on-close.
            if self.isAuxiliaryPlayerWindow(window) || !MainWindowLayout.isPrimaryWindow(window) {
                continue
            }
            window.delegate = self
            MainWindowLayout.configure(window)
            // Store reference to main window for reliable reopen
            self.mainWindow = window
        }
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        // Menu-wide: with auto-enable off, every item must set `isEnabled` itself —
        // AppKit no longer enables an item just because its target responds to the
        // action. Required so the Like item can grey out with no track; the transport
        // items below rely on NSMenuItem's default (enabled). Any future item added
        // here must set its own isEnabled.
        menu.autoenablesItems = false

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

        menu.addItem(.separator())

        // Like/Unlike the current track. Title mirrors the player-bar thumbs-up
        // toggle; disabled when nothing is playing. A disliked track also reads
        // "Like" — clicking replaces the dislike with a like, matching the player
        // bar (the dock has no dislike affordance).
        let canMutateAccount = self.playerService?.canPerformAccountMutation == true
        let isLiked = canMutateAccount && self.playerService?.currentTrackLikeStatus == .like
        let likeItem = NSMenuItem(
            title: isLiked ? String(localized: "Unlike") : String(localized: "Like"),
            action: #selector(self.dockMenuToggleLike),
            keyEquivalent: ""
        )
        likeItem.target = self
        likeItem.isEnabled = self.playerService?.currentTrack != nil && canMutateAccount
        menu.addItem(likeItem)

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

    @objc private func dockMenuToggleLike() {
        // Like requires the API-backed SongLikeStatusManager, so there is no
        // WebView-only fallback like the transport actions have.
        self.playerService?.likeCurrentTrack()
    }

    /// Keep app running when the window is closed (for background audio).
    /// Use Cmd+Q to fully quit.
    /// In UI test mode, terminate normally to avoid process conflicts.
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        UITestConfig.isUITestMode
    }

    /// Handle reopen (clicking dock icon) when all windows are closed.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        if self.isSwitchedToMiniPlayer {
            if #available(macOS 26.0, *) {
                MiniPlayerWindowController.shared.orderFrontIfVisible()
            }
            return false
        }

        // Show main window when dock icon is clicked
        self.showMainWindowIfNeeded()
        return true
    }

    private var isSwitchedToMiniPlayer: Bool {
        guard let playerService else { return false }
        return playerService.isMiniPlayerVisible && playerService.miniPlayerMode == .switchFromMainWindow
    }

    /// Shows the main window if it's not visible.
    private func showMainWindowIfNeeded() {
        DiagnosticsLogger.app.info("AppDelegate: showMainWindowIfNeeded")
        // Try stored reference first
        if let mainWindow, MainWindowLayout.isPrimaryWindow(mainWindow) {
            MainWindowLayout.configure(mainWindow)
            if !mainWindow.isVisible {
                mainWindow.makeKeyAndOrderFront(nil)
            }
            return
        }

        // Fallback: find main window by frameAutosaveName
        for window in NSApplication.shared.windows where window.frameAutosaveName == MainWindowLayout.autosaveName {
            MainWindowLayout.configure(window)
            self.mainWindow = window
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }

        // Last resort: find any main-capable window that's not an auxiliary player window.
        // Do not apply the primary-window sizing contract here: a generic fallback
        // may match Settings or another regular scene window.
        for window in NSApplication.shared.windows where window.canBecomeMain {
            if self.isAuxiliaryPlayerWindow(window) {
                continue
            }
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
    }

    private func isAuxiliaryPlayerWindow(_ window: NSWindow) -> Bool {
        AccessibilityID.isAuxiliaryPlayerWindowIdentifier(window.identifier?.rawValue)
    }
}

// MARK: NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    /// Intercept window close and hide instead, keeping WebView alive for background audio.
    /// In UI test mode, close normally to avoid process conflicts.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // In UI test mode, allow normal close behavior
        if UITestConfig.isUITestMode || self.isTerminating {
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
