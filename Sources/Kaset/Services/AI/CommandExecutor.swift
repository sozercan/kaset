import Foundation

@available(macOS 26.0, *)
@MainActor
struct CommandExecutor {
    private enum ResolvableContentKey: Hashable {
        case moodCategory(MoodCategoryEndpoint)
        case playlist(String)
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
        case musicIntent(MusicIntent, originalQuery: String)
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

        case let .musicIntent(intent, originalQuery):
            return await self.executeMusicIntent(intent, originalQuery: originalQuery)
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

    private func executeMusicIntent(_ intent: MusicIntent, originalQuery: String) async -> Outcome {
        let intent = ContentSourceResolver.groundedIntent(intent, groundingQuery: originalQuery)
        let searchQuery = ContentSourceResolver.buildSearchQuery(from: intent, groundingQuery: originalQuery)
        let description = ContentSourceResolver.queryDescription(for: intent, groundingQuery: originalQuery)
        let contentSource = ContentSourceResolver.suggestedContentSource(for: intent, groundingQuery: originalQuery)

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
            let queryToOpen = CommandIntentParser.explicitSearchQuery(from: originalQuery) ?? fallbackQuery
            return .openSearch(queryToOpen.trimmingCharacters(in: .whitespacesAndNewlines))
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
            if let songs = await self.findSongsFromMoodsAndGenres(intent: intent), !songs.isEmpty {
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
            if let songs = await self.findSongsFromMoodsAndGenres(intent: intent), !songs.isEmpty {
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

            let exactCandidates = self.exactMatchingPlaylists(in: response, matching: searchTerms)
            if let songs = try await self.firstResolvedSongs(
                from: exactCandidates,
                searchTerms: searchTerms,
                visitedCategories: []
            ) {
                return songs
            }

            let directSongs = self.rankedSongs(in: response, matching: searchTerms)
            if !directSongs.isEmpty {
                return Array(directSongs.prefix(25))
            }

            let exactKeys = Set(exactCandidates.map(self.resolvableContentKey))
            let remainingCandidates = self.rankedPlaylists(
                in: response,
                matching: searchTerms,
                includeFallback: false
            ).filter { !exactKeys.contains(self.resolvableContentKey($0)) }
            return try await self.firstResolvedSongs(
                from: remainingCandidates,
                searchTerms: searchTerms,
                visitedCategories: []
            )
        } catch {
            self.logger.error("Failed to fetch Moods & Genres: \(error.localizedDescription)")
            return nil
        }
    }

    private func resolveSongs(
        from playlist: Playlist,
        searchTerms: [String],
        visitedCategories: Set<MoodCategoryEndpoint>
    ) async throws -> [Song]? {
        // Mood/genre landing cards are represented as Playlist values for shared UI,
        // but their IDs encode a category browse request rather than playlist tracks.
        if let category = playlist.resolvedMoodCategoryEndpoint {
            guard !visitedCategories.contains(category) else {
                self.logger.warning("Skipping cyclic mood category: \(playlist.title)")
                return nil
            }

            var visitedCategories = visitedCategories
            visitedCategories.insert(category)
            let response = try await self.client.getMoodCategory(
                browseId: category.browseId,
                params: category.params
            )
            return try await self.resolveSongs(
                fromMoodCategory: response,
                searchTerms: searchTerms,
                visitedCategories: visitedCategories
            )
        }

        return try await self.fetchNonEmptyPlaylistSongs(playlistId: playlist.id)
    }

    private func resolveSongs(
        fromMoodCategory response: HomeResponse,
        searchTerms: [String],
        visitedCategories: Set<MoodCategoryEndpoint>
    ) async throws -> [Song]? {
        var seenVideoIds: Set<String> = []
        let directSongs = response.sections.flatMap { section in
            section.items.compactMap { item -> Song? in
                if case let .song(song) = item,
                   seenVideoIds.insert(song.videoId).inserted
                {
                    return song
                }
                return nil
            }
        }
        if !directSongs.isEmpty {
            return Array(directSongs.prefix(25))
        }

        let candidates = self.rankedPlaylists(
            in: response,
            matching: searchTerms,
            includeFallback: true
        )
        return try await self.firstResolvedSongs(
            from: candidates,
            searchTerms: searchTerms,
            visitedCategories: visitedCategories
        )
    }

    private func firstResolvedSongs(
        from playlists: [Playlist],
        searchTerms: [String],
        visitedCategories: Set<MoodCategoryEndpoint>
    ) async throws -> [Song]? {
        for playlist in playlists {
            if let songs = try await self.resolveSongs(
                from: playlist,
                searchTerms: searchTerms,
                visitedCategories: visitedCategories
            ) {
                return songs
            }
        }
        return nil
    }

    private func resolvableContentKey(_ playlist: Playlist) -> ResolvableContentKey {
        if let category = playlist.resolvedMoodCategoryEndpoint {
            return .moodCategory(category)
        }
        return .playlist(playlist.id)
    }

    private func rankedSongs(in response: HomeResponse, matching searchTerms: [String]) -> [Song] {
        var result: [Song] = []
        var seenVideoIds: Set<String> = []

        func append(_ songs: [Song]) {
            for song in songs where seenVideoIds.insert(song.videoId).inserted {
                result.append(song)
            }
        }

        for term in searchTerms {
            for section in response.sections where self.exactlyMatchesSearchTerm(section.title, [term]) {
                append(section.items.compactMap { item -> Song? in
                    guard case let .song(song) = item else { return nil }
                    return song
                })
            }
        }
        for term in searchTerms {
            for section in response.sections where self.matchesSearchTerms(section.title, [term]) {
                append(section.items.compactMap { item -> Song? in
                    guard case let .song(song) = item else { return nil }
                    return song
                })
            }
        }
        return result
    }

    private func exactMatchingPlaylists(in response: HomeResponse, matching searchTerms: [String]) -> [Playlist] {
        var result: [Playlist] = []
        var seenKeys: Set<ResolvableContentKey> = []

        func append(_ playlists: [Playlist]) {
            for playlist in playlists where seenKeys.insert(self.resolvableContentKey(playlist)).inserted {
                result.append(playlist)
            }
        }

        for term in searchTerms {
            for section in response.sections {
                append(section.items.compactMap(\.playlist).filter {
                    self.exactlyMatchesSearchTerm($0.title, [term])
                })
            }
        }
        for term in searchTerms {
            for section in response.sections where self.exactlyMatchesSearchTerm(section.title, [term]) {
                append(section.items.compactMap(\.playlist))
            }
        }

        return result
    }

    private func rankedPlaylists(
        in response: HomeResponse,
        matching searchTerms: [String],
        includeFallback: Bool
    ) -> [Playlist] {
        var result: [Playlist] = []
        var seenKeys: Set<ResolvableContentKey> = []

        func append(_ playlists: [Playlist]) {
            for playlist in playlists where seenKeys.insert(self.resolvableContentKey(playlist)).inserted {
                result.append(playlist)
            }
        }

        for term in searchTerms {
            for section in response.sections {
                append(section.items.compactMap(\.playlist).filter {
                    self.exactlyMatchesSearchTerm($0.title, [term])
                })
            }
        }
        for term in searchTerms {
            for section in response.sections where self.exactlyMatchesSearchTerm(section.title, [term]) {
                append(section.items.compactMap(\.playlist))
            }
        }
        for term in searchTerms {
            for section in response.sections {
                append(section.items.compactMap(\.playlist).filter {
                    self.matchesSearchTerms($0.title, [term])
                })
            }
        }
        for term in searchTerms {
            for section in response.sections where self.matchesSearchTerms(section.title, [term]) {
                append(section.items.compactMap(\.playlist))
            }
        }
        if includeFallback {
            append(response.sections.flatMap { $0.items.compactMap(\.playlist) })
        }

        return result
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

    private func fetchNonEmptyPlaylistSongs(playlistId: String) async throws -> [Song]? {
        let songs = try await self.fetchPlaylistSongs(playlistId: playlistId)
        return songs.isEmpty ? nil : songs
    }

    private func buildSearchTerms(from intent: MusicIntent) -> [String] {
        var terms: [String] = []

        if !intent.mood.isEmpty {
            let mood = intent.mood.lowercased()
            terms.append(mood)
            terms.append(contentsOf: MusicDiscoveryTaxonomy.moodAliases(for: mood))
        } else if !intent.genre.isEmpty {
            let genre = intent.genre.lowercased()
            terms.append(genre)
            terms.append(contentsOf: MusicDiscoveryTaxonomy.genreAliases(for: genre))
        } else if !intent.activity.isEmpty {
            terms.append(intent.activity.lowercased())
            terms.append(contentsOf: self.activitySynonyms(for: intent.activity.lowercased()))
        }
        if !intent.query.isEmpty {
            let genericTerms: Set = [
                "a", "add", "an", "anything", "for", "me", "music", "play", "please",
                "queue", "some", "something", "song", "songs", "the", "to", "track", "tracks",
            ]
            terms.append(contentsOf: intent.query.lowercased().split(separator: " ").compactMap { word in
                let term = String(word)
                return genericTerms.contains(term) ? nil : term
            })
        }

        var seen: Set<String> = []
        return terms.filter { term in
            !self.normalizedDiscoveryText(term).isEmpty && seen.insert(term).inserted
        }
    }

    private func activitySynonyms(for activity: String) -> [String] {
        switch activity {
        case "run", "running":
            ["running", "workout"]
        case "study", "studying":
            ["study", "focus"]
        case "drive", "driving":
            ["driving", "commute"]
        case "sleep", "sleeping":
            ["sleep", "bedtime"]
        default:
            []
        }
    }

    private func exactlyMatchesSearchTerm(_ title: String, _ terms: [String]) -> Bool {
        let normalizedTitle = self.normalizedDiscoveryText(title)
        return terms.contains { self.normalizedDiscoveryText($0) == normalizedTitle }
    }

    private func matchesSearchTerms(_ title: String, _ terms: [String]) -> Bool {
        let normalizedTitle = self.normalizedDiscoveryText(title)
        return terms.contains { term in
            let normalizedTerm = self.normalizedDiscoveryText(term)
            return !normalizedTerm.isEmpty && normalizedTitle.contains(normalizedTerm)
        }
    }

    private func normalizedDiscoveryText(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
