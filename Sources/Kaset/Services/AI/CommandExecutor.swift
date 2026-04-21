import Foundation

@available(macOS 26.0, *)
@MainActor
struct CommandExecutor {
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
    }

    let client: any YTMusicClientProtocol
    let playerService: any PlayerServiceProtocol

    private let logger = DiagnosticsLogger.ai

    func execute(_ request: Request) async -> Outcome {
        switch request {
        case .pause:
            HapticService.playback()
            await self.playerService.pause()
            return .result("Paused")

        case .resume:
            HapticService.playback()
            await self.playerService.resume()
            return .result("Playing")

        case .skip:
            HapticService.playback()
            await self.playerService.next()
            return .result("Skipped")

        case .previous:
            HapticService.playback()
            await self.playerService.previous()
            return .result("Playing previous track")

        case .like:
            HapticService.toggle()
            self.playerService.likeCurrentTrack()
            return .result("Liked!")

        case .dislike:
            HapticService.toggle()
            self.playerService.dislikeCurrentTrack()
            return .result("Disliked")

        case .clearQueue:
            HapticService.toggle()
            self.playerService.clearQueue()
            return .result("Queue cleared")

        case .shuffleQueue:
            HapticService.toggle()
            self.playerService.shuffleQueue()
            return .result("Queue shuffled")

        case .toggleShuffle:
            HapticService.toggle()
            self.playerService.toggleShuffle()
            let status = self.playerService.shuffleEnabled ? "on" : "off"
            return .result("Shuffle is now \(status)")

        case let .playSearch(query, description):
            return await self.playSearchResult(query: query, description: description)

        case let .queueSearch(query, description):
            return await self.queueSearchResult(query: query, description: description)

        case let .openSearch(query):
            return .openSearch(query)

        case let .musicIntent(intent):
            return await self.executeMusicIntent(intent)
        }
    }

    func describeQueueLocally(previewLimit: Int = 3) -> Outcome {
        let queue = self.playerService.queue

        guard !queue.isEmpty else {
            return .result("Your queue is empty.", shouldDismiss: false)
        }

        let safeCurrentIndex = min(max(self.playerService.currentIndex, 0), queue.count - 1)
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

    private func executeMusicIntent(_ intent: MusicIntent) async -> Outcome {
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
            return await self.playContent(intent: intent, query: searchQuery, description: description, source: contentSource)

        case .queue:
            HapticService.success()
            if !searchQuery.isEmpty {
                return await self.queueContent(intent: intent, query: searchQuery, description: description, source: contentSource)
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

    private func playSearchResult(query: String, description: String = "") async -> Outcome {
        do {
            let allSongs = try await self.client.searchSongs(query: query)
            let songs = Array(allSongs.prefix(20))

            self.logger.info("Songs search returned \(allSongs.count), using top \(songs.count) for query: \(query)")
            if let firstSong = songs.first {
                await self.playerService.playQueue(songs, startingAt: 0)
                self.logger.info("Started queue with \(songs.count) songs, first: \(firstSong.title)")
                if !description.isEmpty {
                    return .result("Playing \(description)")
                }
                return .result("Playing \"\(firstSong.title)\"")
            }
            return .error("No songs found for \"\(query)\"")
        } catch {
            self.logger.error("Search failed: \(error.localizedDescription)")
            return .error(String(localized: "Couldn't search for music"))
        }
    }

    private func queueSearchResult(query: String, description: String = "") async -> Outcome {
        do {
            let allSongs = try await self.client.searchSongs(query: query)
            let songs = Array(allSongs.prefix(10))

            self.logger.info("Queue songs search returned \(allSongs.count), using top \(songs.count) for query: \(query)")
            if let firstSong = songs.first {
                if self.playerService.queue.isEmpty {
                    await self.playerService.playQueue(songs, startingAt: 0)
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
            self.logger.error("Search failed: \(error.localizedDescription)")
            return .error(String(localized: "Couldn't search for music"))
        }
    }

    private func playContent(
        intent: MusicIntent,
        query: String,
        description: String,
        source: ContentSource
    ) async -> Outcome {
        switch source {
        case .moodsAndGenres:
            if let songs = await self.findSongsFromMoodsAndGenres(intent: intent) {
                await self.playerService.playQueue(songs, startingAt: 0)
                return .result("Playing \(description.isEmpty ? "curated playlist" : description)")
            }

            self.logger.info("No matching Moods & Genres playlist, falling back to search")
            return await self.playSearchResult(query: query, description: description)

        case .charts:
            if let songs = await self.findSongsFromCharts() {
                await self.playerService.playQueue(songs, startingAt: 0)
                return .result("Playing top songs")
            }
            return await self.playSearchResult(query: query, description: description)

        case .search:
            return await self.playSearchResult(query: query, description: description)
        }
    }

    private func queueContent(
        intent: MusicIntent,
        query: String,
        description: String,
        source: ContentSource
    ) async -> Outcome {
        switch source {
        case .moodsAndGenres:
            if let songs = await self.findSongsFromMoodsAndGenres(intent: intent) {
                if self.playerService.queue.isEmpty {
                    await self.playerService.playQueue(songs, startingAt: 0)
                    return .result("Playing \(description.isEmpty ? "curated playlist" : description)")
                }

                self.playerService.appendToQueue(songs)
                return .result("Added \(description.isEmpty ? "curated songs" : description) to queue")
            }

            return await self.queueSearchResult(query: query, description: description)

        case .charts:
            if let songs = await self.findSongsFromCharts() {
                if self.playerService.queue.isEmpty {
                    await self.playerService.playQueue(songs, startingAt: 0)
                    return .result("Playing top songs")
                }

                self.playerService.appendToQueue(songs)
                return .result("Added top songs to queue")
            }

            return await self.queueSearchResult(query: query, description: description)

        case .search:
            return await self.queueSearchResult(query: query, description: description)
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
                        if case let .song(song) = item { return song }
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
                    if case let .song(song) = item { return song }
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
