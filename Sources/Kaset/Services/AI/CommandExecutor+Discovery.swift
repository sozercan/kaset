import Foundation

@available(macOS 26.0, *)
extension CommandExecutor {
    private enum ResolvableContentKey: Hashable {
        case moodCategory(MoodCategoryEndpoint)
        case playlist(String)
    }

    func findSongsFromMoodsAndGenres(
        intent: MusicIntent,
        groundingQuery: String
    ) async -> [Song]? {
        do {
            let response = try await self.client.getMoodsAndGenres()
            let searchTerms = self.buildSearchTerms(from: intent, groundingQuery: groundingQuery)
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

    func findSongsFromCharts() async -> [Song]? {
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

    private func buildSearchTerms(
        from intent: MusicIntent,
        groundingQuery: String
    ) -> [String] {
        var terms: [String] = []
        let semanticTerms: [String]

        if !intent.mood.isEmpty {
            let mood = intent.mood.lowercased()
            semanticTerms = [mood] + MusicDiscoveryTaxonomy.moodAliases(for: mood)
        } else if !intent.genre.isEmpty {
            let genre = intent.genre.lowercased()
            semanticTerms = [genre] + MusicDiscoveryTaxonomy.genreAliases(for: genre)
        } else if !intent.activity.isEmpty {
            let activity = intent.activity.lowercased()
            semanticTerms = [activity] + self.activitySynonyms(for: activity)
        } else {
            semanticTerms = []
        }

        terms.append(contentsOf: semanticTerms.compactMap { term -> (String, Int)? in
            guard let position = self.discoveryPhrasePosition(term, in: groundingQuery) else { return nil }
            return (term, position)
        }.sorted { lhs, rhs in
            lhs.1 < rhs.1
        }.map(\.0))
        terms.append(contentsOf: semanticTerms)

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
            let normalized = self.normalizedDiscoveryText(term)
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }

    private func discoveryPhrasePosition(_ phrase: String, in query: String) -> Int? {
        let queryWords = self.normalizedDiscoveryText(query).split(separator: " ").map(String.init)
        let phraseWords = self.normalizedDiscoveryText(phrase).split(separator: " ").map(String.init)
        guard !phraseWords.isEmpty, phraseWords.count <= queryWords.count else { return nil }

        return (0 ... (queryWords.count - phraseWords.count)).first { start in
            Array(queryWords[start ..< start + phraseWords.count]) == phraseWords
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
