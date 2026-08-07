// swiftlint:disable file_length
import Foundation

// MARK: - Queue Management

@MainActor
extension PlayerService {
    /// Plays a queue of songs starting at the specified index.
    func playQueue(_ songs: [Song], startingAt index: Int = 0) async {
        guard !songs.isEmpty else { return }
        await self.playQueue(songs, startingAt: index, deferringSmartShuffleFill: false)
    }

    /// Plays a queue of songs starting at the specified index.
    ///
    /// - Parameter deferringSmartShuffleFill: When true, the trailing Smart Shuffle fill is skipped
    ///   and a deferred-load generation is returned so the caller can grow the queue to the full playlist
    ///   before suggestions are generated (via ``appendOriginalTracks(_:)`` + ``endQueueLoading(_:)``).
    /// - Returns: The deferred-load generation when deferring, otherwise nil.
    @discardableResult
    func playQueue(_ songs: [Song], startingAt index: Int = 0, deferringSmartShuffleFill: Bool) async -> Int? {
        guard !songs.isEmpty else { return nil }
        let intent = self.beginMusicPlaybackIntent()
        return await self.playQueue(
            songs,
            startingAt: index,
            deferringSmartShuffleFill: deferringSmartShuffleFill,
            intent: intent
        )
    }

    @discardableResult
    func playQueue(
        _ songs: [Song],
        startingAt index: Int,
        deferringSmartShuffleFill: Bool,
        intent: MusicPlaybackIntent
    ) async -> Int? {
        guard self.acceptsMusicPlaybackIntent(intent), !songs.isEmpty else { return nil }
        self.invalidateMixContinuationRequest()
        self.resetSmartShuffleForNewQueue()
        let loadGeneration: Int?
        if deferringSmartShuffleFill {
            loadGeneration = self.beginQueueLoading()
        } else {
            self.invalidateStaleQueueLoad()
            loadGeneration = nil
        }
        let queueGeneration = loadGeneration ?? self.queueLoadGeneration
        self.clearForwardSkipNavigationStack()
        self.recordQueueStateForUndo()
        let safeIndex = max(0, min(index, songs.count - 1))
        let entries = songs.map { QueueEntry(id: UUID(), song: $0) }
        if self.shuffleEnabled, entries.count > 1 {
            self.materializeShuffleQueue(
                entries: entries,
                startingAt: safeIndex,
                recordUndo: false,
                storesOriginalOrder: true
            )
            self.currentIndex = 0
        } else {
            self.queueOrderBeforeShuffle = nil
            self.setQueue(entries: entries)
            self.currentIndex = safeIndex
        }
        self.mixContinuationToken = nil
        if let entry = self.queueEntries[safe: self.currentIndex] {
            await self.play(
                song: entry.song,
                webLoadStrategy: .standard,
                queueEntryID: entry.id,
                intent: intent
            )
        }
        guard self.isCurrentQueueLoad(queueGeneration) else { return loadGeneration }
        self.saveQueueForPersistence()
        if self.shuffleMode == .smart, loadGeneration == nil {
            await self.fillSmartShuffleWindow()
            guard self.isCurrentQueueLoad(queueGeneration) else { return nil }
        }
        return loadGeneration
    }

    /// Plays a song and fetches similar songs (radio queue) in the background.
    /// The queue will be populated with similar songs from YouTube Music's radio feature.
    func playWithRadio(song: Song) async {
        let intent = self.beginMusicPlaybackIntent()
        await self.playWithRadio(song: song, intent: intent)
    }

    func playWithRadio(song: Song, intent: MusicPlaybackIntent) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        self.logger.info("Playing with radio: \(song.title)")
        self.clearForwardSkipNavigationStack()
        self.recordQueueStateForUndo()
        self.prepareForNewPlaybackContext()
        self.invalidateMixContinuationRequest()
        self.mixContinuationToken = nil
        let queueGeneration = self.queueLoadGeneration

        let seedEntry = QueueEntry(id: UUID(), song: song)
        self.setQueue(entries: [seedEntry])
        self.queueOrderBeforeShuffle = nil
        self.currentIndex = 0
        await self.play(
            song: song,
            webLoadStrategy: .standard,
            queueEntryID: seedEntry.id,
            intent: intent
        )
        guard self.isCurrentQueueLoad(queueGeneration),
              self.activePlaybackQueueEntryID == seedEntry.id
        else { return }

