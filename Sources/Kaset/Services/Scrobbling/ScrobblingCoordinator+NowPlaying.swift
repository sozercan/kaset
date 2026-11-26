import Foundation

extension ScrobblingCoordinator {
    func cancelNowPlayingTasks() {
        self.nowPlayingTasks.forEach { $0.cancel() }
        self.nowPlayingTasks.removeAll()
    }

    func sendMixNowPlaying(_ entry: MixTrackEntry, song: Song) {
        guard var tracker = self.mixEntryTracker else { return }
        tracker.markNowPlayingSent()
        self.mixEntryTracker = tracker
        let duration = self.mixEntryDuration(entry, song: song)

        let scrobbleTrack = ScrobbleTrack(
            title: entry.title,
            artist: entry.artist ?? song.artistsDisplay,
            album: nil,
            duration: duration,
            timestamp: tracker.startTime,
            videoId: song.videoId
        )

        self.cancelNowPlayingTasks()

        for service in self.enabledConnectedServices {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await service.updateNowPlaying(scrobbleTrack)
                } catch is CancellationError {
                } catch {
                    self.logger.debug("Mix now playing failed for \(service.serviceName) (non-critical): \(error.localizedDescription)")
                }
            }
            self.nowPlayingTasks.append(task)
        }
    }

    func sendNowPlaying(_ track: Song) {
        guard var tracker = self.trackTracker else { return }
        tracker.markNowPlayingSent()
        self.trackTracker = tracker

        let scrobbleTrack = ScrobbleTrack(from: track, timestamp: tracker.startTime)

        self.cancelNowPlayingTasks()

        for service in self.enabledConnectedServices {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await service.updateNowPlaying(scrobbleTrack)
                } catch is CancellationError {
                } catch {
                    self.logger.debug("Now playing update failed for \(service.serviceName) (non-critical): \(error.localizedDescription)")
                }
            }
            self.nowPlayingTasks.append(task)
        }
    }
}
