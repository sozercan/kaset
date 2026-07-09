import Foundation

// MARK: - Queue Metadata Enrichment

@MainActor
extension PlayerService {
    /// Starts queue metadata enrichment if the current queue needs it.
    ///
    /// This is intentionally one-shot/event-driven: no app-lifetime polling loop is kept alive.
    func startQueueEnrichmentService() {
        self.scheduleQueueEnrichmentIfNeeded()
    }

    /// Stops any scheduled/running one-shot enrichment pass.
    func stopQueueEnrichmentService() {
        self.queueEnrichmentNeedsReschedule = false
        self.queueEnrichmentGeneration += 1
        self.queueEnrichmentRunningGeneration = nil
        self.isQueueEnrichmentRunning = false
        self.enrichmentTask?.cancel()
        self.enrichmentTask = nil
    }

    /// Reacts to external queue mutations by re-arming bounded retries and scheduling enrichment only when needed.
    func queueDidChangeForEnrichment() {
        guard !self.isApplyingQueueEnrichmentResult else { return }

        self.resetQueueEnrichmentAttemptState()
        self.scheduleQueueEnrichmentIfNeeded()
    }

    /// Re-arms bounded retry state after an external queue/client event.
    func resetQueueEnrichmentAttemptState() {
        self.queueEnrichmentAttemptsByEntryID.removeAll()
        // Queue replacements and client/account switches invalidate both sleeping
        // retries and active fetches. The cancelled pass checks cancellation before
        // applying its response, while the generation bump prevents it from clearing
        // a replacement task scheduled by the external event.
        self.stopQueueEnrichmentService()
    }

    /// Schedules a single delayed enrichment pass when the queue has incomplete metadata.
    func scheduleQueueEnrichmentIfNeeded(delay requestedDelay: Duration? = nil) {
        self.pruneQueueEnrichmentAttemptState()

        guard self.ytMusicClient != nil else {
            self.stopQueueEnrichmentService()
            return
        }

        let songsNeedingEnrichment = self.identifySongsNeedingEnrichment()
        guard !songsNeedingEnrichment.isEmpty else {
            self.queueEnrichmentAttemptsByEntryID.removeAll()
            self.stopQueueEnrichmentService()
            return
        }

        guard !self.identifyEnrichableSongsNeedingEnrichment().isEmpty else {
            self.stopQueueEnrichmentService()
            return
        }

        if self.isQueueEnrichmentRunning {
            self.queueEnrichmentNeedsReschedule = true
            return
        }

        guard self.enrichmentTask == nil else { return }

        self.queueEnrichmentGeneration += 1
        let generation = self.queueEnrichmentGeneration
        let delay = requestedDelay ?? self.queueEnrichmentInitialDelay

        self.enrichmentTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                await self?.finishScheduledQueueEnrichment(generation: generation)
                return
            }

            guard !Task.isCancelled else {
                await self?.finishScheduledQueueEnrichment(generation: generation)
                return
            }

