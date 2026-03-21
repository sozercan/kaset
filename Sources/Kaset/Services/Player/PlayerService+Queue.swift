import Foundation

// MARK: - Queue Management

@MainActor
extension PlayerService {
    /// Plays a queue of songs starting at the specified index.
    func playQueue(_ songs: [Song], startingAt index: Int = 0) async {
        guard !songs.isEmpty else { return }
        self.recordQueueStateForUndo()
        let safeIndex = max(0, min(index, songs.count - 1))
        self.queue = songs
        self.currentIndex = safeIndex
        // Clear mix continuation since this is not a mix queue
        self.mixContinuationToken = nil
        if let song = songs[safe: safeIndex] {
            await self.play(song: song)
        }
        self.saveQueueForPersistence()
    }

    /// Plays a song and fetches similar songs (radio queue) in the background.
    /// The queue will be populated with similar songs from YouTube Music's radio feature.
    func playWithRadio(song: Song) async {
        self.logger.info("Playing with radio: \(song.title)")
        self.recordQueueStateForUndo()

        // Clear mix continuation since this is a song radio, not a mix
        self.mixContinuationToken = nil

        // Start with just this song in the queue
        self.queue = [song]
        self.currentIndex = 0
        await self.play(song: song)

        // Fetch radio queue in background
        await self.fetchAndApplyRadioQueue(for: song.videoId)
        self.saveQueueForPersistence()
    }

    /// Plays an artist mix from a mix playlist ID.
    /// Fetches a fresh randomized queue from the API each time.
    /// Supports infinite mix - automatically fetches more songs as you approach the end.
    /// - Parameters:
    ///   - playlistId: The mix playlist ID (e.g., "RDEM..." for artist mix)
    ///   - startVideoId: Optional video ID to start with. If nil, API picks a random starting point.
    func playWithMix(playlistId: String, startVideoId: String?) async {
        self.logger.info("Playing mix playlist: \(playlistId), startVideoId: \(startVideoId ?? "nil (random)")")
        self.recordQueueStateForUndo()

        guard let client = self.ytMusicClient else {
            self.logger.warning("No YTMusicClient available for playing mix")
            return
        }

        do {
            // Fetch mix queue from API
            let result = try await client.getMixQueue(playlistId: playlistId, startVideoId: startVideoId)
            guard !result.songs.isEmpty else {
                self.logger.warning("Mix queue returned empty")
                return
            }

            // Store continuation token for infinite mix
            self.mixContinuationToken = result.continuationToken

            // Shuffle the queue to get a different order each time
            // YouTube's API returns a personalized but consistent order per session,
            // so we shuffle to give the user variety on each Mix button click
            let shuffledSongs = result.songs.shuffled()

            // Set up the queue and play the first song
            self.queue = shuffledSongs
            self.currentIndex = 0
            self.currentTrack = shuffledSongs[0]

            // Start playback
            await self.play(videoId: shuffledSongs[0].videoId)

            self.logger.info("Mix queue loaded with \(shuffledSongs.count) songs, hasContinuation: \(result.continuationToken != nil)")
            self.saveQueueForPersistence()
        } catch {
            self.logger.warning("Failed to fetch mix queue: \(error.localizedDescription)")
        }
    }

    /// Fetches more songs for the current mix when approaching the end of the queue.
    /// This enables "infinite mix" behavior like YouTube Music web.
    func fetchMoreMixSongsIfNeeded() async {
        let songsRemaining = self.queue.count - self.currentIndex - 1
        self.logger.debug("Infinite mix check: \(songsRemaining) songs remaining, hasContinuation: \(self.mixContinuationToken != nil)")

        // Only fetch if we have a continuation token and we're near the end
        guard let token = mixContinuationToken,
              !isFetchingMoreMixSongs,
              let client = ytMusicClient
        else {
            return
        }

        // Fetch more when we're within 10 songs of the end
        guard songsRemaining <= 10 else {
            return
        }

        self.logger.info("Fetching more mix songs, \(songsRemaining) remaining in queue")
        self.isFetchingMoreMixSongs = true

        do {
            let result = try await client.getMixQueueContinuation(continuationToken: token)
            self.logger.debug("Continuation returned \(result.songs.count) songs, hasNextToken: \(result.continuationToken != nil)")

            // Filter out songs already in queue to avoid duplicates
            let existingIds = Set(queue.map(\.videoId))
            let newSongs = result.songs.filter { !existingIds.contains($0.videoId) }

            if !newSongs.isEmpty {
                // Create a new array to ensure @Observable triggers UI update
                var updatedQueue = self.queue
                updatedQueue.append(contentsOf: newSongs)
                self.queue = updatedQueue
                self.logger.info("Added \(newSongs.count) new songs to queue, total: \(self.queue.count)")
                self.saveQueueForPersistence()
            }

            // Update continuation token for next batch
            self.mixContinuationToken = result.continuationToken
        } catch {
            self.logger.warning("Failed to fetch more mix songs: \(error.localizedDescription)")
        }

        self.isFetchingMoreMixSongs = false
    }

