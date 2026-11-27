import Foundation
import Sparkle

@MainActor
@Observable
final class UpdaterService {
    private let updaterController: SPUStandardUpdaterController

    var automaticChecksEnabled: Bool {
        get { self.updaterController.updater.automaticallyChecksForUpdates }
        set { self.updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool {
        self.updaterController.updater.canCheckForUpdates
    }

    var lastUpdateCheckDate: Date? {
        self.updaterController.updater.lastUpdateCheckDate
    }

    init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        DiagnosticsLogger.updater.info("UpdaterService initialized")
    }

    func checkForUpdates() {
        DiagnosticsLogger.updater.info("Manually checking for updates")
        self.updaterController.checkForUpdates(nil)
    }
}
