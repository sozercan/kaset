import AppKit
import UserNotifications

extension Notification.Name {
    static let kasetOpenURLs = Notification.Name("kasetOpenURLs")
}

enum AppActivationWindowPolicy {
    static func shouldRevealMainWindow(
        keyWindowIdentifier: String?,
        mainWindowIdentifier: String?
    ) -> Bool {
        !AccessibilityID.isAuxiliaryPlayerWindowIdentifier(keyWindowIdentifier)
            && !AccessibilityID.isAuxiliaryPlayerWindowIdentifier(mainWindowIdentifier)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var playerService: PlayerService?
    weak var scrobblingCoordinator: ScrobblingCoordinator?

    private var pendingOpenURLs: [URL] = []

    private var isOpenURLDeliveryReady = false

    private var mainWindow: NSWindow?

    private var isTerminating = false
    private var isPreparingTermination = false

    func applicationWillFinishLaunching(_: Notification) {
        SettingsManager.shared.appearance.apply()
    }

    func applicationDidFinishLaunching(_: Notification) {
        DiagnosticsLogger.app.info("AppDelegate: applicationDidFinishLaunching")
        if !UITestConfig.isRunningUnitTests {
            UNUserNotificationCenter.current().delegate = self
        }

        if UITestConfig.isUITestMode {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        self.registerForSleepWakeNotifications()

        if SettingsManager.shared.appExperience.includesMusic {
            self.playerService?.restoreQueueFromPersistence()
        } else {
            self.playerService?.loadPersistedPlaybackSessionOwnerScopeWithoutRestoring()
        }
    }

    func applicationWillTerminate(_: Notification) {
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

    private var wasPlayingBeforeSleep: Bool = false

    @objc private func systemWillSleep(_: Notification) {
        self.wasPlayingBeforeSleep = self.playerService?.isPlaying ?? false
        if self.wasPlayingBeforeSleep {
            DiagnosticsLogger.player.info("System going to sleep, pausing playback")
            SingletonPlayerWebView.shared.pause()
        }
    }

    @objc private func systemDidWake(_: Notification) {
        DiagnosticsLogger.player.info("System woke from sleep, wasPlayingBeforeSleep: \(self.wasPlayingBeforeSleep)")
    }

    func applicationDidResignActive(_: Notification) {
        SingletonPlayerWebView.shared.beginBackgroundMediaControlReassertion()
    }

    func applicationDidBecomeActive(_: Notification) {
        SingletonPlayerWebView.shared.endBackgroundMediaControlReassertion()
        SingletonPlayerWebView.shared.reassertMediaControlOverride()
        if self.isSwitchedToMiniPlayer {
            if #available(macOS 26.0, *) {
                MiniPlayerWindowController.shared.orderFrontIfVisible()
            }
            return
        }

        let application = NSApplication.shared
        guard AppActivationWindowPolicy.shouldRevealMainWindow(
            keyWindowIdentifier: application.keyWindow?.identifier?.rawValue,
            mainWindowIdentifier: application.mainWindow?.identifier?.rawValue
        ) else { return }

        self.showMainWindowIfNeeded()
    }

    func registerMainWindow(_ window: NSWindow) {
        guard !self.isAuxiliaryPlayerWindow(window) else { return }
        window.delegate = self
        MainWindowLayout.configureKnownPrimaryWindow(window)
        self.mainWindow = window
    }

    func unregisterMainWindow(_ window: NSWindow) {
        guard self.mainWindow === window else { return }
        if window.delegate === self {
            window.delegate = nil
        }
        self.mainWindow = nil
    }

    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        let menu = NSMenu()
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
            SingletonPlayerWebView.shared.playPause()
            return
        }
        Task {
            await playerService.playPause()
        }
    }

    @objc private func dockMenuNext() {
        guard let playerService else {
            SingletonPlayerWebView.shared.next()
            return
        }
        Task {
            await playerService.next()
        }
    }

    @objc private func dockMenuPrevious() {
        guard let playerService else {
            SingletonPlayerWebView.shared.previous()
            return
        }
        Task {
            await playerService.previous()
        }
    }

    @objc private func dockMenuToggleLike() {
        self.playerService?.likeCurrentTrack()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        UITestConfig.isUITestMode
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        if self.isSwitchedToMiniPlayer {
            if #available(macOS 26.0, *) {
                MiniPlayerWindowController.shared.orderFrontIfVisible()
            }
            return false
        }

        self.showMainWindowIfNeeded()
        return true
    }

    func application(_: NSApplication, open urls: [URL]) {
        DiagnosticsLogger.app.info("AppDelegate: open \(urls.count) URL(s)")
        self.deliverOpenURLs(urls)
    }

    func beginOpenURLDelivery() {
        self.isOpenURLDeliveryReady = true
        let pending = self.pendingOpenURLs
        self.pendingOpenURLs.removeAll()
        self.deliverOpenURLs(pending)
    }

    private func deliverOpenURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if self.isOpenURLDeliveryReady {
            NotificationCenter.default.post(name: .kasetOpenURLs, object: urls)
        } else {
            self.pendingOpenURLs.append(contentsOf: urls)
        }
    }

    private var isSwitchedToMiniPlayer: Bool {
        guard let playerService else { return false }
        return playerService.isMiniPlayerVisible && playerService.miniPlayerMode == .switchFromMainWindow
    }

    private func showMainWindowIfNeeded() {
        DiagnosticsLogger.app.info("AppDelegate: showMainWindowIfNeeded")
        if let mainWindow, MainWindowLayout.isPrimaryWindow(mainWindow) {
            MainWindowLayout.configure(mainWindow)
            if !mainWindow.isVisible {
                mainWindow.makeKeyAndOrderFront(nil)
            }
            return
        }

        for window in NSApplication.shared.windows where window.frameAutosaveName == MainWindowLayout.autosaveName {
            MainWindowLayout.configure(window)
            self.mainWindow = window
            if !window.isVisible {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }

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

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if UITestConfig.isUITestMode || self.isTerminating {
            return true
        }

        sender.orderOut(nil)
        return false
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
