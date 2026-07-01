import Foundation

// MARK: - LyricsPolling

@MainActor
protocol LyricsPolling: AnyObject {
    func startLyricsPoll()
    func stopLyricsPoll()
}

// MARK: - SingletonPlayerWebView + LyricsPolling

extension SingletonPlayerWebView: LyricsPolling {}

// MARK: - LyricsDemandCoordinator

@MainActor
final class LyricsDemandCoordinator {
    private let poller: any LyricsPolling
    private let playerService: (any PlayerServiceProtocol)?
    private let lyricsService: SyncedLyricsService?
    private let settingsManager: SettingsManager
    private var demandCounts: [NowPlayingSurfaceID: Int] = [:]
    private var isPolling = false
    // swiftformat:disable modifierOrder
    /// Task for observing active lyric demand, cancelled in deinit.
    /// nonisolated(unsafe) required for deinit access under Swift 6 actor isolation.
    nonisolated(unsafe) private var observationTask: Task<Void, Never>?
    // swiftformat:enable modifierOrder
    private var lastRequestedVideoID: String?

    init(
        poller: any LyricsPolling = SingletonPlayerWebView.shared,
        playerService: (any PlayerServiceProtocol)? = nil,
        lyricsService: SyncedLyricsService? = nil,
        settingsManager: SettingsManager = .shared
    ) {
        self.poller = poller
        self.playerService = playerService
        self.lyricsService = lyricsService
        self.settingsManager = settingsManager
    }

    deinit {
        observationTask?.cancel()
    }

    func setDemand(for consumer: NowPlayingSurfaceID, isActive: Bool) {
        if isActive {
            self.demandCounts[consumer, default: 0] += 1
        } else {
            let nextCount = max(0, self.demandCounts[consumer, default: 0] - 1)
            if nextCount == 0 {
                self.demandCounts[consumer] = nil
            } else {
                self.demandCounts[consumer] = nextCount
            }
        }

        self.reconcilePollingState()
    }

    func startObserving() {
        guard self.observationTask == nil else { return }
        self.observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshLyricsIfNeeded()
                self?.reconcilePollingState()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stopObserving() {
        self.observationTask?.cancel()
        self.observationTask = nil
        self.stopPollingIfNeeded()
    }

    func fetchSyncedLyricsIfNeeded(for track: Song) async {
        guard let lyricsService else { return }

        guard self.settingsManager.syncedLyricsEnabled else {
            lyricsService.currentLyrics = .unavailable
            lyricsService.activeProvider = nil
            self.reconcilePollingState()
            return
        }

        guard track.videoId != self.lastRequestedVideoID else { return }

        self.lastRequestedVideoID = track.videoId
        let info = LyricsSearchInfo(
            title: track.title,
            artist: track.artistsDisplay,
            album: track.album?.title,
            duration: track.duration,
            videoId: track.videoId
        )
        await lyricsService.fetchLyrics(for: info)
        self.reconcilePollingState()
    }

    private var hasDemand: Bool {
        !self.demandCounts.isEmpty
    }

    private func refreshLyricsIfNeeded() async {
        guard self.hasDemand,
              let playerService,
              let track = playerService.currentTrack
        else {
            return
        }

        await self.fetchSyncedLyricsIfNeeded(for: track)
    }

    private func reconcilePollingState() {
        let lyricsAreSynced = if let lyricsService {
            if case .synced = lyricsService.currentLyrics {
                true
            } else {
                false
            }
        } else {
            true
        }

        guard self.hasDemand,
              self.settingsManager.syncedLyricsEnabled,
              lyricsAreSynced
        else {
            self.stopPollingIfNeeded()
            return
        }

        self.startPollingIfNeeded()
    }

    private func startPollingIfNeeded() {
        guard !self.isPolling else { return }
        self.poller.startLyricsPoll()
        self.isPolling = true
    }

    private func stopPollingIfNeeded() {
        guard self.isPolling else { return }
        self.poller.stopLyricsPoll()
        self.isPolling = false
    }
}
