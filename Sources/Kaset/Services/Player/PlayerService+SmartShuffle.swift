import Foundation

@MainActor
extension PlayerService {
    struct SmartShuffleConfig {
        let suggestEveryN: Int
        let burst: Int
        let suggestionsAhead: Int
    }

    static func resolvedShuffleMode(
        _ mode: ShuffleMode,
        smartShuffleEnabled: Bool
    ) -> ShuffleMode {
        mode == .smart && !smartShuffleEnabled ? .on : mode
    }

    static func dedupeSuggestions(
        _ candidates: [Song],
        against existingIds: Set<String>
    ) -> [Song] {
        var seenIds = existingIds
        var result: [Song] = []
        for song in candidates {
            guard song.isPlayable, !seenIds.contains(song.videoId) else { continue }
            seenIds.insert(song.videoId)
            result.append(song)
        }
        return result
    }

    static func nextSuggestionSlot(
        in entries: [QueueEntry],
        afterIndex currentIndex: Int,
        everyN: Int,
        exhaustedSeeds: Set<String>
    ) -> Int? {
        guard everyN > 0 else { return nil }
        let start = max(currentIndex, 0)
        guard start < entries.count else { return nil }
        var originalsSinceSuggestion = 0
        for index in start ..< entries.count {
            if entries[index].source == .suggested {
                originalsSinceSuggestion = 0
                continue
            }
            originalsSinceSuggestion += 1
            if originalsSinceSuggestion >= everyN {
                let after = index + 1
                if after <= currentIndex {
                    originalsSinceSuggestion = 0
                    continue
                }
                if after < entries.count, entries[after].source == .suggested {
                    originalsSinceSuggestion = 0
                    continue
                }
                if exhaustedSeeds.contains(entries[index].song.videoId) {
                    originalsSinceSuggestion = 0
                    continue
                }
                return index
            }
        }
        return nil
    }

    static func stripSuggested(from entries: [QueueEntry], keepingCurrentID currentID: UUID?) -> [QueueEntry] {
        entries.filter { $0.source != .suggested || $0.id == currentID }
    }

    func fillSmartShuffleWindow() async {
        guard self.shuffleMode == .smart, self.ytMusicClient != nil else { return }
        guard !self.isQueueLoading else { return }
        guard self.smartShuffleFeatureEnabled() else { return }

        if let existing = self.smartShuffleFillTask {
            await existing.value
            return
        }

        self.smartShuffleFillEpoch += 1
        let epoch = self.smartShuffleFillEpoch
        let task = Task { @MainActor in await self.performSmartShuffleFill() }
        self.smartShuffleFillTask = task
        self.isApplyingSmartShuffle = true
        await task.value
        if self.smartShuffleFillEpoch == epoch {
            self.smartShuffleFillTask = nil
            self.isApplyingSmartShuffle = false
        }
    }

    private func performSmartShuffleFill() async {
        let config = self.smartShuffleConfigProvider()
        let everyN = max(1, config.suggestEveryN)
        let burst = max(1, config.burst)
        let target = max(1, config.suggestionsAhead)

        var transientlyFailedSeeds: Set<String> = []
        var radioErrorBudget = 3
        var didInsert = false

        var safety = self.queueEntries.count + (target + 2) * (everyN + burst) + 10
        while safety > 0,
              self.shuffleMode == .smart,
              self.smartShuffleFeatureEnabled(),
              !Task.isCancelled
        {
            safety -= 1
            let entries = self.queueEntries
            let upcomingStart = min(self.currentIndex + 1, entries.count)
            let suggestionsAhead = entries[upcomingStart...].count(where: { $0.source == .suggested })
            if suggestionsAhead >= target {
                break
            }
            guard let slot = Self.nextSuggestionSlot(
                in: entries,
                afterIndex: self.currentIndex,
                everyN: everyN,
                exhaustedSeeds: self.smartShuffleExhaustedSeeds.union(transientlyFailedSeeds)
            ) else {
                break
            }
            let seedEntry = entries[slot]

            guard let client = self.ytMusicClient else { break }
            var candidates: [Song] = []
            do {
                candidates = try await client.getRadioQueue(videoId: seedEntry.song.videoId)
            } catch {
                self.logger.warning("Smart shuffle radio fetch failed for \(seedEntry.song.videoId): \(error.localizedDescription)")
                transientlyFailedSeeds.insert(seedEntry.song.videoId)
                radioErrorBudget -= 1
                if radioErrorBudget <= 0 {
                    break
                }
                continue
            }

            guard self.shuffleMode == .smart,
                  self.smartShuffleFeatureEnabled(),
                  !Task.isCancelled
            else { break }
            let entriesNow = self.queueEntries
            guard let seedIndex = entriesNow.firstIndex(where: { $0.id == seedEntry.id }),
                  seedIndex >= self.currentIndex
            else {
                continue
            }

            let excludeIds = Set(entriesNow.map(\.song.videoId)).union(self.smartShuffleSeenSuggestionIds)
            let chosen = Array(
                Self.dedupeSuggestions(candidates, against: excludeIds).prefix(burst)
            )

            guard !chosen.isEmpty else {
                self.smartShuffleExhaustedSeeds.insert(seedEntry.song.videoId)
                continue
            }

            var updated = entriesNow
            let insertAt = min(seedIndex + 1, updated.count)
            updated.insert(
                contentsOf: chosen.map { QueueEntry(id: UUID(), song: $0, source: .suggested) },
                at: insertAt
            )
            self.smartShuffleSeenSuggestionIds.formUnion(chosen.map(\.videoId))
            self.applyAutomaticQueueChange { self.setQueue(entries: updated) }
            didInsert = true
        }

        if didInsert {
            self.saveQueueForPersistence()
        }
    }

