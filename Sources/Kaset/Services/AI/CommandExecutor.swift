import Foundation

@available(macOS 26.0, *)
@MainActor
struct CommandExecutor {
    private struct QueueCommandOwnership {
        let playbackIntent: MusicPlaybackIntent?
        let queueGeneration: Int?
    }

    enum Request: Equatable {
        case pause
        case resume
        case skip
        case previous
        case like
        case dislike
        case clearQueue
        case shuffleQueue
        case toggleShuffle
        case playSearch(query: String, description: String)
        case queueSearch(query: String, description: String)
        case openSearch(query: String)
        case musicIntent(MusicIntent)

        var requiresPlaybackClaim: Bool {
            switch self {
            case .pause, .resume, .skip, .previous, .clearQueue, .shuffleQueue,
                 .toggleShuffle, .playSearch:
                true
            case let .musicIntent(intent):
                switch intent.action {
                case .play, .shuffle, .skip, .previous, .pause, .resume:
                    true
                case .queue, .like, .dislike, .search:
                    false
                }
            case .queueSearch, .like, .dislike, .openSearch:
                false
            }
        }

        var isQueueRequest: Bool {
            switch self {
            case .queueSearch:
                true
            case let .musicIntent(intent):
                intent.action == .queue
            default:
                false
            }
        }

        var requiresPlaybackValidation: Bool {
            switch self {
            case .like, .dislike:
                true
            case let .musicIntent(intent):
                intent.action == .like || intent.action == .dislike
            default:
                false
            }
        }
    }

    struct Outcome: Equatable {
        let resultMessage: String?
        let errorMessage: String?
        let shouldDismiss: Bool
        let searchQueryToOpen: String?

        static func result(_ message: String, shouldDismiss: Bool = true) -> Self {
            Self(
                resultMessage: message,
                errorMessage: nil,
                shouldDismiss: shouldDismiss,
                searchQueryToOpen: nil
            )
        }

        static func error(_ message: String) -> Self {
            Self(
                resultMessage: nil,
                errorMessage: message,
                shouldDismiss: false,
                searchQueryToOpen: nil
            )
        }

        static func openSearch(_ query: String) -> Self {
            Self(
                resultMessage: nil,
                errorMessage: nil,
                shouldDismiss: false,
                searchQueryToOpen: query
            )
        }

        static var ignored: Self {
            Self(
                resultMessage: nil,
                errorMessage: nil,
                shouldDismiss: false,
                searchQueryToOpen: nil
            )
        }
    }

    let client: any YTMusicClientProtocol
    let playerService: any PlayerServiceProtocol

    private let logger = DiagnosticsLogger.ai

    func execute(
        _ request: Request,
        reservation: MusicPlaybackReservation? = nil
    ) async -> Outcome {
        guard !Task.isCancelled else { return .ignored }
        let playbackIntent: MusicPlaybackIntent?
        let queueGeneration: Int?
        if request.isQueueRequest, !self.playerService.queue.isEmpty {
            playbackIntent = nil
            let submittedQueueGeneration = reservation?.queueMutationGeneration
                ?? self.playerService.reserveQueueMutation()
            guard self.playerService.acceptsQueueMutation(submittedQueueGeneration) else {
                return .ignored
            }
            queueGeneration = submittedQueueGeneration
        } else if request.requiresPlaybackClaim || request.isQueueRequest {
            guard let claimedIntent = self.claimPlaybackIntent(reservation) else { return .ignored }
            playbackIntent = claimedIntent
            queueGeneration = nil
        } else {
            playbackIntent = nil
            queueGeneration = nil
            if request.requiresPlaybackValidation {
                guard self.validatePlaybackReservation(reservation) else { return .ignored }
            }
        }

        switch request {
        case .pause, .resume, .skip, .previous:
            return await self.executeTransportControl(request)
        case .like, .dislike, .clearQueue, .shuffleQueue, .toggleShuffle:
            return self.executeImmediateControl(request)
        case let .playSearch(query, description):
            guard let playbackIntent else { return .ignored }
            return await self.playSearchResult(
                query: query,
                description: description,
                playbackIntent: playbackIntent
            )
        case let .queueSearch(query, description):
            return await self.queueSearchResult(
                query: query,
                description: description,
                ownership: QueueCommandOwnership(
                    playbackIntent: playbackIntent,
                    queueGeneration: queueGeneration
                )
            )
        case let .openSearch(query):
            return .openSearch(query)
        case let .musicIntent(intent):
            return await self.executeMusicIntent(
                intent,
                ownership: QueueCommandOwnership(
                    playbackIntent: playbackIntent,
                    queueGeneration: queueGeneration
                )
            )
        }
    }

