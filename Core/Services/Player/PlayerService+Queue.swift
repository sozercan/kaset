import Foundation

// MARK: - Queue Management

@MainActor
extension PlayerService {
    /// Plays a queue of songs starting at the specified index.
    func playQueue(_ songs: [Song], startingAt index: Int = 0) async {
        guard !songs.isEmpty else { return }
        let safeIndex = max(0, min(index, songs.count - 1))
        self.queue = songs
        self.currentIndex = safeIndex
        // Clear mix continuation since this is not a mix queue
        self.mixContinuationToken = nil
        if let song = songs[safe: safeIndex] {
            await self.play(song: song)
        }
    }

    /// Plays a song and fetches similar songs (radio queue) in the background.
    /// The queue will be populated with similar songs from YouTube Music's radio feature.
    func playWithRadio(song: Song) async {
        self.logger.info("Playing with radio: \(song.title)")

        // Clear mix continuation since this is a song radio, not a mix
        self.mixContinuationToken = nil

        // Start with just this song in the queue
        self.queue = [song]
        self.currentIndex = 0
        await self.play(song: song)

        // Fetch radio queue in background
        await self.fetchAndApplyRadioQueue(for: song.videoId)
    }

    /// Plays an artist mix from a mix playlist ID.
    /// Fetches a fresh randomized queue from the API each time.
    /// Supports infinite mix - automatically fetches more songs as you approach the end.
    /// - Parameters:
    ///   - playlistId: The mix playlist ID (e.g., "RDEM..." for artist mix)
    ///   - startVideoId: Optional video ID to start with. If nil, API picks a random starting point.
    func playWithMix(playlistId: String, startVideoId: String?) async {
        self.logger.info("Playing mix playlist: \(playlistId), startVideoId: \(startVideoId ?? "nil (random)")")

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

            self.queue = newQueue
            self.currentIndex = 0
            self.logger.info("Radio queue updated with \(newQueue.count) songs (current song at front)")
        } catch {
            self.logger.warning("Failed to fetch radio queue: \(error.localizedDescription)")
        }
    }

    /// Clears the playback queue except for the currently playing track.
    func clearQueue() {
        // Clear mix continuation since queue is being manually cleared
        self.mixContinuationToken = nil

        guard let currentTrack else {
            self.queue = []
            self.currentIndex = 0
            return
        }
        // Keep only the current track
        self.queue = [currentTrack]
        self.currentIndex = 0
        self.logger.info("Queue cleared, keeping current track")
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
    }

    /// Inserts songs immediately after the current track.
    /// - Parameter songs: The songs to insert into the queue.
    func insertNextInQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        let insertIndex = min(self.currentIndex + 1, self.queue.count)
        self.queue.insert(contentsOf: songs, at: insertIndex)
        self.logger.info("Inserted \(songs.count) songs at position \(insertIndex)")
    }

    /// Removes songs from the queue by video ID.
    /// - Parameter videoIds: Set of video IDs to remove.
    func removeFromQueue(videoIds: Set<String>) {
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
    }

    /// Reorders the queue based on a new order of video IDs.
    /// - Parameter videoIds: The new order of video IDs.
    func reorderQueue(videoIds: [String]) {
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
    }

    /// Shuffles the queue, keeping the current track in place at the front.
    func shuffleQueue() {
        guard self.queue.count > 1 else { return }

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
    }

    /// Adds songs to the end of the queue.
    /// - Parameter songs: The songs to append to the queue.
    func appendToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        self.queue.append(contentsOf: songs)
        self.logger.info("Appended \(songs.count) songs to queue")
    }
}