    func stripSuggestedEntries() {
        let currentID = self.queueEntryIDOwningCurrentPlayback
        let kept = Self.stripSuggested(from: self.queueEntries, keepingCurrentID: currentID)
        guard kept.count != self.queueEntries.count else { return }
        self.setQueue(entries: kept)
        if let currentID, let restoredIndex = self.queueEntryIDs.firstIndex(of: currentID) {
            self.currentIndex = restoredIndex
        } else {
            self.currentIndex = min(self.currentIndex, max(0, kept.count - 1))
        }
    }

    func cancelSmartShuffleFill() {
        self.smartShuffleFillEpoch += 1
        self.smartShuffleFillTask?.cancel()
        self.smartShuffleFillTask = nil
        self.isApplyingSmartShuffle = false
    }

    func resetSmartShuffleState() {
        self.smartShuffleSeenSuggestionIds = []
        self.smartShuffleExhaustedSeeds = []
    }

    func resetSmartShuffleForNewQueue() {
        self.cancelSmartShuffleFill()
        self.resetSmartShuffleState()
    }

    func prepareForNewPlaybackContext() {
        self.cancelRemoteMusicTransportFollowUp()
        self.resetSmartShuffleForNewQueue()
        self.invalidateStaleQueueLoad()
        self.invalidateMixContinuationRequest()
    }

    func cancelDeferredQueueWork() {
        self.cancelRemoteMusicTransportFollowUp()
        self.invalidateStaleQueueLoad()
        self.cancelSmartShuffleFill()
        self.invalidateMixContinuationRequest()
    }

    func scheduleSmartShuffleFillForCurrentQueue() {
        let queueGeneration = self.queueLoadGeneration
        Task { @MainActor [weak self] in
            guard let self,
                  self.isCurrentQueueLoad(queueGeneration)
            else { return }
            await self.fillSmartShuffleWindow()
        }
    }

    func beginQueueLoading() -> Int {
        self.queueLoadGeneration += 1
        self.isQueueLoading = true
        return self.queueLoadGeneration
    }

    func isCurrentQueueLoad(_ generation: Int) -> Bool {
        generation == self.queueLoadGeneration
    }

    var userQueueMutationGeneration: Int {
        self.queueMutationGeneration &- self.automaticQueueMutationCount
    }

    func applyAutomaticQueueChange(_ change: () -> Void) {
        let before = self.queueMutationGeneration
        change()
        self.automaticQueueMutationCount &+= self.queueMutationGeneration &- before
    }

    func reserveQueueMutation() -> Int {
        self.queueLoadGeneration
    }

    func acceptsQueueMutation(_ generation: Int) -> Bool {
        self.isCurrentQueueLoad(generation)
    }

    func invalidateStaleQueueLoad() {
        self.queueLoadGeneration += 1
        self.isQueueLoading = false
    }

    func appendOriginalTracks(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let newEntries = songs.map { QueueEntry(id: UUID(), song: $0) }
        self.applyAutomaticQueueChange { self.setQueue(entries: self.queueEntries + newEntries) }
        if self.queueOrderBeforeShuffle != nil {
            self.queueOrderBeforeShuffle?.append(contentsOf: newEntries)
        }
        if !self.isQueueLoading {
            self.saveQueueForPersistence()
        }
    }

    func endQueueLoading(_ generation: Int) async {
        guard self.isCurrentQueueLoad(generation), self.isQueueLoading else { return }
        self.isQueueLoading = false
        self.applyAutomaticQueueChange { self.stripSuggestedEntries() }
        self.resetSmartShuffleState()
        if self.shuffleMode != .off {
            self.applyAutomaticQueueChange {
                self.materializeShuffleQueueForCurrentTrack(recordUndo: false, storesOriginalOrder: false)
            }
        } else {
            self.saveQueueForPersistence()
        }
        await self.fillSmartShuffleWindow()
    }
}