    private func executeTransportControl(_ request: Request) async -> Outcome {
        HapticService.playback()
        switch request {
        case .pause:
            await self.playerService.pause()
            return .result("Paused")
        case .resume:
            await self.playerService.resume()
            return .result("Playing")
        case .skip:
            await self.playerService.next()
            return .result("Skipped")
        case .previous:
            await self.playerService.previous()
            return .result("Playing previous track")
        default:
            return .ignored
        }
    }

    private func executeImmediateControl(_ request: Request) -> Outcome {
        HapticService.toggle()
        switch request {
        case .like:
            self.playerService.likeCurrentTrack()
            return .result("Liked!")
        case .dislike:
            self.playerService.dislikeCurrentTrack()
            return .result("Disliked")
        case .clearQueue:
            self.playerService.clearQueue()
            return .result("Queue cleared")
        case .shuffleQueue:
            self.playerService.shuffleQueue()
            return .result("Queue shuffled")
        case .toggleShuffle:
            self.playerService.toggleShuffle()
            let status = self.playerService.shuffleEnabled ? "on" : "off"
            return .result("Shuffle is now \(status)")
        default:
            return .ignored
        }
    }

    private func claimPlaybackIntent(
        _ reservation: MusicPlaybackReservation?
    ) -> MusicPlaybackIntent? {
        let reservation = reservation ?? self.playerService.reserveMusicPlaybackIntent()
        return self.playerService.claimMusicPlaybackIntent(reservation)
    }

    private func validatePlaybackReservation(
        _ reservation: MusicPlaybackReservation?
    ) -> Bool {
        let reservation = reservation ?? self.playerService.reserveMusicPlaybackIntent()
        return self.playerService.acceptsMusicPlaybackReservation(reservation)
    }

    private func commandStillOwnsPlayback(_ intent: MusicPlaybackIntent) -> Bool {
        !Task.isCancelled && self.playerService.acceptsMusicPlaybackIntent(intent)
    }

    private func commandStillOwnsQueue(_ ownership: QueueCommandOwnership) -> Bool {
        if let playbackIntent = ownership.playbackIntent {
            return self.commandStillOwnsPlayback(playbackIntent)
        }
        if let queueGeneration = ownership.queueGeneration {
            return !Task.isCancelled
                && self.playerService.acceptsQueueMutation(queueGeneration)
        }
        return false
    }

    func describeQueueLocally(previewLimit: Int = 3) -> Outcome {
        let queue = self.playerService.queue

        guard !queue.isEmpty else {
            return .result("Your queue is empty.", shouldDismiss: false)
        }

        guard let activeIndex = self.playerService.activePlaybackQueueIndex else {
            let preview = queue.prefix(previewLimit).map { song in
                let artist = song.artistsDisplay.isEmpty ? "Unknown Artist" : song.artistsDisplay
                return "\"\(song.title)\" by \(artist)"
            }.joined(separator: ", ")
            let remainingCount = max(0, queue.count - min(previewLimit, queue.count))
            let suffix = remainingCount > 0 ? ", and \(remainingCount) more." : "."
            return .result(
                "Your queue has \(queue.count) tracks: \(preview)\(suffix)",
                shouldDismiss: false
            )
        }
        let safeCurrentIndex = min(max(activeIndex, 0), queue.count - 1)
        let currentTrack = queue[safe: safeCurrentIndex] ?? queue[0]
        let currentArtist = currentTrack.artistsDisplay.isEmpty ? "Unknown Artist" : currentTrack.artistsDisplay
        let intro = if self.playerService.isPlaying {
            "Now playing"
        } else {
            "Currently on"
        }

        let upcoming = Array(queue.dropFirst(safeCurrentIndex + 1).prefix(previewLimit))
        var summary = "\(intro) \"\(currentTrack.title)\" by \(currentArtist)."

        if !upcoming.isEmpty {
            let preview = upcoming.map { song in
                let artist = song.artistsDisplay.isEmpty ? "Unknown Artist" : song.artistsDisplay
                return "\"\(song.title)\" by \(artist)"
            }.joined(separator: ", ")

            let remainingCount = max(0, queue.count - safeCurrentIndex - 1 - upcoming.count)
            summary += " Up next: \(preview)"
            if remainingCount > 0 {
                summary += ", and \(remainingCount) more."
            } else {
                summary += "."
            }
        } else if queue.count == 1 {
            summary += " That's the only song in your queue."
        } else {
            summary += " That's the end of your queue."
        }

        return .result(summary, shouldDismiss: false)
    }

