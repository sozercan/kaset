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
    /// - Returns: Stable queue-entry IDs and video IDs for songs needing enrichment.
    func identifySongsNeedingEnrichment() -> [(entryID: UUID, videoId: String)] {
        var songsNeedingEnrichment: [(entryID: UUID, videoId: String)] = []

        for entry in self.queueEntries {
            let song = entry.song
            if Self.songNeedsQueueEnrichment(song) {
                songsNeedingEnrichment.append((entryID: entry.id, videoId: song.videoId))
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
        for (entryID, videoId) in songsToEnrich {
            guard self.queueEntries.contains(where: { $0.id == entryID && $0.song.videoId == videoId }) else {
                continue
            }

            do {
                let enrichedSong = try await client.getSong(videoId: videoId)

                if let index = self.queueEntries.firstIndex(where: {
                    $0.id == entryID && $0.song.videoId == videoId
                }), Self.songNeedsQueueEnrichment(self.queueEntries[index].song) {
                    var updatedEntries = self.queueEntries
                    let mergedSong = Self.mergingQueueMetadata(
                        current: updatedEntries[index].song,
                        response: enrichedSong,
                        includesAccountMetadata: false
                    )
                    // Preserve `source` so a Smart Shuffle `.suggested` entry is not demoted to `.queued`.
                    updatedEntries[index] = QueueEntry(
                        id: updatedEntries[index].id,
                        song: mergedSong,
                        source: updatedEntries[index].source
                    )
                    self.setQueue(entries: updatedEntries)
                    self.logger.debug("Enriched song \(index): '\(mergedSong.title)' - artists: \(mergedSong.artistsDisplay)")
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

    static func songNeedsQueueEnrichment(_ song: Song) -> Bool {
        song.artists.isEmpty
            || song.artists.allSatisfy { $0.name.isEmpty || $0.name == "Unknown Artist" }
            || song.title.isEmpty
            || song.title == "Loading..."
            || song.thumbnailURL == nil
    }

    static func mergingQueueMetadata(
        current: Song,
        response: Song,
        includesAccountMetadata: Bool = true
    ) -> Song {
        let keepsCurrentArtists = !current.artists.isEmpty
            && !current.artists.allSatisfy { $0.name.isEmpty || $0.name == "Unknown Artist" }
        let keepsCurrentTitle = !current.title.isEmpty && current.title != "Loading..."
        return Song(
            id: current.id,
            title: keepsCurrentTitle ? current.title : response.title,
            artists: keepsCurrentArtists ? current.artists : response.artists,
            album: current.album ?? response.album,
            duration: current.duration ?? response.duration,
            thumbnailURL: current.thumbnailURL ?? response.thumbnailURL,
            videoId: current.videoId,
            // `getSong` uses the `next` parser, which defaults playability to true.
            // Preserve the browse renderer's authoritative grey-out state during
            // background enrichment alongside the account-scoped fields below.
            isPlayable: includesAccountMetadata ? response.isPlayable : current.isPlayable,
            hasVideo: current.hasVideo ?? response.hasVideo,
            musicVideoType: current.musicVideoType ?? response.musicVideoType,
            likeStatus: includesAccountMetadata ? (current.likeStatus ?? response.likeStatus) : current.likeStatus,
            isInLibrary: includesAccountMetadata ? (current.isInLibrary ?? response.isInLibrary) : current.isInLibrary,
            feedbackTokens: includesAccountMetadata
                ? (current.feedbackTokens ?? response.feedbackTokens)
                : current.feedbackTokens,
            isExplicit: current.isExplicit ?? response.isExplicit
        )
    }
}
