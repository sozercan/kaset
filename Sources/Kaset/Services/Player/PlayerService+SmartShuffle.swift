import Foundation

// MARK: - Smart Shuffle (pure helpers)

@MainActor
extension PlayerService {
    static func resolvedShuffleMode(
        _ mode: ShuffleMode,
        smartShuffleEnabled: Bool
    ) -> ShuffleMode {
        mode == .smart && !smartShuffleEnabled ? .on : mode
    }

    /// Filters candidates to playable songs not already present (matched by `videoId`), and drops
    /// duplicates within the candidate list. Order is preserved.
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

    /// Scans the upcoming window for the next insertion slot that still needs suggestions.
    /// Returns the index of the original entry whose radio should seed the slot (suggestions are
    /// inserted immediately after it), or `nil` if the window is already satisfied.
    ///
    /// Counting resets after any existing `.suggested` entry, so already-filled gaps are skipped —
    /// this makes the scan idempotent and safe to call repeatedly as the playhead advances.
    /// A slot whose seed is in `exhaustedSeeds` (its radio yielded nothing new) is skipped so the
    /// fill loop can never spin on an unfillable slot.
    static func nextSuggestionSlot(
        in entries: [QueueEntry],
        afterIndex currentIndex: Int,
        everyN: Int,
        exhaustedSeeds: Set<String>
    ) -> Int? {
        guard everyN > 0 else { return nil }
        // Count only your playlist's originals as "songs". The currently-playing track is included
        // when it is an original (so the first suggestion lands right after it), but a suggestion
        // you are playing is NOT counted — it never triggers more suggestions right after itself;
        // the cadence waits for the next original.
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
                // Never insert into the played prefix or before the current track.
                if after <= currentIndex {
                    originalsSinceSuggestion = 0
                    continue
                }
                if after < entries.count, entries[after].source == .suggested {
                    // Slot already filled — reset and keep scanning past the existing suggestion(s)
                    // so we don't keep targeting the same gap and clustering everything there.
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

    /// Removes `.suggested` entries, keeping any entry whose id matches `currentID`
    /// (so the currently-playing track is never removed mid-play).
    static func stripSuggested(from entries: [QueueEntry], keepingCurrentID currentID: UUID?) -> [QueueEntry] {
        entries.filter { $0.source != .suggested || $0.id == currentID }
    }

    // MARK: - Smart Shuffle (orchestration)

    /// Rolling, preceding-song filler. For each insertion slot in the upcoming window it seeds
    /// radio from the original track immediately before the slot, so suggestions stay locally
    /// coherent and self-diversify across a multi-genre playlist. Idempotent and rolling: called
    /// both when entering smart mode and on every track advance to keep the lookahead window full.
    ///
    /// Single-flight: concurrent callers (mode cycling, rapid advances, a deferred load finishing)
    /// coalesce onto one stored task instead of racing interleaved fill loops; a queue replacement
    /// cancels the in-flight fill via ``cancelSmartShuffleFill()``.
    func fillSmartShuffleWindow() async {
        guard self.shuffleMode == .smart, self.ytMusicClient != nil else { return }
        // Defer suggestion generation until the full playlist has loaded into the queue, so
        // candidates dedup against every track rather than only the first loaded batch.
        guard !self.isQueueLoading else { return }
        // If the feature was disabled in settings while still in smart mode, stop topping up.
        // Already-queued suggestions remain until the user cycles shuffle off (which strips them).
        guard self.smartShuffleFeatureEnabled() else { return }

        // Coalesce onto any fill already running rather than starting a second interleaved loop.
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
        // Only clear if a newer fill or a cancellation hasn't already taken ownership.
        if self.smartShuffleFillEpoch == epoch {
            self.smartShuffleFillTask = nil
            self.isApplyingSmartShuffle = false
        }
    }

    /// The actual fill loop, run inside the stored single-flight task. Assumes the entry guards in
    /// ``fillSmartShuffleWindow()`` already passed; bails promptly on cancellation or a mode change.
    private func performSmartShuffleFill() async {
        let everyN = max(1, SettingsManager.shared.smartShuffleSuggestEveryN)
        let burst = max(1, SettingsManager.shared.smartShuffleBurst)
        let target = max(1, SettingsManager.shared.smartShuffleSuggestionsAhead)

        // Seeds whose radio threw this pass: skipped for the rest of the pass (so later slots still
        // fill) but NOT banned for the session — a transient error should be retried next advance.
        var transientlyFailedSeeds: Set<String> = []
        // Bounded tolerance for radio errors within a single pass before giving up.
        var radioErrorBudget = 3
        var didInsert = false

        // Natural exits are reaching `target` suggestions ahead or `nextSuggestionSlot` returning
        // nil. `safety` is only a defensive backstop; sizing it by the queue length plus the fill
        // budget guarantees it cannot trip before a genuinely converged state, even when many seeds
        // are exhausted on a very long playlist.
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
                // Skip this seed for the rest of the pass and move on to later slots instead of
                // aborting the whole fill on the nearest gap.
                transientlyFailedSeeds.insert(seedEntry.song.videoId)
                radioErrorBudget -= 1
                if radioErrorBudget <= 0 {
                    break
                }
                continue
            }

            // The queue, mode, or feature setting may have changed while awaiting — re-validate
            // against current state before inserting any recommendations.
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

            // Dedup against everything already in the queue (originals + suggestions) plus prior
            // session suggestions, matched by videoId.
            let excludeIds = Set(entriesNow.map(\.song.videoId)).union(self.smartShuffleSeenSuggestionIds)
            let chosen = Array(
                Self.dedupeSuggestions(candidates, against: excludeIds).prefix(burst)
            )

            guard !chosen.isEmpty else {
                // This seed has nothing new to offer; mark it so the scan skips it next time.
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
            self.setQueue(entries: updated)
            didInsert = true
        }

        // Suggestions are ephemeral (stripped on save), so the persisted payload does not change as
        // they are inserted — persist once at the end rather than re-encoding the queue per insert.
        if didInsert {
            self.saveQueueForPersistence()
        }
    }

    /// Removes upcoming `.suggested` entries, keeping the currently-playing track, and realigns the index.
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

    /// Cancels the in-flight suggestion fill (if any) and turns off the "applying" UI hint.
    /// The cancelled task observes `Task.isCancelled` and stops at its next checkpoint.
    func cancelSmartShuffleFill() {
        self.smartShuffleFillEpoch += 1
        self.smartShuffleFillTask?.cancel()
        self.smartShuffleFillTask = nil
        self.isApplyingSmartShuffle = false
    }

    /// Clears in-memory smart-shuffle bookkeeping (seen set, exhausted seeds). Deliberately does
    /// NOT touch the in-flight fill flag/task — cancellation is handled by ``cancelSmartShuffleFill()``
    /// so clearing state can never race a running fill into a second interleaved loop.
    func resetSmartShuffleState() {
        self.smartShuffleSeenSuggestionIds = []
        self.smartShuffleExhaustedSeeds = []
    }

    /// Tears down smart-shuffle for a brand-new playback context: cancels any in-flight fill and
    /// clears the seen/exhausted bookkeeping so the new queue starts fresh. Without this, the prior
    /// queue's suggestions stay excluded and its exhausted seeds stay skipped, starving suggestions.
    func resetSmartShuffleForNewQueue() {
        self.cancelSmartShuffleFill()
        self.resetSmartShuffleState()
    }

    /// Full teardown for a non-deferred playback that replaces the queue: resets smart-shuffle and
    /// supersedes any in-flight deferred load so a stale pager cannot suppress or pollute the new
    /// playback's suggestions.
    func prepareForNewPlaybackContext() {
        self.cancelRemoteMusicTransportFollowUp()
        self.resetSmartShuffleForNewQueue()
        self.invalidateStaleQueueLoad()
        self.invalidateMixContinuationRequest()
    }

    /// Cancels async work owned by the current queue without otherwise changing
    /// the queue. Used by terminal/privacy/restoration boundaries.
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

    // MARK: - Progressive queue loading

    /// Marks the queue as still loading the rest of a playlist after playback started and returns
    /// the generation identifying this load stream. While loading, `fillSmartShuffleWindow` defers
    /// so suggestions dedup against the full set. Pass the generation back to `endQueueLoading(_:)`.
    func beginQueueLoading() -> Int {
        self.queueLoadGeneration += 1
        self.isQueueLoading = true
        return self.queueLoadGeneration
    }

    /// Whether `generation` still identifies the active load — false once a newer playback replaced
    /// the queue (and bumped the generation), so a stale deferred load can stand down instead of
    /// clobbering the new playback's loading state.
    func isCurrentQueueLoad(_ generation: Int) -> Bool {
        generation == self.queueLoadGeneration
    }

    func reserveQueueMutation() -> Int {
        self.queueLoadGeneration
    }

    func acceptsQueueMutation(_ generation: Int) -> Bool {
        self.isCurrentQueueLoad(generation)
    }

    /// Supersedes any in-flight deferred load without starting a new one: bumps the generation (so
    /// the prior stream sees it is stale) and clears the loading flag. Called by queue-replacing
    /// playback that is not itself a progressive load, so its own suggestion fill is not suppressed.
    func invalidateStaleQueueLoad() {
        self.queueLoadGeneration += 1
        self.isQueueLoading = false
    }

    /// Appends originals (in playlist order) to a queue that is still loading, keeping the
    /// pre-shuffle snapshot complete so "shuffle off" later restores the full original order.
    /// Late tracks land at the tail of a shuffled queue; `endQueueLoading` re-shuffles them in.
    /// Duplicate video IDs are preserved because authored playlists can intentionally repeat songs.
    func appendOriginalTracks(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let newEntries = songs.map { QueueEntry(id: UUID(), song: $0) }
        self.setQueue(entries: self.queueEntries + newEntries)
        if self.queueOrderBeforeShuffle != nil {
            self.queueOrderBeforeShuffle?.append(contentsOf: newEntries)
        }
        // While loading, defer persistence to `endQueueLoading` to avoid an O(n) re-encode on every
        // continuation batch; persist immediately for any out-of-load append.
        if !self.isQueueLoading {
            self.saveQueueForPersistence()
        }
    }

    /// Finishes progressive loading for `generation` (no-op if it was superseded by a newer
    /// playback): strips any suggestions that slipped in, re-applies the active shuffle to the
    /// now-complete queue (re-shuffle for on/smart keeping the current track; off keeps playlist
    /// order), then generates smart suggestions against the full set. The grown queue is persisted
    /// by the re-shuffle (on/smart) or by an explicit save (off), so there is no extra trailing save.
    func endQueueLoading(_ generation: Int) async {
        guard self.isCurrentQueueLoad(generation), self.isQueueLoading else { return }
        self.isQueueLoading = false
        // Defensive: drop any suggestions generated before the full set loaded so the re-shuffle
        // operates on originals only and the fill regenerates a clean cadence against everything.
        self.stripSuggestedEntries()
        self.resetSmartShuffleState()
        if self.shuffleMode != .off {
            self.materializeShuffleQueueForCurrentTrack(recordUndo: false, storesOriginalOrder: false)
        } else {
            // Off mode neither re-shuffles nor fills, so persist the grown queue explicitly.
            self.saveQueueForPersistence()
        }
        await self.fillSmartShuffleWindow()
    }
}