    private func executeMusicIntent(
        _ intent: MusicIntent,
        ownership: QueueCommandOwnership
    ) async -> Outcome {
        let searchQuery = ContentSourceResolver.buildSearchQuery(from: intent)
        let description = ContentSourceResolver.queryDescription(for: intent)
        let contentSource = ContentSourceResolver.suggestedContentSource(for: intent)

        self.logger.info("Executing intent: \(intent.action.rawValue)")
        self.logger.info("  Raw query: \(intent.query)")
        self.logger.info("  Artist: \(intent.artist), Genre: \(intent.genre), Mood: \(intent.mood)")
        self.logger.info("  Era: \(intent.era), Version: \(intent.version), Activity: \(intent.activity)")
        self.logger.info("  Built search query: \(searchQuery)")
        self.logger.info("  Content source: \(contentSource)")

        switch intent.action {
        case .play:
            HapticService.playback()
            if searchQuery.isEmpty, intent.query.isEmpty {
                await self.playerService.resume()
                return .result("Resuming playback")
            }
            guard let playbackIntent = ownership.playbackIntent else { return .ignored }
            return await self.playContent(
                intent: intent,
                query: searchQuery,
                description: description,
                source: contentSource,
                playbackIntent: playbackIntent
            )

        case .queue:
            HapticService.success()
            if !searchQuery.isEmpty {
                return await self.queueContent(
                    intent: intent,
                    query: searchQuery,
                    description: description,
                    source: contentSource,
                    ownership: ownership
                )
            }
            return .error(String(localized: "Couldn't search for music"))

        case .shuffle:
            HapticService.toggle()
            if intent.shuffleScope == "queue" {
                self.playerService.shuffleQueue()
                return .result("Queue shuffled")
            }
            self.playerService.toggleShuffle()
            let status = self.playerService.shuffleEnabled ? "on" : "off"
            return .result("Shuffle is now \(status)")

        case .like:
            HapticService.toggle()
            self.playerService.likeCurrentTrack()
            return .result("Liked!")

        case .dislike:
            HapticService.toggle()
            self.playerService.dislikeCurrentTrack()
            return .result("Disliked")

        case .skip:
            HapticService.playback()
            await self.playerService.next()
            return .result("Skipped")

        case .previous:
            HapticService.playback()
            await self.playerService.previous()
            return .result("Playing previous track")

        case .pause:
            HapticService.playback()
            await self.playerService.pause()
            return .result("Paused")

        case .resume:
            HapticService.playback()
            await self.playerService.resume()
            return .result("Playing")

        case .search:
            let fallbackQuery = intent.query.isEmpty ? searchQuery : intent.query
            return .openSearch(fallbackQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func playSearchResult(
        query: String,
        description: String = "",
        playbackIntent: MusicPlaybackIntent
    ) async -> Outcome {
        do {
            let allSongs = try await self.client.searchSongs(query: query)
            guard self.commandStillOwnsPlayback(playbackIntent) else { return .ignored }
            let songs = Array(allSongs.prefix(20))

            self.logger.info("Songs search returned \(allSongs.count), using top \(songs.count) for query: \(query)")
            if let firstSong = songs.first {
                await self.playerService.playQueue(
                    songs,
                    startingAt: 0,
                    deferringSmartShuffleFill: false,
                    intent: playbackIntent
                )
                guard self.commandStillOwnsPlayback(playbackIntent) else { return .ignored }
                self.logger.info("Started queue with \(songs.count) songs, first: \(firstSong.title)")
                if !description.isEmpty {
                    return .result("Playing \(description)")
                }
                return .result("Playing \"\(firstSong.title)\"")
            }
            return .error("No songs found for \"\(query)\"")
        } catch {
            guard self.commandStillOwnsPlayback(playbackIntent) else { return .ignored }
            self.logger.error("Search failed: \(error.localizedDescription)")
            return .error(String(localized: "Couldn't search for music"))
        }
    }

    private func queueSearchResult(
        query: String,
        description: String = "",
        ownership: QueueCommandOwnership
    ) async -> Outcome {
        do {
            let allSongs = try await self.client.searchSongs(query: query)
            guard self.commandStillOwnsQueue(ownership) else { return .ignored }
            let songs = Array(allSongs.prefix(10))

            self.logger.info("Queue songs search returned \(allSongs.count), using top \(songs.count) for query: \(query)")
            if let firstSong = songs.first {
                if self.playerService.queue.isEmpty {
                    guard let playbackIntent = ownership.playbackIntent else { return .ignored }
                    await self.playerService.playQueue(
                        songs,
                        startingAt: 0,
                        deferringSmartShuffleFill: false,
                        intent: playbackIntent
                    )
                    guard self.commandStillOwnsPlayback(playbackIntent) else { return .ignored }
                    if !description.isEmpty {
                        return .result("Playing \(description)")
                    }
                    return .result("Playing \"\(firstSong.title)\" and \(songs.count - 1) more")
                }

                self.playerService.appendToQueue(songs)
                if !description.isEmpty {
                    return .result("Added \(description) to queue")
                }
                return .result("Added \(songs.count) songs to queue")
            }
            return .error("No songs found for \"\(query)\"")
        } catch {
            guard self.commandStillOwnsQueue(ownership) else { return .ignored }
            self.logger.error("Search failed: \(error.localizedDescription)")
            return .error(String(localized: "Couldn't search for music"))
        }
    }

    private func playContent(
        intent: MusicIntent,
        query: String,
        description: String,
        source: ContentSource,
        playbackIntent: MusicPlaybackIntent
    ) async -> Outcome {
        switch source {
        case .moodsAndGenres:
            if let songs = await self.findSongsFromMoodsAndGenres(intent: intent) {
                guard self.commandStillOwnsPlayback(playbackIntent) else { return .ignored }
                await self.playerService.playQueue(
                    songs,
                    startingAt: 0,
                    deferringSmartShuffleFill: false,
                    intent: playbackIntent
                )
                guard self.commandStillOwnsPlayback(playbackIntent) else { return .ignored }
                return .result("Playing \(description.isEmpty ? "curated playlist" : description)")
            }

            self.logger.info("No matching Moods & Genres playlist, falling back to search")
            return await self.playSearchResult(
                query: query,
                description: description,
                playbackIntent: playbackIntent
            )

        case .charts:
            if let songs = await self.findSongsFromCharts() {
                guard self.commandStillOwnsPlayback(playbackIntent) else { return .ignored }
                await self.playerService.playQueue(
                    songs,
                    startingAt: 0,
                    deferringSmartShuffleFill: false,
                    intent: playbackIntent
                )
                guard self.commandStillOwnsPlayback(playbackIntent) else { return .ignored }
                return .result("Playing top songs")
            }
            return await self.playSearchResult(
                query: query,
                description: description,
                playbackIntent: playbackIntent
            )

        case .search:
            return await self.playSearchResult(
                query: query,
                description: description,
                playbackIntent: playbackIntent
            )
        }
    }

    private func queueContent(
        intent: MusicIntent,
        query: String,
        description: String,
        source: ContentSource,
        ownership: QueueCommandOwnership
    ) async -> Outcome {
        switch source {
        case .moodsAndGenres:
            if let songs = await self.findSongsFromMoodsAndGenres(intent: intent) {
                guard self.commandStillOwnsQueue(ownership) else { return .ignored }
                if self.playerService.queue.isEmpty {
                    guard let playbackIntent = ownership.playbackIntent else { return .ignored }
                    await self.playerService.playQueue(
                        songs,
                        startingAt: 0,
                        deferringSmartShuffleFill: false,
                        intent: playbackIntent
                    )
                    guard self.commandStillOwnsPlayback(playbackIntent) else { return .ignored }
                    return .result("Playing \(description.isEmpty ? "curated playlist" : description)")
                }

                self.playerService.appendToQueue(songs)
                return .result("Added \(description.isEmpty ? "curated songs" : description) to queue")
            }

            return await self.queueSearchResult(
                query: query,
                description: description,
                ownership: ownership
            )

        case .charts:
            if let songs = await self.findSongsFromCharts() {
                guard self.commandStillOwnsQueue(ownership) else { return .ignored }
                if self.playerService.queue.isEmpty {
                    guard let playbackIntent = ownership.playbackIntent else { return .ignored }
                    await self.playerService.playQueue(
                        songs,
                        startingAt: 0,
                        deferringSmartShuffleFill: false,
                        intent: playbackIntent
                    )
                    guard self.commandStillOwnsPlayback(playbackIntent) else { return .ignored }
                    return .result("Playing top songs")
                }

                self.playerService.appendToQueue(songs)
                return .result("Added top songs to queue")
            }

            return await self.queueSearchResult(
                query: query,
                description: description,
                ownership: ownership
            )

        case .search:
            return await self.queueSearchResult(
                query: query,
                description: description,
                ownership: ownership
            )
        }
    }

    private func findSongsFromMoodsAndGenres(intent: MusicIntent) async -> [Song]? {
        do {
            let response = try await self.client.getMoodsAndGenres()
            let searchTerms = self.buildSearchTerms(from: intent)
            self.logger.info("Searching Moods & Genres with terms: \(searchTerms)")

            for section in response.sections {
                if self.matchesSearchTerms(section.title, searchTerms) {
                    if let playlistItem = section.items.first(where: { $0.playlist != nil }),
                       let playlist = playlistItem.playlist
                    {
                        return try await self.fetchPlaylistSongs(playlistId: playlist.id)
                    }

                    let songs = section.items.compactMap { item -> Song? in
                        if case let .song(song) = item {
                            return song
                        }
                        return nil
                    }
                    if !songs.isEmpty {
                        return Array(songs.prefix(25))
                    }
                }

                for item in section.items where self.matchesSearchTerms(item.title, searchTerms) {
                    if let playlist = item.playlist {
                        return try await self.fetchPlaylistSongs(playlistId: playlist.id)
                    }
                }
            }

            self.logger.info("No matching Moods & Genres content found")
            return nil
        } catch {
            self.logger.error("Failed to fetch Moods & Genres: \(error.localizedDescription)")
            return nil
        }
    }

    private func findSongsFromCharts() async -> [Song]? {
        do {
            let response = try await self.client.getCharts()

            for section in response.sections {
                let songs = section.items.compactMap { item -> Song? in
                    if case let .song(song) = item {
                        return song
                    }
                    return nil
                }
                if songs.count >= 5 {
                    return Array(songs.prefix(25))
                }
            }

            return nil
        } catch {
            self.logger.error("Failed to fetch Charts: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchPlaylistSongs(playlistId: String) async throws -> [Song] {
        let response = try await self.client.getPlaylist(id: playlistId)
        return Array(response.detail.tracks.prefix(25))
    }

    private func buildSearchTerms(from intent: MusicIntent) -> [String] {
        var terms: [String] = []

        if !intent.mood.isEmpty {
            let mood = intent.mood.lowercased()
            terms.append(mood)
            terms.append(contentsOf: self.moodSynonyms(for: mood))
        }
        if !intent.genre.isEmpty {
            terms.append(intent.genre.lowercased())
        }
        if !intent.activity.isEmpty {
            terms.append(intent.activity.lowercased())
        }
        if !intent.query.isEmpty {
            terms.append(contentsOf: intent.query.lowercased().split(separator: " ").map { String($0) })
        }

        return terms
    }

    private func moodSynonyms(for mood: String) -> [String] {
        switch mood {
        case "chill", "relaxing", "calm":
            ["chill", "relax", "calm", "peaceful", "ambient", "lo-fi", "lofi", "mellow"]
        case "energetic", "upbeat", "happy":
            ["energy", "upbeat", "happy", "pump", "hype", "workout", "party"]
        case "sad", "melancholic":
            ["sad", "melancholy", "heartbreak", "emotional", "moody"]
        case "focus", "study":
            ["focus", "study", "concentrate", "work", "productivity"]
        case "romantic", "love":
            ["romance", "romantic", "love", "date"]
        case "sleep", "bedtime":
            ["sleep", "bedtime", "night", "ambient", "calm"]
        default:
            []
        }
    }

    private func matchesSearchTerms(_ title: String, _ terms: [String]) -> Bool {
        let titleLower = title.lowercased()
        return terms.contains { titleLower.contains($0) }
    }
}