    /// Fetches radio queue and applies it, keeping the current song at the front.
    func fetchAndApplyRadioQueue(for videoId: String) async {
        guard let client = ytMusicClient else {
            self.logger.warning("No YTMusicClient available for fetching radio queue")
            return
        }

        do {
            let radioSongs = try await client.getRadioQueue(videoId: videoId)
            guard !radioSongs.isEmpty else {
                self.logger.info("No radio songs returned")
                return
            }

            // Only update if we're still playing the same song
            guard let currentSong = self.currentTrack, currentSong.videoId == videoId else {
                self.logger.info("Track changed, discarding radio queue")
                return
            }

            // Ensure the current song is at the front of the queue
            // The radio queue may or may not include the seed song
            var newQueue: [Song] = []

            // Check if the current song is already in the radio queue
            let radioContainsCurrentSong = radioSongs.contains { $0.videoId == videoId }

            if radioContainsCurrentSong {
                // Find the index of current song and reorder queue to start from it
                if let currentSongIndex = radioSongs.firstIndex(where: { $0.videoId == videoId }) {
                    // Put current song first, then the rest
                    newQueue.append(currentSong)
                    for (index, song) in radioSongs.enumerated() where index != currentSongIndex {
                        newQueue.append(song)
                    }
                } else {
                    newQueue = radioSongs
                }
            } else {
                // Current song not in radio queue - prepend it
                newQueue.append(currentSong)
                newQueue.append(contentsOf: radioSongs)
            }

            self.recordQueueStateForUndo()
            self.queue = newQueue
            self.currentIndex = 0
            self.logger.info("Radio queue updated with \(newQueue.count) songs (current song at front)")
            self.saveQueueForPersistence()
        } catch {
            self.logger.warning("Failed to fetch radio queue: \(error.localizedDescription)")
        }
    }

    /// Clears the entire queue and current track (for "Clear" in side panel). Records state for undo.
    func clearQueueEntirely() {
        self.recordQueueStateForUndo()
        self.mixContinuationToken = nil
        self.queue = []
        self.currentIndex = 0
        self.logger.info("Queue cleared entirely")
        self.saveQueueForPersistence()
    }

    /// Clears the playback queue except for the currently playing track.
    func clearQueue() {
        self.recordQueueStateForUndo()
        // Clear mix continuation since queue is being manually cleared
        self.mixContinuationToken = nil

        guard let currentTrack else {
            self.queue = []
            self.currentIndex = 0
            self.saveQueueForPersistence()
            return
        }
        // Keep only the current track
        self.queue = [currentTrack]
        self.currentIndex = 0
        self.logger.info("Queue cleared, keeping current track")
        self.saveQueueForPersistence()
    }

    /// Plays a song from the queue at the specified index.
    func playFromQueue(at index: Int) async {
        guard index >= 0, index < self.queue.count else { return }
        self.currentIndex = index
        if let song = queue[safe: index] {
            await self.play(song: song)
        }
        // Check if we need to fetch more songs for infinite mix
        await self.fetchMoreMixSongsIfNeeded()
        self.saveQueueForPersistence()
    }

