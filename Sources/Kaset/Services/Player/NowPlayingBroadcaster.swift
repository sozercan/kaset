import Foundation
import Observation

/// Broadcasts a distributed notification when playback state changes so external
/// now-playing surfaces (e.g. the boring.notch "Kaset" media source) can refresh
/// without polling.
///
/// The notification is a bare, change-only trigger: it carries no `userInfo` (the
/// App Sandbox strips `userInfo` from a sandboxed sender's distributed
/// notifications), and the name is prefixed with the app's bundle id so the sandbox
/// permits posting it. It fires only on a *change* after `configure()` — there is no
/// initial snapshot and a missed notification is not resent — so listeners read the
/// full state via the `get player info` AppleScript command, and must poll it for the
/// initial state and for high-frequency values (position, volume) that are
/// deliberately not triggers.
@MainActor
final class NowPlayingBroadcaster {
    static let shared = NowPlayingBroadcaster()

    /// Distributed-notification name. **Published cross-process contract** — external
    /// listeners (e.g. boring.notch) match this exact string, so it must not change
    /// casually. Bundle-id-prefixed so the App Sandbox permits posting it.
    static let notificationName = "com.sertacozercan.Kaset.playerInfo"

    /// Weak: `PlayerService.shared` owns its own lifetime; the broadcaster must not retain it.
    private weak var playerService: PlayerService?
    private let logger = DiagnosticsLogger.player
    private var isConfigured = false

    private init() {}

    /// Begins observing the player and broadcasting on change. Idempotent.
    func configure(playerService: PlayerService) {
        guard !self.isConfigured else {
            self.logger.debug("NowPlayingBroadcaster already configured, skipping")
            return
        }
        self.isConfigured = true
        self.playerService = playerService
        self.observe()
        self.logger.info("NowPlayingBroadcaster configured")
    }

    private func observe() {
        withObservationTracking {
            // Track only the discrete fields a now-playing surface reacts to.
            // Deliberately excludes `progress` and `volume`: both change rapidly
            // (continuous playback / volume drags) and would flood the cross-process
            // notification. Consumers read position and volume via `get player info`.
            _ = self.playerService?.currentTrack?.videoId
            _ = self.playerService?.state
            _ = self.playerService?.currentTrackLikeStatus
            _ = self.playerService?.shuffleEnabled
            _ = self.playerService?.repeatMode
        } onChange: {
            Task { @MainActor [weak self] in
                self?.post()
                self?.observe()
            }
        }
    }

    private func post() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(Self.notificationName),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
