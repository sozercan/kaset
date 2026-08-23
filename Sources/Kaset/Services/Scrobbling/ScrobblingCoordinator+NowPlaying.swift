import Foundation

extension ScrobblingCoordinator {
    func cancelNowPlayingTasks() {
        self.nowPlayingTasks.forEach { $0.cancel() }
        self.nowPlayingTasks.removeAll()
    }

    /// Sends a "now playing" update for a mix sub-track.
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

        // Cancel any in-flight now-playing tasks from a previous sub-track
        self.cancelNowPlayingTasks()

        for service in self.enabledConnectedServices {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await service.updateNowPlaying(scrobbleTrack)
                } catch is CancellationError {
                    // Expected when sub-track changes
                } catch {
                    self.logger.debug("Mix now playing failed for \(service.serviceName) (non-critical): \(error.localizedDescription)")
                }
            }
            self.nowPlayingTasks.append(task)
        }
    }

    // MARK: - Now Playing

    func sendNowPlaying(_ track: Song) {
        guard var tracker = self.trackTracker else { return }
        tracker.markNowPlayingSent()
        self.trackTracker = tracker

        let scrobbleTrack = ScrobbleTrack(from: track, timestamp: tracker.startTime)

        // Cancel any in-flight now-playing tasks from a previous track
        self.cancelNowPlayingTasks()

        // Send now-playing to all enabled+connected services
        for service in self.enabledConnectedServices {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await service.updateNowPlaying(scrobbleTrack)
                } catch is CancellationError {
                    // Expected when coordinator stops or track changes
                } catch {
                    self.logger.debug("Now playing update failed for \(service.serviceName) (non-critical): \(error.localizedDescription)")
                }
            }
            self.nowPlayingTasks.append(task)
        }
    }
}
