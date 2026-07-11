import Foundation

@MainActor
extension PlayerService {
    private static let queueNavigationRecoveryTimeout: Duration = .seconds(8)

    func finishPlaybackAfterFailedQueueAdvance(reason: String) async {
        self.mixContinuationToken = nil
        self.mixContinuationRequiresAuth = false
        self.shouldSuppressAutoplayAfterQueueEnd = true
        self.markPlaybackEnded()
        self.logger.info("Ending playback after failed queue advance: \(reason)")
        await self.pause()
    }

    func clearQueueNavigationRecovery() {
        self.queueNavigationRecoveryGeneration &+= 1
        self.queueNavigationRecoveryLoadTask?.cancel()
        self.queueNavigationRecoveryLoadTask = nil
        self.queueNavigationRecoveryTask?.cancel()
        self.queueNavigationRecoveryTask = nil
        self.queueNavigationRecoveryVideoId = nil
    }

    func scheduleQueueNavigationRecovery(for song: Song) {
        guard self.queueNavigationRecoveryVideoId != song.videoId else {
            self.logger.debug("Coalescing stale metadata recovery for \(song.videoId)")
            return
        }

        self.clearQueueNavigationRecovery()
        let generation = self.queueNavigationRecoveryGeneration
        self.queueNavigationRecoveryVideoId = song.videoId
        self.protectQueueNavigationTarget(song.videoId)
        self.queueNavigationRecoveryLoadTask = Task { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  self.queueNavigationRecoveryGeneration == generation,
                  self.queueNavigationRecoveryVideoId == song.videoId
            else {
                return
            }

            await self.play(
                song: song,
                webLoadStrategy: .forceFullPageWhenSameVideoId,
                isQueueNavigationRecovery: true
            )

            guard self.queueNavigationRecoveryGeneration == generation else { return }
            self.queueNavigationRecoveryLoadTask = nil
        }
        self.queueNavigationRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.queueNavigationRecoveryTimeout)
            } catch {
                return
            }
            guard let self,
                  self.queueNavigationRecoveryGeneration == generation,
                  self.queueNavigationRecoveryVideoId == song.videoId
            else {
                return
            }
            self.queueNavigationRecoveryGeneration &+= 1
            self.queueNavigationRecoveryLoadTask?.cancel()
            self.queueNavigationRecoveryLoadTask = nil
            self.queueNavigationRecoveryTask = nil
            self.queueNavigationRecoveryVideoId = nil
        }
    }
}
