import Foundation

@MainActor
@Observable
final class NowPlayingTracklistProvider {
    private(set) var tracklist: MixTracklist?

    private static let minMixDuration: TimeInterval = 600

    private let parser: MixTracklistParser?
    private let retryDelay: Duration
    private let maxTransientRetryAttempts: Int
    private let logger = DiagnosticsLogger.player

    private var currentVideoId: String?

    private var attemptedVideoId: String?

    private var parseTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var parseGeneration = 0
    private var transientRetryAttempts = 0

    var isParsing: Bool {
        self.parseTask != nil || self.retryTask != nil
    }

    init(
        parser: MixTracklistParser?,
        retryDelay: Duration = .seconds(1),
        maxTransientRetryAttempts: Int = 1
    ) {
        self.parser = parser
        self.retryDelay = retryDelay
        self.maxTransientRetryAttempts = max(0, maxTransientRetryAttempts)
    }

    func update(track: Song?, duration: TimeInterval) {
        guard let track else {
            self.reset(to: nil)
            return
        }

        let normalizedVideoId = track.videoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedVideoId.isEmpty, normalizedVideoId != "unknown" else {
            self.reset(to: nil)
            return
        }

        if track.videoId != self.currentVideoId {
            self.reset(to: track.videoId)
        }

        guard self.tracklist == nil,
              self.attemptedVideoId != track.videoId,
              duration > Self.minMixDuration
        else { return }

        guard let parser else { return }

        self.attemptedVideoId = track.videoId
        let videoId = track.videoId
        let title = track.title
        let generation = self.parseGeneration
        self.parseTask = Task { [weak self] in
            let parsed = await parser.parseTracklist(videoId: videoId)
            guard let self else { return }
            guard self.currentVideoId == videoId, self.parseGeneration == generation else { return }
            self.parseTask = nil
            guard !Task.isCancelled else { return }
            if let parsed, parsed.isMix {
                self.tracklist = parsed
                self.logger.info("Now-playing tracklist loaded: \(parsed.entries.count) sub-tracks for \(title)")
                return
            }
            guard !parser.hasCachedResult(for: videoId) else { return }
            self.scheduleTransientRetry(
                track: track,
                duration: duration,
                videoId: videoId,
                generation: generation
            )
        }
    }

    private func scheduleTransientRetry(
        track: Song,
        duration: TimeInterval,
        videoId: String,
        generation: Int
    ) {
        guard self.transientRetryAttempts < self.maxTransientRetryAttempts else { return }
        self.transientRetryAttempts += 1
        let delay = self.retryDelay
        self.retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.currentVideoId == videoId,
                  self.parseGeneration == generation
            else { return }

            self.retryTask = nil
            self.attemptedVideoId = nil
            self.update(track: track, duration: duration)
        }
    }

    func currentEntry(at progress: TimeInterval) -> MixTrackEntry? {
        self.tracklist?.entry(at: progress)
    }

    private func reset(to videoId: String?) {
        self.parseTask?.cancel()
        self.parseTask = nil
        self.retryTask?.cancel()
        self.retryTask = nil
        self.parseGeneration &+= 1
        self.currentVideoId = videoId
        self.attemptedVideoId = nil
        self.transientRetryAttempts = 0
        self.tracklist = nil
    }
}
