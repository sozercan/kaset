import Foundation
import Observation

// MARK: - NowPlayingSnapshotStore

@MainActor
@Observable
final class NowPlayingSnapshotStore {
    private let playerService: any PlayerServiceProtocol
    private let lyricsService: SyncedLyricsService
    // swiftformat:disable modifierOrder
    /// Task for observing now-playing state, cancelled in deinit.
    /// nonisolated(unsafe) required for deinit access under Swift 6 actor isolation.
    @ObservationIgnored
    nonisolated(unsafe) private var observationTask: Task<Void, Never>?
    // swiftformat:enable modifierOrder

    private(set) var snapshot: NowPlayingSnapshot = .empty

    init(
        playerService: any PlayerServiceProtocol,
        lyricsService: SyncedLyricsService
    ) {
        self.playerService = playerService
        self.lyricsService = lyricsService
        self.refresh()
    }

    deinit {
        observationTask?.cancel()
    }

    func startObserving(interval: Duration = .milliseconds(250)) {
        guard self.observationTask == nil else { return }
        self.observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopObserving() {
        self.observationTask?.cancel()
        self.observationTask = nil
    }

    func refresh() {
        self.snapshot = Self.makeSnapshot(
            playerService: self.playerService,
            lyricsService: self.lyricsService
        )
    }

    private static func makeSnapshot(
        playerService: any PlayerServiceProtocol,
        lyricsService: SyncedLyricsService
    ) -> NowPlayingSnapshot {
        let track = playerService.currentTrack.map { song in
            NowPlayingTrackSnapshot(
                title: song.title,
                artist: song.artistsDisplay.trimmedNonEmpty,
                albumTitle: song.album?.title.trimmedNonEmpty,
                artworkURL: song.thumbnailURL ?? song.fallbackThumbnailURL,
                videoID: song.videoId
            )
        }

        return NowPlayingSnapshot(
            playbackState: playerService.state,
            track: track,
            elapsedSeconds: playerService.progress.isFinite ? playerService.progress : nil,
            durationSeconds: playerService.duration > 0 ? playerService.duration : nil,
            volume: max(0, min(1, playerService.volume)),
            shuffleEnabled: playerService.shuffleEnabled,
            repeatMode: playerService.repeatMode,
            likeStatus: playerService.currentTrackLikeStatus,
            currentLyricLine: Self.currentLyricLine(
                result: lyricsService.currentLyrics,
                currentTimeMs: playerService.currentTimeMs
            )
        )
    }

    private static func currentLyricLine(result: LyricResult, currentTimeMs: Int) -> SyncedLyricLine? {
        guard case let .synced(lyrics) = result,
              let index = lyrics.currentLineIndex(at: currentTimeMs)
        else {
            return nil
        }

        return lyrics.lines[index]
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
