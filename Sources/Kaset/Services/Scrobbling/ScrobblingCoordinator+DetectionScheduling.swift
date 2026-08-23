import Foundation

extension ScrobblingCoordinator {
    func scheduleMixParseTimeout(for track: Song, videoId: String, generation: Int) {
        let timeout = self.mixParseTimeout
        self.mixParseTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let self,
                  self.mixParseGeneration == generation,
                  self.currentTrackVideoId == videoId,
                  case .parsing = self.mixDetectionState
            else { return }

            self.mixParseGeneration += 1
            self.mixParseTimeoutTask = nil
            self.mixParseMonitorTask?.cancel()
            self.mixParseMonitorTask = nil
            self.mixParseTask?.cancel()
            self.mixParseTask = nil
            self.mixParseStartedWithoutDuration = false
            self.logger.warning("Mix parse timed out; resuming whole-track scrobbling for \(track.title)")
            self.resolveAsNotMix()
            self.pollPlayerState()
        }
    }

    func scheduleUnknownDurationParse(for track: Song) {
        guard self.mixTracklistParser != nil else { return }
        let videoId = track.videoId
        let delay = self.unknownDurationParseDelay
        self.unknownDurationParseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self,
                  !Task.isCancelled,
                  self.currentTrackVideoId == videoId,
                  case .unresolved = self.mixDetectionState,
                  let parser = self.mixTracklistParser,
                  let trackedSong = self.trackedSong
            else { return }
            guard self.requiredPlaybackStateSequence == nil else {
                self.unknownDurationParseTask = nil
                return
            }
            if let songDuration = trackedSong.duration, songDuration > 0 {
                if songDuration > Self.mixMinimumVideoDuration {
                    self.startMixParse(for: trackedSong, parser: parser, startedWithoutDuration: false)
                } else {
                    self.resolveAsNotMix()
                    self.pollPlayerState()
                }
            } else {
                self.startMixParse(for: trackedSong, parser: parser, startedWithoutDuration: true)
            }
        }
    }

    /// Gives authoritative duration metadata a short grace period after a fallback parse. Once the
    /// grace period completes, later duration observations resolve directly without starting more
    /// timers, while tracklist bounds can independently prove a long mix.
    func scheduleAwaitingDurationConfirmation(for track: Song) {
        let videoId = track.videoId
        let expectedTitle = track.title
        let expectedArtist = track.artistsDisplay
        let delay = self.unknownDurationParseDelay
        self.durationConfirmationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self,
                  !Task.isCancelled,
                  self.currentTrackVideoId == videoId,
                  case let .awaitingDuration(tracklist) = self.mixDetectionState,
                  let currentTrack = self.playerService.currentTrack,
                  currentTrack.videoId == videoId,
                  currentTrack.title == expectedTitle,
                  currentTrack.artistsDisplay == expectedArtist
            else { return }

            self.durationConfirmationTask = nil
            self.durationConfirmationCompleted = true
            let decision = Self.mixDurationDecision(
                for: tracklist,
                songDuration: currentTrack.duration,
                playerDuration: self.scopedPlayerDuration(for: currentTrack),
                phase: .activeAfterGrace
            )
            self.applyMixDurationDecision(decision, tracklist: tracklist)
            self.pollPlayerState()
        }
    }
}
