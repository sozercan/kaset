import Foundation

// MARK: - Queue Metadata Enrichment

@MainActor
extension PlayerService {
    /// Starts the background metadata enrichment service.
    /// This periodically checks the queue for songs with incomplete metadata and fetches full details.
    func startQueueEnrichmentService() {
        // Cancel any existing task
        enrichmentTask?.cancel()

        enrichmentTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                // Wait 30 seconds between checks
                try? await Task.sleep(for: .seconds(30))

                guard !Task.isCancelled else { break }

                // Perform enrichment
                await self.enrichQueueMetadata()
            }
        }
    }

    /// Stops the background enrichment service.
    func stopQueueEnrichmentService() {
        enrichmentTask?.cancel()
        enrichmentTask = nil
    }

    /// Identifies songs in the queue that need metadata enrichment.
    /// - Returns: Array of tuples containing index and videoId for songs needing enrichment.
    func identifySongsNeedingEnrichment() -> [(index: Int, videoId: String)] {
        var songsNeedingEnrichment: [(index: Int, videoId: String)] = []

        for (index, song) in queue.enumerated() {
            // Check if song needs enrichment:
            // 1. No artists or all artists are empty/unknown
            // 2. Title is placeholder ("Loading..." or empty)
            // 3. No thumbnail
            let needsEnrichment = song.artists.isEmpty ||
                song.artists.allSatisfy { $0.name.isEmpty || $0.name == "Unknown Artist" } ||
                song.title.isEmpty ||
                song.title == "Loading..." ||
                song.thumbnailURL == nil

            if needsEnrichment {
                songsNeedingEnrichment.append((index: index, videoId: song.videoId))
            }
        }

        return songsNeedingEnrichment
    }

    /// Enriches queue metadata by fetching full song details for incomplete entries.
    /// This updates the queue in-place and persists the enriched data.
    func enrichQueueMetadata() async {
        guard let client = self.ytMusicClient else { return }

        let songsToEnrich = self.identifySongsNeedingEnrichment()

        guard !songsToEnrich.isEmpty else { return }

        self.logger.info("Enriching metadata for \(songsToEnrich.count) songs in queue")

        // Process in small batches to avoid overwhelming the API
        // Process one song at a time to be gentle on the API
        for (index, videoId) in songsToEnrich {
            // Check if still needed (song might have been removed)
            guard index < queue.count, queue[index].videoId == videoId else { continue }

            do {
                let enrichedSong = try await client.getSong(videoId: videoId)

                // Update the queue in-place
                if index < queue.count, queue[index].videoId == videoId {
                    var updatedEntries = self.queueEntries
                    // Preserve `source` so a Smart Shuffle `.suggested` entry is not demoted to `.queued`.
                    updatedEntries[index] = QueueEntry(
                        id: updatedEntries[index].id,
                        song: enrichedSong,
                        source: updatedEntries[index].source
                    )
                    self.setQueue(entries: updatedEntries)
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
        self.saveQueueForPersistence()
        self.logger.info("Queue metadata enrichment complete, saved to persistence")
    }
}