        await self.fetchAndApplyRadioQueue(
            for: song.videoId,
            seedEntryID: seedEntry.id,
            queueGeneration: queueGeneration
        )
        guard self.isCurrentQueueLoad(queueGeneration) else { return }
        self.saveQueueForPersistence()
    }

    /// Plays an artist mix from a mix playlist ID.
    /// Fetches a fresh randomized queue from the API each time.
    /// Supports infinite mix - automatically fetches more songs as you approach the end.
    /// - Parameters:
    ///   - playlistId: The mix playlist ID (e.g., "RDEM..." for artist mix)
    ///   - startVideoId: Optional video ID to start with. If nil, API picks a random starting point.
    func playWithMix(
        playlistId: String,
        startVideoId: String?,
        intent suppliedIntent: MusicPlaybackIntent? = nil
    ) async {
        let intent = suppliedIntent ?? self.beginMusicPlaybackIntent()
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        self.logger.info("Playing mix playlist: \(playlistId), startVideoId: \(startVideoId ?? "nil (random)")")
        let continuationRequiresAuth = self.authService?.hasPersonalAccount == true
        self.clearForwardSkipNavigationStack()

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

            guard self.acceptsMusicPlaybackIntent(intent) else {
                self.logger.info("Discarding stale mix playback request after playback boundary")
                return
            }

            let priorQueueState = self.makeQueueStateSnapshot()

            // Store continuation token for infinite mix
            self.mixContinuationToken = result.continuationToken
            self.mixContinuationRequiresAuth = continuationRequiresAuth

            // Shuffle the queue to get a different order each time
            // YouTube's API returns a personalized but consistent order per session,
            // so we shuffle to give the user variety on each Mix button click
            let shuffledSongs = result.songs.shuffled()
            let shuffledEntries = shuffledSongs.map { QueueEntry(id: UUID(), song: $0) }
            self.recordQueueStateForUndo(priorQueueState)

            // The mix is confirmed non-empty: now supersede any in-flight deferred load and reset
            // smart-shuffle (done here, not before the await, so a failed/empty mix that returns
            // without replacing the queue does not prematurely stand down an active playlist load).
            self.prepareForNewPlaybackContext()
            let queueGeneration = self.queueLoadGeneration

            // Set up the queue and play the first song
            self.setQueue(entries: shuffledEntries)
            self.queueOrderBeforeShuffle = nil
            self.currentIndex = 0

            if let firstEntry = self.queueEntries.first {
                await self.play(
                    song: firstEntry.song,
                    webLoadStrategy: .standard,
                    queueEntryID: firstEntry.id,
                    intent: intent
                )
            }
            guard self.isCurrentQueueLoad(queueGeneration) else { return }
            self.logger.info(
                "Mix queue loaded with \(shuffledEntries.count) songs, hasContinuation: \(result.continuationToken != nil)"
            )
            self.saveQueueForPersistence()
        } catch {
            guard self.acceptsMusicPlaybackIntent(intent) else { return }
            self.logger.warning("Failed to fetch mix queue: \(error.localizedDescription)")
        }
    }

    /// Fetches more songs for the current mix when approaching the end of the queue.
    /// This enables "infinite mix" behavior like YouTube Music web.
    func fetchMoreMixSongsIfNeeded(
        queueGeneration suppliedQueueGeneration: Int? = nil
    ) async {
        if self.isFetchingMoreMixSongs {
            await self.waitForActiveMixContinuationRequest()
            return
        }

        let songsRemaining = self.queue.count - self.currentIndex - 1
        self.logger.debug("Infinite mix check: \(songsRemaining) songs remaining, hasContinuation: \(self.mixContinuationToken != nil)")

        // Only fetch if we have a continuation token and we're near the end
        guard let token = mixContinuationToken,
              !isFetchingMoreMixSongs,
              !(self.mixContinuationRequiresAuth && self.authService?.hasPersonalAccount != true),
              let client = ytMusicClient
        else {
            return
        }

        // Fetch more when we're within 10 songs of the end
        guard songsRemaining <= 10 else {
            return
        }

        let queueGeneration = suppliedQueueGeneration ?? self.queueLoadGeneration
        guard self.isCurrentQueueLoad(queueGeneration) else { return }
        self.logger.info("Fetching more mix songs, \(songsRemaining) remaining in queue")
        self.isFetchingMoreMixSongs = true
        let requestID = UUID()
        self.activeMixContinuationRequestID = requestID
        defer {
            self.finishMixContinuationRequest(requestID)
        }

        do {
            let result = try await client.getMixQueueContinuation(continuationToken: token)
            guard self.isCurrentQueueLoad(queueGeneration) else {
                self.logger.info("Discarding stale mix continuation after queue replacement")
                return
            }
            guard self.activeMixContinuationRequestID == requestID else { return }
            self.logger.debug("Continuation returned \(result.songs.count) songs, hasNextToken: \(result.continuationToken != nil)")

            // Filter out songs already in queue to avoid duplicates
            let existingIds = Set(queue.map(\.videoId))
            let newSongs = result.songs.filter { !existingIds.contains($0.videoId) }

            if !newSongs.isEmpty {
                let updatedEntries = self.queueEntries + newSongs.map { QueueEntry(id: UUID(), song: $0) }
                self.setQueue(entries: updatedEntries)
                self.logger.info("Added \(newSongs.count) new songs to queue, total: \(self.queue.count)")
                self.saveQueueForPersistence()
            }

            // Update continuation token for next batch
            self.mixContinuationToken = result.continuationToken
        } catch {
            self.logger.warning("Failed to fetch more mix songs: \(error.localizedDescription)")
        }
    }

    /// Fetches radio queue and applies it to the queue context that owns the seed.
    func fetchAndApplyRadioQueue(for videoId: String) async {
        await self.fetchAndApplyRadioQueue(
            for: videoId,
            seedEntryID: self.activePlaybackQueueEntryID,
            queueGeneration: self.queueLoadGeneration
        )
    }

    func fetchAndApplyRadioQueue(
        for videoId: String,
        seedEntryID: UUID?,
        queueGeneration: Int
    ) async {
        guard self.isCurrentQueueLoad(queueGeneration),
              let client = self.ytMusicClient
        else { return }

        do {
            let radioSongs = try await client.getRadioQueue(videoId: videoId)
            guard self.isCurrentQueueLoad(queueGeneration) else {
                self.logger.info("Discarding stale radio queue after queue replacement")
                return
            }
            guard !radioSongs.isEmpty else {
                self.logger.info("No radio songs returned")
                return
            }
            guard let seedEntryID,
                  let seedEntry = self.queueEntries.first(where: { $0.id == seedEntryID }),
                  seedEntry.song.videoId == videoId,
                  self.currentTrack?.videoId == videoId,
                  self.activePlaybackQueueEntryID == seedEntryID
            else {
                self.logger.info("Logical seed changed, discarding radio queue")
                return
            }

            let existingVideoIDs = Set(self.queue.map(\.videoId))
            let relatedEntries = radioSongs.compactMap { song -> QueueEntry? in
                guard song.videoId != videoId,
                      !existingVideoIDs.contains(song.videoId)
                else { return nil }
                return QueueEntry(id: UUID(), song: song)
            }
            guard !relatedEntries.isEmpty else { return }

            self.clearForwardSkipNavigationStack()
            self.recordQueueStateForUndo()
            if self.shuffleEnabled {
                let liveEntryIDs = Set(self.queueEntries.map(\.id))
                var originalEntries = (self.queueOrderBeforeShuffle ?? []).filter {
                    liveEntryIDs.contains($0.id)
                }
                let originalIDs = Set(originalEntries.map(\.id))
                originalEntries.append(contentsOf: self.queueEntries.filter {
                    !originalIDs.contains($0.id)
                })
                originalEntries.append(contentsOf: relatedEntries)
                let seedOriginalIndex = originalEntries.firstIndex(where: { $0.id == seedEntryID }) ?? 0
                self.materializeShuffleQueue(
                    entries: originalEntries,
                    startingAt: seedOriginalIndex,
                    recordUndo: false,
                    storesOriginalOrder: true
                )
            } else {
                self.setQueue(entries: self.queueEntries + relatedEntries)
                self.queueOrderBeforeShuffle = nil
            }
            if let seedIndex = self.queueEntries.firstIndex(where: { $0.id == seedEntryID }) {
                self.currentIndex = seedIndex
            }
            self.activePlaybackQueueEntryID = seedEntryID
            self.logger.info("Radio queue merged with \(relatedEntries.count) related songs")
            self.saveQueueForPersistence()
        } catch {
            guard self.isCurrentQueueLoad(queueGeneration) else { return }
            self.logger.warning("Failed to fetch radio queue: \(error.localizedDescription)")
        }
    }

    /// Stops playback and clears the entire queue. Records state for undo.
    func clearQueueEntirely() async {
        await self.stopAndClearQueue()
    }

    func clearQueueEntriesAfterStop(
        intent: MusicPlaybackIntent,
        undoState: QueueState? = nil
    ) {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        self.cancelDeferredQueueWork()
        self.clearForwardSkipNavigationStack()
        self.recordQueueStateForUndo(undoState ?? self.makeQueueStateSnapshot())
        self.mixContinuationToken = nil
        self.prepareForNewPlaybackContext()
        self.setQueue([])
        self.queueOrderBeforeShuffle = nil
        self.currentIndex = 0
        self.logger.info("Queue cleared entirely")
        self.clearSavedQueue()
    }

    /// Clears the playback queue except for the currently playing track.
    func clearQueue() {
        self.beginMusicPlaybackIntent(allowsPriorTerminalEvent: true)
        self.cancelDeferredQueueWork()
        self.clearForwardSkipNavigationStack()
        self.recordQueueStateForUndo()
        // Clear mix continuation since queue is being manually cleared
        self.mixContinuationToken = nil
        self.prepareForNewPlaybackContext()

        guard let currentTrack else {
            self.setQueue([])
            self.queueOrderBeforeShuffle = nil
            self.currentIndex = 0
            self.saveQueueForPersistence()
            return
        }
        // Keep only the current track
        let currentEntryID = self.queueEntryIDOwningCurrentPlayback
        self.setQueue([currentTrack], entryIDs: currentEntryID.map { [$0] })
        self.queueOrderBeforeShuffle = nil
        self.currentIndex = 0
        self.logger.info("Queue cleared, keeping current track")
        self.saveQueueForPersistence()
    }

    /// Plays a song from the queue at the specified index.
    func playFromQueue(at index: Int) async {
        guard self.queueEntries.indices.contains(index) else { return }
        let intent = self.beginMusicPlaybackIntent()
        await self.playFromQueue(at: index, intent: intent)
    }

    func playFromQueue(at index: Int, intent: MusicPlaybackIntent) async {
        guard self.acceptsMusicPlaybackIntent(intent) else { return }
        guard index >= 0, index < self.queueEntries.count else { return }
        let queueGeneration = self.queueLoadGeneration
        self.clearForwardSkipNavigationStack()
        self.currentIndex = index
        if let entry = self.queueEntries[safe: index] {
            await self.play(
                song: entry.song,
                webLoadStrategy: .standard,
                queueEntryID: entry.id,
                intent: intent
            )
        }
        guard self.isCurrentQueueLoad(queueGeneration) else { return }
        await self.fetchMoreMixSongsIfNeeded(queueGeneration: queueGeneration)
        guard self.isCurrentQueueLoad(queueGeneration) else { return }
        await self.fillSmartShuffleWindow()
        guard self.isCurrentQueueLoad(queueGeneration) else { return }
        self.saveQueueForPersistence()
    }

    func playFromQueue(entryID: UUID) async {
        guard self.queueEntries.contains(where: { $0.id == entryID }) else { return }
        let intent = self.beginMusicPlaybackIntent()
        await self.playFromQueue(entryID: entryID, intent: intent)
    }

    func playFromQueue(entryID: UUID, intent: MusicPlaybackIntent) async {
        guard self.acceptsMusicPlaybackIntent(intent),
              let index = self.queueEntries.firstIndex(where: { $0.id == entryID })
        else { return }
        await self.playFromQueue(at: index, intent: intent)
    }

    /// Inserts songs immediately after the current track.
    /// - Parameter songs: The songs to insert into the queue.
    func insertNextInQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        self.clearForwardSkipNavigationStack()
        self.recordQueueStateForUndo()
        let insertIndex = min(self.currentIndex + 1, self.queue.count)
        var updatedEntries = self.queueEntries
        updatedEntries.insert(contentsOf: songs.map { QueueEntry(id: UUID(), song: $0) }, at: insertIndex)
        self.setQueue(entries: updatedEntries)
        self.logger.info("Inserted \(songs.count) songs at position \(insertIndex)")
        self.saveQueueForPersistence()
    }

    /// Whether the queue contains the same song more than once.
    var queueHasDuplicateEntries: Bool {
        var seenVideoIds = Set<String>()
        for song in self.queue where !seenVideoIds.insert(song.videoId).inserted {
            return true
        }
        return false
    }

    /// Removes the queue entry at the given index, leaving other occurrences of the same song intact.
    /// - Parameter index: The queue index to remove.
    func removeFromQueue(at index: Int) {
        guard self.queueEntries.indices.contains(index) else { return }
        self.clearForwardSkipNavigationStack()
        self.recordQueueStateForUndo()
        let previousCount = self.queue.count
        let currentEntryID = self.currentQueueEntryID
        let originalCurrentIndex = self.currentIndex
        var remainingEntries = self.queueEntries
        remainingEntries.remove(at: index)
        self.setQueue(entries: remainingEntries)
        self.realignCurrentIndexAfterQueueMutation(
            currentEntryID: currentEntryID,
            originalCurrentIndex: originalCurrentIndex,
            removedIndex: index
        )

        self.logger.info("Removed queue entry at index \(index); queue size \(previousCount) -> \(self.queue.count)")
        self.saveQueueForPersistence()
    }

    /// Removes songs from the queue by stable entry IDs.
    /// - Parameter entryIDs: Set of queue entry IDs to remove.
    func removeFromQueue(entryIDs: Set<UUID>) {
        guard !entryIDs.isEmpty else { return }

        let priorEntries = self.queueEntries
        var remainingEntries: [QueueEntry] = []
        remainingEntries.reserveCapacity(priorEntries.count)
        var removedIndices: [Int] = []

        for (index, entry) in priorEntries.enumerated() {
            if entryIDs.contains(entry.id) {
                removedIndices.append(index)
            } else {
                remainingEntries.append(entry)
            }
        }

        guard !removedIndices.isEmpty else { return }

        self.clearForwardSkipNavigationStack()
        self.recordQueueStateForUndo()
        let previousCount = priorEntries.count
        let currentEntryID = self.currentQueueEntryID
        let originalCurrentIndex = self.currentIndex
        self.setQueue(entries: remainingEntries)
        self.realignCurrentIndexAfterQueueMutation(
            currentEntryID: currentEntryID,
            originalCurrentIndex: originalCurrentIndex,
            removedIndices: removedIndices
        )

        self.logger.info("Removed \(previousCount - remainingEntries.count) songs from queue")
        self.saveQueueForPersistence()
    }

    /// Removes later duplicate songs from the queue, keeping the first occurrence of each video ID.
    func removeDuplicateQueueEntries() {
        guard self.queueHasDuplicateEntries else { return }

        self.clearForwardSkipNavigationStack()
        self.recordQueueStateForUndo()

        let currentEntryID = self.currentQueueEntryID
        let activePlaybackEntryID = self.activePlaybackQueueEntryID
        let preferredRetainedEntryID = activePlaybackEntryID ?? currentEntryID
        let preferredRetainedEntry = preferredRetainedEntryID.flatMap { preferredRetainedEntryID in
            self.queueEntries.first(where: { $0.id == preferredRetainedEntryID })
        }
        var seenVideoIds = Set<String>()
        var deduplicatedEntries: [QueueEntry] = []
        var removedCount = 0

        for entry in self.queueEntries {
            if seenVideoIds.contains(entry.song.videoId) {
                removedCount += 1
                continue
            }
            seenVideoIds.insert(entry.song.videoId)
            if preferredRetainedEntry?.song.videoId == entry.song.videoId,
               let preferredRetainedEntry
            {
                deduplicatedEntries.append(preferredRetainedEntry)
            } else {
                deduplicatedEntries.append(entry)
            }
        }

        guard removedCount > 0 else { return }

        let priorEntries = self.queueEntries
        self.setQueue(entries: deduplicatedEntries)
        self.realignCurrentIndexAfterDuplicateRemoval(
            currentEntryID: currentEntryID,
            activePlaybackEntryID: activePlaybackEntryID,
            priorEntries: priorEntries
        )
        self.logger.info("Removed \(removedCount) duplicate queue entries")
        self.saveQueueForPersistence()
    }

    private func realignCurrentIndexAfterQueueMutation(
        currentEntryID: UUID?,
        originalCurrentIndex: Int,
        removedIndex: Int
    ) {
        self.realignCurrentIndexAfterQueueMutation(
            currentEntryID: currentEntryID,
            originalCurrentIndex: originalCurrentIndex,
            removedIndices: [removedIndex]
        )
    }

    private func realignCurrentIndexAfterQueueMutation(
        currentEntryID: UUID?,
        originalCurrentIndex: Int,
        removedIndices: [Int]
    ) {
        let currentEntries = self.queueEntries
        if let currentEntryID,
           let newIndex = currentEntries.firstIndex(where: { $0.id == currentEntryID })
        {
            self.currentIndex = newIndex
            return
        }

        let removedBeforeCurrent = removedIndices.count(where: { $0 < originalCurrentIndex })
        let adjustedIndex = max(0, originalCurrentIndex - removedBeforeCurrent)
        self.currentIndex = min(adjustedIndex, max(0, currentEntries.count - 1))
    }

    private func realignCurrentIndexAfterDuplicateRemoval(
        currentEntryID: UUID?,
        activePlaybackEntryID: UUID?,
        priorEntries: [QueueEntry]
    ) {
        if let activePlaybackEntryID,
           !self.queueEntries.contains(where: { $0.id == activePlaybackEntryID }),
           let removedActiveEntry = priorEntries.first(where: { $0.id == activePlaybackEntryID }),
           let retainedActiveEntry = self.queueEntries.first(where: {
               $0.song.videoId == removedActiveEntry.song.videoId
           })
        {
            self.activePlaybackQueueEntryID = retainedActiveEntry.id
        }
        if let currentEntryID,
           let keptIndex = self.queueEntries.firstIndex(where: { $0.id == currentEntryID })
        {
            self.currentIndex = keptIndex
            return
        }

        if let currentEntryID,
           let removedEntry = priorEntries.first(where: { $0.id == currentEntryID }),
           let fallbackIndex = self.queueEntries.firstIndex(where: { $0.song.videoId == removedEntry.song.videoId })
        {
            self.currentIndex = fallbackIndex
            return
        }

        self.currentIndex = min(self.currentIndex, max(0, self.queueEntries.count - 1))
    }

    /// Removes songs from the queue by video ID.
    /// - Parameter videoIds: Set of video IDs to remove.
    func removeFromQueue(videoIds: Set<String>) {
        self.clearForwardSkipNavigationStack()
        self.recordQueueStateForUndo()
        let previousCount = self.queue.count
        let currentEntryID = self.currentQueueEntryID
        let originalCurrentIndex = self.currentIndex
        let indicesToRemove = self.queueEntries.enumerated()
            .filter { videoIds.contains($0.element.song.videoId) }
            .map(\.offset)
        let remainingEntries = self.queueEntries.filter { !videoIds.contains($0.song.videoId) }
        self.setQueue(entries: remainingEntries)
        self.realignCurrentIndexAfterQueueMutation(
            currentEntryID: currentEntryID,
            originalCurrentIndex: originalCurrentIndex,
            removedIndices: indicesToRemove
        )

        self.logger.info("Removed \(previousCount - self.queue.count) songs from queue")
        self.saveQueueForPersistence()
    }

    /// Reorders one logical queue entry before another entry, or to the end when `beforeEntryID` is nil.
    /// Entry IDs keep drag/drop stable when the queue changes between gesture start and drop.
    func reorderQueue(entryID: UUID, before beforeEntryID: UUID?) {
        guard entryID != self.queueEntryIDOwningCurrentPlayback,
              let sourceIndex = self.queueEntries.firstIndex(where: { $0.id == entryID })
        else {
            self.logger.warning("Cannot reorder: cannot move current or missing track")
            return
        }
        guard beforeEntryID != entryID else { return }
        if let beforeEntryID,
           !self.queueEntries.contains(where: { $0.id == beforeEntryID })
        {
            return
        }

        var updatedEntries = self.queueEntries
        let movedEntry = updatedEntries.remove(at: sourceIndex)
        let destination = beforeEntryID.flatMap { targetID in
            updatedEntries.firstIndex(where: { $0.id == targetID })
        } ?? updatedEntries.endIndex
        updatedEntries.insert(movedEntry, at: destination)
        guard updatedEntries != self.queueEntries else { return }

        let currentEntryID = self.currentQueueEntryID
        self.clearForwardSkipNavigationStack()
        self.recordQueueStateForUndo()
        self.setQueue(entries: updatedEntries)
        if let currentEntryID,
           let newCurrentIndex = updatedEntries.firstIndex(where: { $0.id == currentEntryID })
        {
            self.currentIndex = newCurrentIndex
        }
        self.logger.info("Queue reordered by entry identity")
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
        self.clearForwardSkipNavigationStack()
        self.recordQueueStateForUndo()

        var updatedEntries = self.queueEntries
        let currentEntryID = self.currentQueueEntryID
        updatedEntries.move(fromOffsets: source, toOffset: destination)

        // Adjust currentIndex if needed (current track moved in the array)
        if let currentEntryID,
           let newCurrentIndex = updatedEntries.firstIndex(where: { $0.id == currentEntryID })
        {
            self.currentIndex = newCurrentIndex
        }

        self.setQueue(entries: updatedEntries)
        self.logger.info("Queue reordered: moved from \(source) to \(destination)")
        self.saveQueueForPersistence()
    }

    /// Reorders the queue based on a new order of video IDs.
    /// - Parameter videoIds: The new order of video IDs.
    func reorderQueue(videoIds: [String]) {
        self.clearForwardSkipNavigationStack()
        self.recordQueueStateForUndo()
        let currentEntryID = self.currentQueueEntryID
        let currentEntries = self.queueEntries
        var entriesByVideoId: [String: [QueueEntry]] = [:]
        for entry in currentEntries {
            entriesByVideoId[entry.song.videoId, default: []].append(entry)
        }

        var reorderedEntries: [QueueEntry] = []
        for videoId in videoIds {
            guard var entries = entriesByVideoId[videoId], !entries.isEmpty else { continue }
            reorderedEntries.append(entries.removeFirst())
            entriesByVideoId[videoId] = entries
        }

        self.setQueue(entries: reorderedEntries)

        // Update currentIndex to match current track's new position
        if let currentEntryID,
           let newIndex = reorderedEntries.firstIndex(where: { $0.id == currentEntryID })
        {
            self.currentIndex = newIndex
        } else {
            self.currentIndex = min(self.currentIndex, max(0, reorderedEntries.count - 1))
        }

        self.logger.info("Queue reordered with \(reorderedEntries.count) songs")
        self.saveQueueForPersistence()
    }

    /// Shuffles the queue, keeping the current track in place at the front.
    func shuffleQueue() {
        self.beginMusicPlaybackIntent(allowsPriorTerminalEvent: true)
        self.materializeShuffleQueueForCurrentTrack(recordUndo: true, storesOriginalOrder: false)
    }

    /// Reorders the queue into the actual shuffled playback order.
    /// Keeps the current track first so the visible "next up" order matches playback.
    func materializeShuffleQueueForCurrentTrack(recordUndo: Bool, storesOriginalOrder: Bool) {
        guard self.queue.count > 1 else { return }
        self.materializeShuffleQueue(
            entries: self.queueEntries,
            startingAt: self.currentIndex,
            recordUndo: recordUndo,
            storesOriginalOrder: storesOriginalOrder
        )
    }

    /// Reorders the provided entries into a shuffled playback order.
    func materializeShuffleQueue(
        entries: [QueueEntry],
        startingAt index: Int,
        recordUndo: Bool,
        storesOriginalOrder: Bool
    ) {
        guard entries.count > 1 else {
            self.setQueue(entries: entries)
            self.currentIndex = min(max(index, 0), max(0, entries.count - 1))
            return
        }
        self.clearForwardSkipNavigationStack()
        if recordUndo {
            self.recordQueueStateForUndo()
        }
        if storesOriginalOrder {
            self.queueOrderBeforeShuffle = entries
        }

        // Remove current track, shuffle the rest, put current track at front
        var shuffledEntries = entries
        let safeIndex = min(max(index, 0), shuffledEntries.count - 1)
        let currentEntry = shuffledEntries.remove(at: safeIndex)
        shuffledEntries.shuffle()
        shuffledEntries.insert(currentEntry, at: 0)
        self.setQueue(entries: shuffledEntries)
        self.currentIndex = 0

        self.logger.info("Queue shuffled")
        self.saveQueueForPersistence()
    }

    /// Restores the queue order captured before shuffle was enabled.
    func restoreQueueOrderBeforeShuffle(recordUndo: Bool) {
        guard let snapshot = self.queueOrderBeforeShuffle, !snapshot.isEmpty else {
            self.queueOrderBeforeShuffle = nil
            return
        }

        let currentEntries = self.queueEntries
        let currentEntryID = self.currentQueueEntryID
        let currentEntriesByID = Dictionary(uniqueKeysWithValues: currentEntries.map { ($0.id, $0) })
        let currentEntryIDs = Set(currentEntries.map(\.id))

        let snapshotEntryIDs = Set(snapshot.map(\.id))
        var restoredEntries: [QueueEntry] = []
        if let currentEntryID,
           snapshotEntryIDs.contains(currentEntryID) == false,
           let currentEntry = currentEntriesByID[currentEntryID],
           let currentPosition = currentEntries.firstIndex(where: { $0.id == currentEntryID })
        {
            // The current Smart Shuffle suggestion is not in the original-order snapshot. Keep
            // originals that were already behind the playhead before it, then insert the current
            // suggestion, then restore the remaining originals in playlist order so Next continues
            // through the unplayed playlist instead of skipping it.
            let originalIDsBeforeCurrent = Set(
                currentEntries[..<currentPosition]
                    .filter { snapshotEntryIDs.contains($0.id) }
                    .map(\.id)
            )
            for entry in snapshot where currentEntryIDs.contains(entry.id) && originalIDsBeforeCurrent.contains(entry.id) {
                restoredEntries.append(currentEntriesByID[entry.id] ?? entry)
            }
            restoredEntries.append(currentEntry)
            for entry in snapshot where currentEntryIDs.contains(entry.id) && originalIDsBeforeCurrent.contains(entry.id) == false {
                restoredEntries.append(currentEntriesByID[entry.id] ?? entry)
            }
        } else {
            for entry in snapshot where currentEntryIDs.contains(entry.id) {
                restoredEntries.append(currentEntriesByID[entry.id] ?? entry)
            }
        }

        let restoredEntryIDs = Set(restoredEntries.map(\.id))
        restoredEntries.append(contentsOf: currentEntries.filter { !restoredEntryIDs.contains($0.id) })

        guard !restoredEntries.isEmpty else {
            self.queueOrderBeforeShuffle = nil
            return
        }

        self.clearForwardSkipNavigationStack()
        if recordUndo {
            self.recordQueueStateForUndo()
        }

        self.setQueue(entries: restoredEntries)
        if let currentEntryID,
           let restoredIndex = self.queueEntryIDs.firstIndex(of: currentEntryID)
        {
            self.currentIndex = restoredIndex
        } else {
            self.currentIndex = min(self.currentIndex, restoredEntries.count - 1)
        }
        self.queueOrderBeforeShuffle = nil
        self.logger.info("Restored queue order before shuffle")
        self.saveQueueForPersistence()
    }

    /// Adds songs to the end of the queue.
    /// - Parameter songs: The songs to append to the queue.
    func appendToQueue(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        self.recordQueueStateForUndo()
        self.setQueue(entries: self.queueEntries + songs.map { QueueEntry(id: UUID(), song: $0) })
        self.logger.info("Appended \(songs.count) songs to queue")
        self.saveQueueForPersistence()
    }

    // MARK: - Queue Persistence

    /// Serialized playback session persisted across launches.
    private struct PersistedPlaybackSession: Codable, Hashable {
        let queue: [Song]
        let entrySources: [QueueEntry.Source]?
        let currentIndex: Int
        let currentVideoId: String?
        let progress: TimeInterval
        let duration: TimeInterval
        let ownerScope: String?
        let shuffleMode: ShuffleMode?
        let preShuffleQueue: [Song]?
        let preShuffleEntrySources: [QueueEntry.Source]?
        let preShuffleActiveIndex: Int?
        let preShuffleEntryIndices: [Int]?
    }

    /// UserDefaults keys for queue persistence (no expiry; saved queue is kept until overwritten or cleared).
    private static let savedQueueKey = "kaset.saved.queue"
    private static let savedQueueIndexKey = "kaset.saved.queueIndex"
    private static let savedPlaybackSessionKey = "kaset.saved.playbackSession"

    private var savedQueueKey: String {
        Self.savedQueueKey + self.queuePersistenceKeySuffix
    }

    private var savedQueueIndexKey: String {
        Self.savedQueueIndexKey + self.queuePersistenceKeySuffix
    }

    private var savedPlaybackSessionKey: String {
        Self.savedPlaybackSessionKey + self.queuePersistenceKeySuffix
    }

    #if DEBUG
        func useQueuePersistenceNamespaceForTesting(_ namespace: String) {
            self.queuePersistenceKeySuffix = namespace.isEmpty ? "" : ".\(namespace)"
        }
    #endif

    private func hasPersistedPlaybackSessionPayload() -> Bool {
        self.queuePersistenceDefaults.data(forKey: self.savedQueueKey) != nil &&
            self.queuePersistenceDefaults.object(forKey: self.savedQueueIndexKey) != nil &&
            self.queuePersistenceDefaults.data(forKey: self.savedPlaybackSessionKey) != nil
    }

    /// Saves the current queue to UserDefaults for restoration on next launch.
    func saveQueueForPersistence(ownerScopeOverride: String? = nil) {
        let queue = self.queue
        guard !queue.isEmpty || self.currentTrack != nil else {
            if self.suppressNextEmptyQueuePersistence {
                self.suppressNextEmptyQueuePersistence = false
                self.logger.info("Skipped clearing saved playback session after guest-startup cleanup")
                return
            }
            self.removeSavedPlaybackSession()
            self.logger.info("Cleared saved playback session (queue is empty)")
            return
        }

        self.suppressNextEmptyQueuePersistence = false

        // Smart Shuffle suggestions are ephemeral (regenerated from live context), so never
        // persist them. Strip before saving, keeping the currently-playing track if it is one.
        let activeQueueEntryID = self.queueEntryIDOwningCurrentPlayback
        let persistedEntries: [QueueEntry]
        let currentID: UUID?
        if let activeQueueEntryID {
            currentID = activeQueueEntryID
            persistedEntries = Self.stripSuggested(
                from: self.queueEntries,
                keepingCurrentID: activeQueueEntryID
            )
        } else if let currentTrack = self.currentTrack {
            let standaloneEntry = QueueEntry(id: UUID(), song: currentTrack)
            currentID = standaloneEntry.id
            persistedEntries = [standaloneEntry]
        } else {
            currentID = nil
            persistedEntries = Self.stripSuggested(
                from: self.queueEntries,
                keepingCurrentID: nil
            )
        }
        let persistableQueue = persistedEntries.map(\.song)
        let persistedEntryIDs = Set(persistedEntries.map(\.id))
        let preShuffleEntries = self.queueOrderBeforeShuffle?.filter {
            persistedEntryIDs.contains($0.id)
        }
        guard !persistableQueue.isEmpty else {
            self.removeSavedPlaybackSession()
            return
        }

        do {
            let encoder = Self.persistenceEncoder()
            let safeIndex = self.persistedCurrentIndex(currentID: currentID, entries: persistedEntries)
            let currentVideoId = self.currentTrack?.videoId ?? persistableQueue[safe: safeIndex]?.videoId
            let queuedTrack = persistableQueue[safe: safeIndex]
            let ownedQueueTrack = activeQueueEntryID.flatMap { activeID in
                persistedEntries.first(where: { $0.id == activeID })?.song
            }
            let resolvedDuration = self.resolvedPersistenceDuration(
                queuedTrack: queuedTrack,
                ownedQueueTrack: ownedQueueTrack
            )
            let clampedProgress = resolvedDuration > 0
                ? min(max(self.progress, 0), resolvedDuration)
                : max(self.progress, 0)

            let isKnownGuestSession = self.authService?.shouldPersistGuestPlaybackState == true
            let ownerScope = ownerScopeOverride ?? (isKnownGuestSession
                ? Self.playbackSessionScopeGuest
                : Self.playbackSessionScopeAuthenticated)
            let persistedQueue = isKnownGuestSession ? Self.queueWithoutAccountMetadata(persistableQueue) : persistableQueue
            let persistedEntryIndexByID = Dictionary(
                uniqueKeysWithValues: persistedEntries.enumerated().map { ($0.element.id, $0.offset) }
            )
            let preShuffleEntryIndices = preShuffleEntries?.compactMap { persistedEntryIndexByID[$0.id] }
            let session = PersistedPlaybackSession(
                queue: persistedQueue,
                entrySources: persistedEntries.map(\.source),
                currentIndex: safeIndex,
                currentVideoId: currentVideoId,
                progress: clampedProgress,
                duration: resolvedDuration,
                ownerScope: ownerScope,
                shuffleMode: self.shuffleMode,
                preShuffleQueue: preShuffleEntries.map { entries in
                    let songs = entries.map(\.song)
                    return isKnownGuestSession ? Self.queueWithoutAccountMetadata(songs) : songs
                },
                preShuffleEntrySources: preShuffleEntries?.map(\.source),
                preShuffleActiveIndex: activeQueueEntryID.flatMap { activeID in
                    preShuffleEntries?.firstIndex(where: { $0.id == activeID })
                },
                preShuffleEntryIndices: preShuffleEntryIndices
            )
            let queueData = try encoder.encode(persistedQueue)
            let sessionData = try encoder.encode(session)
            if self.lastSavedPlaybackSessionSignature == sessionData, self.hasPersistedPlaybackSessionPayload() {
                self.logger.debug("Skipped unchanged playback session persistence")
                return
            }

            self.queuePersistenceDefaults.set(queueData, forKey: self.savedQueueKey)
            self.queuePersistenceDefaults.set(safeIndex, forKey: self.savedQueueIndexKey)
            self.queuePersistenceDefaults.set(sessionData, forKey: self.savedPlaybackSessionKey)
            self.lastSavedPlaybackSessionSignature = sessionData
            self.queuePersistenceWriteCountForTesting += 1
            self.restoredPlaybackSessionOwnerScope = ownerScope
            self.logger.info("Saved playback session with \(persistedQueue.count) songs at index \(safeIndex)")
        } catch {
            self.logger.error("Failed to save playback session: \(error.localizedDescription)")
        }
    }

    private static func persistenceEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func persistedCurrentIndex(currentID: UUID?, entries: [QueueEntry]) -> Int {
        if let currentID, let index = entries.firstIndex(where: { $0.id == currentID }) {
            return index
        }
        return min(max(self.currentIndex, 0), entries.count - 1)
    }

    /// Resolves the persisted clock without borrowing metadata from a different queue occurrence.
    private func resolvedPersistenceDuration(
        queuedTrack: Song?,
        ownedQueueTrack: Song?
    ) -> TimeInterval {
        let persistenceTrack = self.currentTrack ?? ownedQueueTrack ?? queuedTrack
        let primaryDuration = self.bestKnownDuration(for: persistenceTrack)
        guard primaryDuration <= 0 else { return primaryDuration }

        // WebView metadata can temporarily replace the same queue song without a duration. Retain
        // the queue/API duration only from the exact entry that owns playback, bypassing observation
        // precedence because reaching this branch already proved no positive observation exists.
        return self.positiveMetadataDuration(for: ownedQueueTrack)
    }

    static func songWithoutAccountMetadata(_ song: Song) -> Song {
        var sanitized = song
        sanitized.likeStatus = nil
        sanitized.isInLibrary = nil
        sanitized.feedbackTokens = nil
        return sanitized
    }

    private static func queueWithoutAccountMetadata(_ queue: [Song]) -> [Song] {
        queue.map(self.songWithoutAccountMetadata)
    }

    func invalidatePendingPlaybackRequests() {
        self.beginMusicPlaybackIntent()
        self.invalidateMixContinuationRequest()
    }

    /// Re-tags a restored/persisted playback session after crossing a playback
    /// privacy boundary without otherwise changing the queue payload.
    func updateRestoredPlaybackSessionOwnerScope(_ ownerScope: String?) {
        self.restoredPlaybackSessionOwnerScope = ownerScope

        guard let sessionData = self.queuePersistenceDefaults.data(forKey: self.savedPlaybackSessionKey) else { return }

        do {
            let decoder = JSONDecoder()
            let savedSession = try decoder.decode(PersistedPlaybackSession.self, from: sessionData)
            let updatedSession = PersistedPlaybackSession(
                queue: savedSession.queue,
                entrySources: savedSession.entrySources,
                currentIndex: savedSession.currentIndex,
                currentVideoId: savedSession.currentVideoId,
                progress: savedSession.progress,
                duration: savedSession.duration,
                ownerScope: ownerScope,
                shuffleMode: savedSession.shuffleMode,
                preShuffleQueue: savedSession.preShuffleQueue,
                preShuffleEntrySources: savedSession.preShuffleEntrySources,
                preShuffleActiveIndex: savedSession.preShuffleActiveIndex,
                preShuffleEntryIndices: savedSession.preShuffleEntryIndices
            )
            let sessionData = try JSONEncoder().encode(updatedSession)
            self.queuePersistenceDefaults.set(sessionData, forKey: self.savedPlaybackSessionKey)
            self.lastSavedPlaybackSessionSignature = nil
        } catch {
            self.logger.error("Failed to update playback session owner scope: \(error.localizedDescription)")
        }
    }

    /// Restores the queue from UserDefaults if available.
    /// - Returns: True if queue was restored, false otherwise.
    @discardableResult
    func restoreQueueFromPersistence() -> Bool {
        let decoder = JSONDecoder()

        if let sessionData = self.queuePersistenceDefaults.data(forKey: self.savedPlaybackSessionKey) {
            do {
                let savedSession = try decoder.decode(PersistedPlaybackSession.self, from: sessionData)
                let restoredQueue = savedSession.ownerScope == Self.playbackSessionScopeGuest
                    ? Self.queueWithoutAccountMetadata(savedSession.queue)
                    : savedSession.queue
                guard !restoredQueue.isEmpty else {
                    self.logger.info("Saved playback session is empty")
                    self.queuePersistenceDefaults.removeObject(forKey: self.savedPlaybackSessionKey)
                    return self.restoreLegacyQueueFromPersistence(using: decoder)
                }

                let resolvedIndex = self.resolvedPersistedQueueIndex(
                    savedIndex: savedSession.currentIndex,
                    currentVideoId: savedSession.currentVideoId,
                    in: restoredQueue
                )

                self.applyRestoredPlaybackSession(
                    queue: restoredQueue,
                    entrySources: savedSession.entrySources,
                    currentIndex: resolvedIndex,
                    progress: savedSession.progress,
                    duration: savedSession.duration
                )
                let savedShuffleMode = savedSession.shuffleMode ?? self.shuffleMode
                self.shuffleMode = Self.resolvedShuffleMode(
                    savedShuffleMode,
                    smartShuffleEnabled: self.smartShuffleFeatureEnabled()
                )
                self.queueOrderBeforeShuffle = self.reconstructedPreShuffleEntries(
                    songs: savedSession.preShuffleQueue,
                    sources: savedSession.preShuffleEntrySources,
                    activeIndex: savedSession.preShuffleActiveIndex,
                    entryIndices: savedSession.preShuffleEntryIndices
                )
                self.restoredPlaybackSessionOwnerScope = savedSession.ownerScope
                self.logger.info(
                    "Restored playback session with \(restoredQueue.count) songs at index \(resolvedIndex)"
                )
                self.fillSmartShuffleWindowAfterRestoreIfNeeded()
                return true
            } catch {
                self.logger.error("Failed to restore playback session: \(error.localizedDescription)")
                self.queuePersistenceDefaults.removeObject(forKey: self.savedPlaybackSessionKey)
            }
        }

        return self.restoreLegacyQueueFromPersistence(using: decoder)
    }

    private func reconstructedPreShuffleEntries(
        songs: [Song]?,
        sources: [QueueEntry.Source]?,
        activeIndex: Int?,
        entryIndices: [Int]?
    ) -> [QueueEntry]? {
        guard let songs, !songs.isEmpty else { return nil }
        if let entryIndices,
           entryIndices.count == songs.count,
           Set(entryIndices).count == entryIndices.count,
           entryIndices.indices.allSatisfy({ index in
               self.queueEntries.indices.contains(entryIndices[index])
                   && self.queueEntries[entryIndices[index]].song.videoId == songs[index].videoId
           })
        {
            return entryIndices.enumerated().map { index, queueIndex in
                let entry = self.queueEntries[queueIndex]
                return QueueEntry(
                    id: entry.id,
                    song: entry.song,
                    source: sources?[safe: index] ?? entry.source
                )
            }
        }

        var availableEntries = self.queueEntries
        var restoredEntries: [QueueEntry] = []
        restoredEntries.reserveCapacity(songs.count)

        for (index, song) in songs.enumerated() {
            let activeEntryID = self.activePlaybackQueueEntryID
            let activeMatchIndex = index == activeIndex ? availableEntries.firstIndex(where: {
                $0.id == activeEntryID
                    && $0.song.id == song.id
                    && $0.song.videoId == song.videoId
            }) : nil
            let reservesActiveEntry = activeIndex != nil && index != activeIndex
            let matchIndex = activeMatchIndex
                ?? availableEntries.firstIndex(where: {
                    (!reservesActiveEntry || $0.id != activeEntryID)
                        && $0.song.id == song.id
                        && $0.song.videoId == song.videoId
                })
                ?? availableEntries.firstIndex(where: {
                    (!reservesActiveEntry || $0.id != activeEntryID)
                        && $0.song.videoId == song.videoId
                })
            guard let matchIndex else { continue }
            var entry = availableEntries.remove(at: matchIndex)
            if let source = sources?[safe: index] {
                entry = QueueEntry(id: entry.id, song: entry.song, source: source)
            }
            restoredEntries.append(entry)
        }
        return restoredEntries.isEmpty ? nil : restoredEntries
    }

    /// After restoring a saved session in smart mode, regenerates the (ephemeral, never-persisted)
    /// suggestion window so it is present without requiring a manual track advance. Best effort: a
    /// no-op until a client is attached and while the queue is still loading.
    private func fillSmartShuffleWindowAfterRestoreIfNeeded() {
        guard self.shuffleMode == .smart else { return }
        self.scheduleSmartShuffleFillForCurrentQueue()
    }

    /// Clears the saved queue from UserDefaults.
    func clearSavedQueue() {
        self.removeSavedPlaybackSession()
        self.logger.info("Cleared saved queue")
    }

    /// Restores the legacy queue/index payload when no playback session is available.
    private func restoreLegacyQueueFromPersistence(using decoder: JSONDecoder) -> Bool {
        guard let queueData = self.queuePersistenceDefaults.data(forKey: self.savedQueueKey),
              let savedIndex = self.queuePersistenceDefaults.object(forKey: self.savedQueueIndexKey) as? Int
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
            self.restoredPlaybackSessionOwnerScope = nil
            self.logger.info("Restored legacy queue with \(savedQueue.count) songs at index \(resolvedIndex)")
            self.fillSmartShuffleWindowAfterRestoreIfNeeded()
            return true
        } catch {
            self.logger.error("Failed to restore legacy queue: \(error.localizedDescription)")
            self.clearSavedQueue()
            return false
        }
    }

    /// Removes all persisted queue/session payloads.
    private func removeSavedPlaybackSession() {
        self.queuePersistenceDefaults.removeObject(forKey: self.savedQueueKey)
        self.queuePersistenceDefaults.removeObject(forKey: self.savedQueueIndexKey)
        self.queuePersistenceDefaults.removeObject(forKey: self.savedPlaybackSessionKey)
        self.restoredPlaybackSessionOwnerScope = nil
        self.lastSavedPlaybackSessionSignature = nil
    }

    /// Resolves the queue index from saved metadata.
    /// Prefers the persisted index when it is valid so duplicate tracks restore to the exact entry.
    /// Falls back to the saved video ID only for legacy or invalid payloads.
    private func resolvedPersistedQueueIndex(
        savedIndex: Int,
        currentVideoId: String?,
        in queue: [Song]
    ) -> Int {
        if queue.indices.contains(savedIndex) {
            return savedIndex
        }

        if let currentVideoId,
           let matchingIndex = queue.firstIndex(where: { $0.videoId == currentVideoId })
        {
            return matchingIndex
        }

        return min(max(savedIndex, 0), queue.count - 1)
    }
}
