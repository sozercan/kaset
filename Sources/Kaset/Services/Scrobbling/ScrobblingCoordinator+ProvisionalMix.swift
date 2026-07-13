import Foundation

extension ScrobblingCoordinator {
    func consumeProvisionalPlayback(for tracklist: MixTracklist, song: Song?) {
        guard let song, self.playerService.playbackStateVideoId == song.videoId else { return }
        guard self.provisionalMixHistory.hasPlayback else {
            self.provisionalMixHistory.removeAll()
            return
        }
        defer { self.provisionalMixHistory.removeAll() }
        let videoDuration = self.videoDuration(for: song)

        let credits = self.provisionalMixHistory.credits(
            tracklist: tracklist,
            videoDuration: videoDuration,
            thresholds: self.mixEntryThresholds
        )
        let activeEntryId = tracklist.entry(at: self.playerService.progress)?.id
        var enqueuedCount = 0

        for entry in tracklist.entries {
            let duration = tracklist.effectiveDuration(for: entry, videoDuration: videoDuration)
            let entryCredits = credits[entry.id] ?? []
            for credit in entryCredits {
                guard let startTime = credit.startTime else { continue }
                if credit.hasScrobbled {
                    self.queue.enqueue(ScrobbleTrack(
                        title: entry.title,
                        artist: entry.artist ?? song.artistsDisplay,
                        album: nil,
                        duration: duration,
                        timestamp: startTime,
                        videoId: song.videoId
                    ))
                    enqueuedCount += 1
                }
            }

            let hasHistoricalScrobble = entryCredits.contains(where: \.hasScrobbled)
            if entry.id == activeEntryId {
                let lastCredit = entryCredits.last
                let isContiguous = lastCredit.map {
                    $0.isActiveAtEnd
                        && abs($0.endProgress - self.playerService.progress) <= Self.mixReplayStartTolerance
                } ?? false
                if let lastCredit, isContiguous {
                    self.provisionalCurrentMixCredit = (entry.id, lastCredit)
                    if lastCredit.hasScrobbled {
                        self.mixEntryScrobbledIds.insert(entry.id)
                    } else {
                        self.mixEntryScrobbledIds.remove(entry.id)
                    }
                } else if hasHistoricalScrobble,
                          self.playerService.progress > entry.startTime + Self.mixReplayStartTolerance
                {
                    self.mixEntryScrobbledIds.insert(entry.id)
                } else {
                    self.mixEntryScrobbledIds.remove(entry.id)
                }
            } else if hasHistoricalScrobble {
                self.mixEntryScrobbledIds.insert(entry.id)
            }
        }

        if enqueuedCount > 0 {
            self.scheduleQueueFlushIfNeeded()
            self.logger.info("Mix detection credited \(enqueuedCount) sub-tracks from provisional playback")
        }
    }

    func finalizeResidualMixHistoryIfNeeded() {
        guard case let .mix(tracklist) = self.mixDetectionState,
              self.provisionalMixHistory.hasPlayback,
              let song = self.trackedSong
        else { return }

        let scrobbles = self.provisionalMixHistory.scrobbles(
            tracklist: tracklist,
            song: song,
            videoDuration: self.trackedVideoDuration,
            thresholds: self.mixEntryThresholds
        )
        for scrobble in scrobbles {
            self.queue.enqueue(scrobble)
        }
        self.provisionalMixHistory.removeAll()
        if !scrobbles.isEmpty {
            self.scheduleQueueFlushIfNeeded()
        }
    }
}
