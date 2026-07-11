import Foundation

@MainActor
extension PlayerService {
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
        self.queueNavigationRecoveryTask?.cancel()
        self.queueNavigationRecoveryTask = nil
        self.queueNavigationRecoveryVideoId = nil
    }

    func scheduleQueueNavigationRecovery(for song: Song) {
        guard self.queueNavigationRecoveryVideoId != song.videoId
            || self.queueNavigationRecoveryTask == nil
        else {
            self.logger.debug("Coalescing stale metadata recovery for \(song.videoId)")
            return
        }

        self.clearQueueNavigationRecovery()
        let generation = self.queueNavigationRecoveryGeneration
        self.queueNavigationRecoveryVideoId = song.videoId
        self.queueNavigationRecoveryTask = Task { @MainActor [weak self] in
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
            self.queueNavigationRecoveryTask = nil
            self.queueNavigationRecoveryVideoId = nil
        }
    }
}
