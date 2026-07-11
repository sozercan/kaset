import Foundation

extension ScrobblingCoordinator {
    func prepareForTermination(timeout: Duration = .seconds(3)) async {
        self.stopMonitoring(finalizeCurrentTrack: true)
        let deadline = ContinuousClock.now + timeout
        while !self.pendingMixFinalizations.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }

        guard !self.pendingMixFinalizations.isEmpty else { return }
        for pending in self.pendingMixFinalizations.values {
            pending.parseTask.cancel()
            pending.finalizationTask.cancel()
            for scrobble in pending.fallbackScrobbles {
                self.queue.enqueue(scrobble)
            }
        }
        self.pendingMixFinalizations.removeAll()
    }

    func deferPendingRegularTrackFinalizationIfNeeded() -> Bool {
        guard case .parsing = self.mixDetectionState,
              let parseTask = self.mixParseTask,
              let tracker = self.trackTracker,
              let song = self.trackedSong
        else { return false }

        let duration = self.trackedVideoDuration ?? song.duration.flatMap { $0 > 0 ? $0 : nil }
        let provisionalMixHistory = self.provisionalMixHistory
        let trackThresholds = self.trackThresholds
        let mixEntryThresholds = self.mixEntryThresholds
        let timeout = self.mixParseTimeout
        var pendingWholeTrackPlays = self.pendingWholeTrackPlays
        if let lastIndex = pendingWholeTrackPlays.indices.last,
           pendingWholeTrackPlays[lastIndex].tracker.startTime == tracker.startTime
        {
            pendingWholeTrackPlays[lastIndex] = PendingWholeTrackPlay(
                tracker: tracker,
                song: pendingWholeTrackPlays[lastIndex].song
            )
        }
        let currentWholeTrackEligible = !tracker.hasScrobbled
            && tracker.meetsThreshold(duration: duration, thresholds: trackThresholds)
        guard currentWholeTrackEligible
            || !pendingWholeTrackPlays.isEmpty
            || provisionalMixHistory.hasPlayback
        else { return false }

        self.mixParseGeneration += 1
        self.mixParseMonitorTask?.cancel()
        self.mixParseMonitorTask = nil
        self.mixParseTimeoutTask?.cancel()
        self.mixParseTimeoutTask = nil
        self.mixParseTask = nil
        self.mixParseStartedWithoutDuration = false
        self.pendingWholeTrackPlays.removeAll()

        var fallbackScrobbles = self.wholeTrackScrobbles(
            from: pendingWholeTrackPlays,
            duration: duration,
            thresholds: trackThresholds
        )
        if currentWholeTrackEligible {
            fallbackScrobbles.append(ScrobbleTrack(
                title: song.title,
                artist: song.artistsDisplay,
                album: song.album?.title,
                duration: duration,
                timestamp: tracker.startTime,
                videoId: song.videoId
            ))
        }

        let id = UUID()
        let queue = self.queue
        let logger = DiagnosticsLogger.scrobbling
        let finalizationTask = Task { @MainActor [weak self] in
            let outcome = await Self.awaitDeferredMixParse(parseTask, timeout: timeout)
            self?.pendingMixFinalizations.removeValue(forKey: id)
            guard !Task.isCancelled else { return }

            let tracklist: MixTracklist?
            switch outcome {
            case let .parsed(parsedTracklist):
                tracklist = parsedTracklist
            case .timedOut:
                tracklist = nil
                logger.warning("Deferred mix parse timed out; committing whole-track fallback for \(song.title)")
            }

            let shouldUseMixResult = Self.shouldUseDeferredMixResult(
                tracklist,
                songDuration: song.duration,
                playerDuration: duration
            )
            if let tracklist, shouldUseMixResult {
                let scrobbles = provisionalMixHistory.scrobbles(
                    tracklist: tracklist,
                    song: song,
                    videoDuration: duration,
                    thresholds: mixEntryThresholds
                )
                for scrobble in scrobbles {
                    queue.enqueue(scrobble)
                }
                guard !scrobbles.isEmpty else { return }
                logger.info("Deferred mix finalized after track exit: \(scrobbles.count) sub-tracks for \(song.title)")
            } else {
                for scrobble in fallbackScrobbles {
                    queue.enqueue(scrobble)
                }
                guard !fallbackScrobbles.isEmpty else { return }
                logger.info("Deferred whole-track scrobbles finalized after mix detection: \(song.title)")
            }
            self?.scheduleQueueFlushIfNeeded()
        }
        self.pendingMixFinalizations[id] = PendingMixFinalization(
            parseTask: parseTask,
            finalizationTask: finalizationTask,
            fallbackScrobbles: fallbackScrobbles
        )
        return true
    }

    private static func shouldUseDeferredMixResult(
        _ tracklist: MixTracklist?,
        songDuration: TimeInterval?,
        playerDuration: TimeInterval?
    ) -> Bool {
        guard let tracklist, tracklist.isMix else { return false }
        let decision = Self.mixDurationDecision(
            for: tracklist,
            songDuration: songDuration,
            playerDuration: playerDuration,
            phase: .finalization
        )
        if case .mix = decision {
            return true
        }
        return false
    }

    private static func awaitDeferredMixParse(
        _ parseTask: Task<MixTracklist?, Never>,
        timeout: Duration
    ) async -> DeferredMixParseOutcome {
        let pair = AsyncStream<DeferredMixParseOutcome>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let parseWaiter = Task { @MainActor in
            let tracklist = await parseTask.value
            guard !Task.isCancelled else { return }
            pair.continuation.yield(.parsed(tracklist))
        }
        let timeoutWaiter = Task { @MainActor in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            pair.continuation.yield(.timedOut)
        }

        var iterator = pair.stream.makeAsyncIterator()
        let outcome = await iterator.next() ?? .timedOut
        parseWaiter.cancel()
        timeoutWaiter.cancel()
        pair.continuation.finish()
        if case .timedOut = outcome {
            parseTask.cancel()
        }
        return outcome
    }
}