    /// Inserts songs immediately after the current track.
    /// - Parameter songs: The songs to insert into the queue.
    func insertNextInQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        self.recordQueueStateForUndo()
        let insertIndex = min(self.currentIndex + 1, self.queue.count)
        self.queue.insert(contentsOf: songs, at: insertIndex)
        self.logger.info("Inserted \(songs.count) songs at position \(insertIndex)")
        self.saveQueueForPersistence()
    }

    /// Removes songs from the queue by video ID.
    /// - Parameter videoIds: Set of video IDs to remove.
    func removeFromQueue(videoIds: Set<String>) {
        self.recordQueueStateForUndo()
        let previousCount = self.queue.count
        self.queue.removeAll { videoIds.contains($0.videoId) }

        // Adjust currentIndex if needed
        if let current = currentTrack,
           let newIndex = queue.firstIndex(where: { $0.videoId == current.videoId })
        {
            self.currentIndex = newIndex
        } else if self.currentIndex >= self.queue.count {
            self.currentIndex = max(0, self.queue.count - 1)
        }

        self.logger.info("Removed \(previousCount - self.queue.count) songs from queue")
        self.saveQueueForPersistence()
    }

    /// Reorders the queue by moving items from source indices to destination offset.
    /// Used for drag-and-drop reordering; does not allow moving the current track.
    /// - Parameters:
    ///   - source: Indices of items to move.
    ///   - destination: Index where items will be placed (after removal from source).
    func reorderQueue(from source: IndexSet, to destination: Int) {
        guard !source.contains(self.currentIndex) else {
            self.logger.warning("Cannot reorder: cannot move current track")
            return
        }
        guard destination != self.currentIndex else {
            self.logger.warning("Cannot reorder: destination is current track")
            return
        }
        self.recordQueueStateForUndo()

        var newQueue = self.queue
        newQueue.move(fromOffsets: source, toOffset: destination)

        // Adjust currentIndex if needed (current track moved in the array)
        if let oldCurrent = self.queue[safe: self.currentIndex],
           let newCurrentIndex = newQueue.firstIndex(where: { $0.videoId == oldCurrent.videoId })
        {
            self.currentIndex = newCurrentIndex
        }

        self.queue = newQueue
        self.logger.info("Queue reordered: moved from \(source) to \(destination)")
        self.saveQueueForPersistence()
    }

    /// Reorders the queue based on a new order of video IDs.
    /// - Parameter videoIds: The new order of video IDs.
    func reorderQueue(videoIds: [String]) {
        self.recordQueueStateForUndo()
        var reordered: [Song] = []
        var videoIdToSong: [String: Song] = [:]

        for song in self.queue {
            videoIdToSong[song.videoId] = song
        }

        for videoId in videoIds {
            if let song = videoIdToSong[videoId] {
                reordered.append(song)
            }
        }

        self.queue = reordered

        // Update currentIndex to match current track's new position
        if let current = currentTrack,
           let newIndex = queue.firstIndex(where: { $0.videoId == current.videoId })
        {
            self.currentIndex = newIndex
        }

        self.logger.info("Queue reordered with \(reordered.count) songs")
        self.saveQueueForPersistence()
    }

    /// Shuffles the queue, keeping the current track in place at the front.
    func shuffleQueue() {
        guard self.queue.count > 1 else { return }
        self.recordQueueStateForUndo()

        // Remove current track, shuffle the rest, put current track at front
        if let currentSong = queue[safe: currentIndex] {
            var shuffled = self.queue
            shuffled.remove(at: self.currentIndex)
            shuffled.shuffle()
            shuffled.insert(currentSong, at: 0)
            self.queue = shuffled
            self.currentIndex = 0
        } else {
            self.queue.shuffle()
            self.currentIndex = 0
        }

        self.logger.info("Queue shuffled")
        self.saveQueueForPersistence()
    }

    /// Adds songs to the end of the queue.
    /// - Parameter songs: The songs to append to the queue.
    func appendToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        self.recordQueueStateForUndo()
        self.queue.append(contentsOf: songs)
        self.logger.info("Appended \(songs.count) songs to queue")
        self.saveQueueForPersistence()
    }

    // MARK: - Queue Persistence

    /// Serialized playback session persisted across launches.
    private struct PersistedPlaybackSession: Codable {
        let queue: [Song]
        let currentIndex: Int
        let currentVideoId: String?
        let progress: TimeInterval
        let duration: TimeInterval
    }

    /// UserDefaults keys for queue persistence (no expiry; saved queue is kept until overwritten or cleared).
    private static let savedQueueKey = "kaset.saved.queue"
    private static let savedQueueIndexKey = "kaset.saved.queueIndex"
    private static let savedPlaybackSessionKey = "kaset.saved.playbackSession"

    /// Saves the current queue to UserDefaults for restoration on next launch.
    func saveQueueForPersistence() {
        guard !self.queue.isEmpty else {
            self.removeSavedPlaybackSession()
            self.logger.info("Cleared saved playback session (queue is empty)")
            return
        }

        do {
            let encoder = JSONEncoder()
            let safeIndex = min(max(self.currentIndex, 0), self.queue.count - 1)
            let currentVideoId = self.currentTrack?.videoId ?? self.queue[safe: safeIndex]?.videoId
            let resolvedDuration = max(self.duration, self.currentTrack?.duration ?? self.queue[safe: safeIndex]?.duration ?? 0)
            let clampedProgress = resolvedDuration > 0
                ? min(max(self.progress, 0), resolvedDuration)
                : max(self.progress, 0)

            let queueData = try encoder.encode(self.queue)
            let sessionData = try encoder.encode(
                PersistedPlaybackSession(
                    queue: self.queue,
                    currentIndex: safeIndex,
                    currentVideoId: currentVideoId,
                    progress: clampedProgress,
                    duration: resolvedDuration
                )
            )

            UserDefaults.standard.set(queueData, forKey: Self.savedQueueKey)
            UserDefaults.standard.set(safeIndex, forKey: Self.savedQueueIndexKey)
            UserDefaults.standard.set(sessionData, forKey: Self.savedPlaybackSessionKey)
            self.logger.info("Saved playback session with \(self.queue.count) songs at index \(safeIndex)")
        } catch {
            self.logger.error("Failed to save playback session: \(error.localizedDescription)")
        }
    }

    /// Restores the queue from UserDefaults if available.
    /// - Returns: True if queue was restored, false otherwise.
    @discardableResult
    func restoreQueueFromPersistence() -> Bool {
        let decoder = JSONDecoder()

        if let sessionData = UserDefaults.standard.data(forKey: Self.savedPlaybackSessionKey) {
            do {
                let savedSession = try decoder.decode(PersistedPlaybackSession.self, from: sessionData)
                guard !savedSession.queue.isEmpty else {
                    self.logger.info("Saved playback session is empty")
                    UserDefaults.standard.removeObject(forKey: Self.savedPlaybackSessionKey)
                    return self.restoreLegacyQueueFromPersistence(using: decoder)
                }

                let resolvedIndex = self.resolvedPersistedQueueIndex(
                    savedIndex: savedSession.currentIndex,
                    currentVideoId: savedSession.currentVideoId,
                    in: savedSession.queue
                )

                self.applyRestoredPlaybackSession(
                    queue: savedSession.queue,
                    currentIndex: resolvedIndex,
                    progress: savedSession.progress,
                    duration: savedSession.duration
                )
                self.logger.info(
                    "Restored playback session with \(savedSession.queue.count) songs at index \(resolvedIndex)"
                )
                return true
            } catch {
                self.logger.error("Failed to restore playback session: \(error.localizedDescription)")
                UserDefaults.standard.removeObject(forKey: Self.savedPlaybackSessionKey)
            }
        }

        return self.restoreLegacyQueueFromPersistence(using: decoder)
    }

    /// Clears the saved queue from UserDefaults.
    func clearSavedQueue() {
        self.removeSavedPlaybackSession()
        self.logger.info("Cleared saved queue")
    }

    /// Restores the legacy queue/index payload when no playback session is available.
    private func restoreLegacyQueueFromPersistence(using decoder: JSONDecoder) -> Bool {
        guard let queueData = UserDefaults.standard.data(forKey: Self.savedQueueKey),
              let savedIndex = UserDefaults.standard.object(forKey: Self.savedQueueIndexKey) as? Int
        else {
            self.logger.info("No saved queue found")
            return false
        }

        do {
            let savedQueue = try decoder.decode([Song].self, from: queueData)
            guard !savedQueue.isEmpty else {
                self.logger.info("Saved queue is empty")
                self.clearSavedQueue()
                return false
            }

            let resolvedIndex = self.resolvedPersistedQueueIndex(
                savedIndex: savedIndex,
                currentVideoId: nil,
                in: savedQueue
            )
            let restoredDuration = savedQueue[safe: resolvedIndex]?.duration ?? 0

            self.applyRestoredPlaybackSession(
                queue: savedQueue,
                currentIndex: resolvedIndex,
                progress: 0,
                duration: restoredDuration
            )
            self.logger.info("Restored legacy queue with \(savedQueue.count) songs at index \(resolvedIndex)")
            return true
        } catch {
            self.logger.error("Failed to restore legacy queue: \(error.localizedDescription)")
            self.clearSavedQueue()
            return false
        }
    }

    /// Removes all persisted queue/session payloads.
    private func removeSavedPlaybackSession() {
        UserDefaults.standard.removeObject(forKey: Self.savedQueueKey)
        UserDefaults.standard.removeObject(forKey: Self.savedQueueIndexKey)
        UserDefaults.standard.removeObject(forKey: Self.savedPlaybackSessionKey)
    }

    /// Resolves the queue index from saved metadata, preferring the saved video ID when available.
    private func resolvedPersistedQueueIndex(
        savedIndex: Int,
        currentVideoId: String?,
        in queue: [Song]
    ) -> Int {
        if let currentVideoId,
           let matchingIndex = queue.firstIndex(where: { $0.videoId == currentVideoId })
        {
            return matchingIndex
        }

        return min(max(savedIndex, 0), queue.count - 1)
    }

    // MARK: - Queue Metadata Enrichment

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
                    queue[index] = enrichedSong
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