            await self?.runScheduledQueueEnrichment(generation: generation)
        }
    }

    /// Runs the scheduled enrichment pass and clears/reschedules state as appropriate.
    func runScheduledQueueEnrichment(generation: Int) async {
        guard generation == self.queueEnrichmentGeneration else { return }
        let songsToEnrich = self.identifyEnrichableSongsNeedingEnrichment()
        guard self.ytMusicClient != nil, !songsToEnrich.isEmpty else {
            await self.finishScheduledQueueEnrichment(generation: generation)
            return
        }

        self.isQueueEnrichmentRunning = true
        self.queueEnrichmentRunningGeneration = generation
        self.queueEnrichmentNeedsReschedule = false
        await self.enrichQueueMetadata(songsToEnrich: songsToEnrich)
        if self.queueEnrichmentRunningGeneration == generation {
            self.queueEnrichmentRunningGeneration = nil
            self.isQueueEnrichmentRunning = false
        }

        guard generation == self.queueEnrichmentGeneration, !Task.isCancelled else { return }

        let shouldRescheduleForMutation = self.queueEnrichmentNeedsReschedule
        let shouldRetryIncompleteEntries = !self.identifyEnrichableSongsNeedingEnrichment().isEmpty
        await self.finishScheduledQueueEnrichment(generation: generation)

        if shouldRescheduleForMutation {
            self.scheduleQueueEnrichmentIfNeeded()
        } else if shouldRetryIncompleteEntries {
            self.scheduleQueueEnrichmentIfNeeded(delay: self.queueEnrichmentRetryDelay)
        }
    }

    /// Clears a scheduled task if it still owns the current enrichment generation.
    func finishScheduledQueueEnrichment(generation: Int) async {
        guard generation == self.queueEnrichmentGeneration else { return }

        self.enrichmentTask = nil
    }

    /// Identifies incomplete queue entries that have not exhausted their bounded retry budget.
    func identifyEnrichableSongsNeedingEnrichment() -> [(index: Int, videoId: String)] {
        self.identifySongsNeedingEnrichment().filter { item in
            guard let entryID = self.queueEntries[safe: item.index]?.id else { return false }

            return self.queueEnrichmentAttemptsByEntryID[entryID, default: 0] < Self.maxQueueEnrichmentAttempts
        }
    }

    /// Drops retry state for entries that are no longer in the queue.
    func pruneQueueEnrichmentAttemptState() {
        let activeEntryIDs = Set(self.queueEntryIDs)
        self.queueEnrichmentAttemptsByEntryID = self.queueEnrichmentAttemptsByEntryID.filter { entryID, _ in
            activeEntryIDs.contains(entryID)
        }
    }

    /// Returns whether a song has placeholder or missing metadata that the API can improve.
    func songNeedsQueueMetadataEnrichment(_ song: Song) -> Bool {
        song.artists.isEmpty ||
            song.artists.allSatisfy { $0.name.isEmpty || $0.name == "Unknown Artist" } ||
            song.title.isEmpty ||
            song.title == "Loading..." ||
            song.thumbnailURL == nil
    }

    /// Identifies songs in the queue that need metadata enrichment.
    /// - Returns: Array of tuples containing index and videoId for songs needing enrichment.
    func identifySongsNeedingEnrichment() -> [(index: Int, videoId: String)] {
        var songsNeedingEnrichment: [(index: Int, videoId: String)] = []

        // Check if song needs enrichment:
        // 1. No artists or all artists are empty/unknown
        // 2. Title is placeholder ("Loading..." or empty)
        // 3. No thumbnail
        for (index, song) in queue.enumerated() where self.songNeedsQueueMetadataEnrichment(song) {
            songsNeedingEnrichment.append((index: index, videoId: song.videoId))
        }

        return songsNeedingEnrichment
    }

    /// Enriches queue metadata by fetching full song details for incomplete entries.
    /// This updates the queue in-place and persists the enriched data.
    func enrichQueueMetadata(songsToEnrich requestedSongsToEnrich: [(index: Int, videoId: String)]? = nil) async {
        guard let client = self.ytMusicClient else { return }

        let songsToEnrich = requestedSongsToEnrich ?? self.identifySongsNeedingEnrichment()

        guard !songsToEnrich.isEmpty else { return }

        self.logger.info("Enriching metadata for \(songsToEnrich.count) songs in queue")

        var didUpdateQueue = false

        // Process one song at a time to be gentle on the API.
        for (index, videoId) in songsToEnrich {
            guard !Task.isCancelled else { break }

            // Check if still needed (song might have been removed)
            guard index < queue.count, queue[index].videoId == videoId else { continue }
            let entryID = self.queueEntries[safe: index]?.id
            if let entryID {
                self.queueEnrichmentAttemptsByEntryID[entryID, default: 0] += 1
            }

            do {
                let enrichedSong = try await client.getSong(videoId: videoId)

                guard !Task.isCancelled else { break }

                // Update the queue in-place
                if index < queue.count, queue[index].videoId == videoId {
                    var updatedEntries = self.queueEntries
                    // Preserve `source` so a Smart Shuffle `.suggested` entry is not demoted to `.queued`.
                    updatedEntries[index] = QueueEntry(
                        id: updatedEntries[index].id,
                        song: enrichedSong,
                        source: updatedEntries[index].source
                    )
                    self.isApplyingQueueEnrichmentResult = true
                    self.setQueue(entries: updatedEntries)
                    self.isApplyingQueueEnrichmentResult = false
                    didUpdateQueue = true
                    if let entryID, !self.songNeedsQueueMetadataEnrichment(enrichedSong) {
                        self.queueEnrichmentAttemptsByEntryID.removeValue(forKey: entryID)
                    }
                    self.logger.debug("Enriched song \(index): '\(enrichedSong.title)' - artists: \(enrichedSong.artistsDisplay)")
                }

                // Small delay between requests to be API-friendly
                if songsToEnrich.count > 1 {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                self.logger.warning("Failed to enrich metadata for song \(videoId): \(error.localizedDescription)")
            }
        }

        // Save the enriched queue to persistence
        if didUpdateQueue {
            self.saveQueueForPersistence()
            self.logger.info("Queue metadata enrichment complete, saved to persistence")
        } else {
            self.logger.info("Queue metadata enrichment complete, no queue updates to persist")
        }
    }
}
