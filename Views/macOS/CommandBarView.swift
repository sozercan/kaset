import FoundationModels
import SwiftUI

// MARK: - CommandBarView

/// A floating command bar for natural language music control.
/// Accessible via Cmd+K, allows users to control playback with voice-like commands.
@available(macOS 26.0, *)
struct CommandBarView: View {
    @Environment(PlayerService.self) private var playerService

    /// The YTMusicClient for search operations.
    let client: any YTMusicClientProtocol

    /// Binding to control visibility (used for dismiss).
    @Binding var isPresented: Bool

    /// The user's input text.
    @State private var inputText = ""

    /// Whether the AI is processing the command.
    @State private var isProcessing = false

    /// Error message to display, if any.
    @State private var errorMessage: String?

    /// Result message after successful command.
    @State private var resultMessage: String?

    /// Focus state for the text field.
    @FocusState private var isInputFocused: Bool

    private let logger = DiagnosticsLogger.ai

    /// Dismisses the command bar.
    private func dismissCommandBar() {
        self.isPresented = false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Input field
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundStyle(.tint)

                TextField("Ask anything about music...", text: self.$inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused(self.$isInputFocused)
                    .onSubmit {
                        Task {
                            await self.processCommand()
                        }
                    }
                    .disabled(self.isProcessing)

                if self.isProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if !self.inputText.isEmpty {
                    Button {
                        self.inputText = ""
                        self.errorMessage = nil
                        self.resultMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            // Status area
            if let error = errorMessage {
                self.errorView(error)
            } else if let result = resultMessage {
                self.resultView(result)
            } else {
                self.suggestionsView
            }
        }
        .frame(width: 500)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onAppear {
            self.isInputFocused = true
        }
        .onExitCommand {
            self.dismissCommandBar()
        }
    }

    // MARK: - Subviews

    private func errorView(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(error)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Search instead") {
                self.fallbackToSearch()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
    }

    private func resultView(_ result: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)

            Text(result)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer()
        }
        .padding(12)
    }

    private var suggestionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try commands like:")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                SuggestionChip(text: "Play something chill") {
                    self.executeSuggestion("Play something chill")
                }

                SuggestionChip(text: "Add jazz to queue") {
                    self.executeSuggestion("Add jazz to queue")
                }

                SuggestionChip(text: "Shuffle my queue") {
                    self.executeSuggestion("Shuffle my queue")
                }
            }

            HStack(spacing: 8) {
                SuggestionChip(text: "Skip this song") {
                    self.executeSuggestion("Skip this song")
                }

                SuggestionChip(text: "I like this") {
                    self.executeSuggestion("I like this")
                }

                SuggestionChip(text: "Clear queue") {
                    self.executeSuggestion("Clear queue")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    /// Executes a suggestion command immediately.
    private func executeSuggestion(_ command: String) {
        self.inputText = command
        Task {
            await self.processCommand()
        }
    }

    /// System instructions for the AI session.
    private var aiSystemInstructions: String {
        """
        You are a music assistant for the Kaset app. Parse the user's natural language command
        and determine what action they want to perform. Return a MusicIntent with:
        1. The action (play, queue, shuffle, like, skip, pause, etc.)
        2. Parsed query components (artist, genre, mood, era, version, activity)
        3. The full original query (IMPORTANT: preserve keywords like "hits", "greatest", "best of")

        PARSE NATURAL LANGUAGE INTO STRUCTURED COMPONENTS:

        Example: "rolling stones 90s hits"
        → action: play, query: "rolling stones 90s hits", artist: "Rolling Stones", era: "1990s"

        Example: "upbeat rolling stones songs from the 90s"
        → action: play, query: "upbeat rolling stones songs", artist: "Rolling Stones", mood: "upbeat", era: "1990s"

        Example: "chill jazz for studying"
        → action: play, query: "chill jazz for studying", genre: "jazz", mood: "chill", activity: "study"

        Example: "acoustic covers of pop hits"
        → action: play, query: "acoustic covers of pop hits", genre: "pop", version: "acoustic cover"

        Example: "80s synthwave"
        → action: play, query: "80s synthwave", genre: "synthwave", era: "1980s"

        Example: "add some energetic workout music to queue"
        → action: queue, query: "energetic workout music", mood: "energetic", activity: "workout"

        Example: "best of queen"
        → action: play, query: "best of queen", artist: "Queen"

        COMPONENT EXTRACTION RULES:
        - query: ALWAYS include the full natural language request (minus action words)
        - artist: Extract artist name if mentioned ("Beatles", "Taylor Swift", "Rolling Stones")
        - genre: rock, pop, jazz, classical, hip-hop, r&b, electronic, country, folk, metal, indie, latin, k-pop
        - mood: upbeat, chill, sad, happy, energetic, relaxing, melancholic, romantic, aggressive, peaceful, groovy
        - era: Use decade format (1960s, 1970s, 1980s, 1990s, 2000s, 2010s, 2020s) or "classic"
        - version: acoustic, live, remix, instrumental, cover, unplugged, remastered
        - activity: workout, study, sleep, party, driving, cooking, focus, running, yoga

        For simple commands: skip/next → skip, pause/stop → pause, play/resume → resume,
        shuffle my queue → shuffle (shuffleScope: queue), like this → like, clear queue → queue (query: "__clear__")
        """
    }

    private func processCommand() async {
        let query = self.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        self.isProcessing = true
        self.errorMessage = nil
        self.resultMessage = nil

        self.logger.info("Processing command: \(query)")

        guard FoundationModelsService.shared.isAvailable else {
            self.errorMessage = "Apple Intelligence is not available"
            self.isProcessing = false
            return
        }

        let searchTool = MusicSearchTool(client: self.client)
        let queueTool = QueueTool(playerService: self.playerService)

        guard let session = FoundationModelsService.shared.createCommandSession(
            instructions: self.aiSystemInstructions,
            tools: [searchTool, queueTool]
        ) else {
            self.errorMessage = "Could not create AI session"
            self.isProcessing = false
            return
        }

        do {
            let response = try await session.respond(to: query, generating: MusicIntent.self)
            await self.executeIntent(response.content)
        } catch {
            // Check if this is a deserialization/generation error
            let errorDescription = String(describing: error)
            let isDeserializationError = errorDescription.contains("deserialize") ||
                errorDescription.contains("Generable") ||
                errorDescription.contains("generation")

            if isDeserializationError {
                // Fallback: use the query directly as a search
                self.logger.info("AI generation failed, falling back to direct search for: \(query)")
                await self.fallbackDirectSearch(query: query)
            } else if let message = AIErrorHandler.handleAndMessage(error, context: "command processing") {
                // Use centralized error handler for other errors
                self.errorMessage = message
            } else {
                // Cancelled - no message needed
                self.logger.info("Command processing cancelled")
            }
        }

        self.isProcessing = false
    }

    /// Fallback to direct search when AI parsing fails.
    private func fallbackDirectSearch(query: String) async {
        // Extract action keyword and clean query
        let lowered = query.lowercased()
        let cleanQuery: String

        if lowered.hasPrefix("play ") {
            cleanQuery = String(query.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        } else if lowered.hasPrefix("add ") {
            cleanQuery = String(query.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            // Handle "add X to queue" pattern
            if let range = cleanQuery.lowercased().range(of: " to queue") {
                let extracted = String(cleanQuery[..<range.lowerBound])
                await self.queueSearchResult(query: extracted, description: extracted)
                return
            }
        } else if lowered.contains("shuffle") {
            if lowered.contains("queue") {
                self.playerService.shuffleQueue()
                self.resultMessage = "Queue shuffled"
            } else {
                self.playerService.toggleShuffle()
                let status = self.playerService.shuffleEnabled ? "on" : "off"
                self.resultMessage = "Shuffle is now \(status)"
            }
            try? await Task.sleep(for: .seconds(1))
            self.dismissCommandBar()
            return
        } else if lowered.contains("skip") || lowered.contains("next") {
            await self.playerService.next()
            self.resultMessage = "Skipped"
            try? await Task.sleep(for: .seconds(1))
            self.dismissCommandBar()
            return
        } else if lowered.contains("like") {
            self.playerService.likeCurrentTrack()
            self.resultMessage = "Liked!"
            try? await Task.sleep(for: .seconds(1))
            self.dismissCommandBar()
            return
        } else if lowered.contains("clear"), lowered.contains("queue") {
            self.playerService.clearQueue()
            self.resultMessage = "Queue cleared"
            try? await Task.sleep(for: .seconds(1))
            self.dismissCommandBar()
            return
        } else {
            cleanQuery = query
        }

        // Default to play action with search
        await self.playSearchResult(query: cleanQuery, description: cleanQuery)
        if self.resultMessage != nil {
            try? await Task.sleep(for: .seconds(1))
            self.dismissCommandBar()
        }
    }

    private func executeIntent(_ intent: MusicIntent) async {
        // Build the search query from parsed components
        let searchQuery = intent.buildSearchQuery()
        let description = intent.queryDescription()
        let contentSource = intent.suggestedContentSource()

        self.logger.info("Executing intent: \(intent.action.rawValue)")
        self.logger.info("  Raw query: \(intent.query)")
        self.logger.info("  Artist: \(intent.artist), Genre: \(intent.genre), Mood: \(intent.mood)")
        self.logger.info("  Era: \(intent.era), Version: \(intent.version), Activity: \(intent.activity)")
        self.logger.info("  Built search query: \(searchQuery)")
        self.logger.info("  Content source: \(contentSource)")

        switch intent.action {
        case .play:
            if searchQuery.isEmpty, intent.query.isEmpty {
                await self.playerService.resume()
                self.resultMessage = "Resuming playback"
            } else {
                await self.playContent(intent: intent, query: searchQuery, description: description, source: contentSource)
            }

        case .queue:
            if intent.query == "__clear__" {
                self.playerService.clearQueue()
                self.resultMessage = "Queue cleared"
            } else if !searchQuery.isEmpty {
                await self.queueContent(intent: intent, query: searchQuery, description: description, source: contentSource)
            }

        case .shuffle:
            if intent.shuffleScope == "queue" {
                self.playerService.shuffleQueue()
                self.resultMessage = "Queue shuffled"
            } else {
                self.playerService.toggleShuffle()
                let status = self.playerService.shuffleEnabled ? "on" : "off"
                self.resultMessage = "Shuffle is now \(status)"
            }

        case .like:
            self.playerService.likeCurrentTrack()
            self.resultMessage = "Liked!"

        case .dislike:
            self.playerService.dislikeCurrentTrack()
            self.resultMessage = "Disliked"

        case .skip:
            await self.playerService.next()
            self.resultMessage = "Skipped"

        case .previous:
            await self.playerService.previous()
            self.resultMessage = "Playing previous track"

        case .pause:
            await self.playerService.pause()
            self.resultMessage = "Paused"

        case .resume:
            await self.playerService.resume()
            self.resultMessage = "Playing"

        case .search:
            // Switch to search view with the query
            self.fallbackToSearch()
        }

        // Auto-dismiss after successful action (except search)
        if intent.action != .search, self.resultMessage != nil {
            try? await Task.sleep(for: .seconds(1))
            self.dismissCommandBar()
        }
    }

    private func playSearchResult(query: String, description: String = "") async {
        do {
            // Use songs-only filtered search to exclude podcasts/videos
            let allSongs = try await client.searchSongs(query: query)
            let songs = Array(allSongs.prefix(20))

            self.logger.info("Songs search returned \(allSongs.count), using top \(songs.count) for query: \(query)")
            if let firstSong = songs.first {
                // Use playQueue to populate the queue with search results
                await self.playerService.playQueue(songs, startingAt: 0)
                self.logger.info("Started queue with \(songs.count) songs, first: \(firstSong.title)")
                // Use description if available for nicer feedback
                if !description.isEmpty {
                    self.resultMessage = "Playing \(description)"
                } else {
                    self.resultMessage = "Playing \"\(firstSong.title)\""
                }
            } else {
                self.errorMessage = "No songs found for \"\(query)\""
            }
        } catch {
            self.logger.error("Search failed: \(error.localizedDescription)")
            self.errorMessage = "Couldn't search for music"
        }
    }

    private func queueSearchResult(query: String, description: String = "") async {
        do {
            // Use songs-only filtered search to exclude podcasts/videos
            let allSongs = try await client.searchSongs(query: query)
            let songs = Array(allSongs.prefix(10))

            self.logger.info("Queue songs search returned \(allSongs.count), using top \(songs.count) for query: \(query)")
            if !songs.isEmpty {
                if self.playerService.queue.isEmpty {
                    // No queue exists, create one with the search results
                    await self.playerService.playQueue(songs, startingAt: 0)
                    if !description.isEmpty {
                        self.resultMessage = "Playing \(description)"
                    } else {
                        self.resultMessage = "Playing \"\(songs.first!.title)\" and \(songs.count - 1) more"
                    }
                } else {
                    // Add all songs to existing queue
                    self.playerService.appendToQueue(songs)
                    if !description.isEmpty {
                        self.resultMessage = "Added \(description) to queue"
                    } else {
                        self.resultMessage = "Added \(songs.count) songs to queue"
                    }
                }
            } else {
                self.errorMessage = "No songs found for \"\(query)\""
            }
        } catch {
            self.logger.error("Search failed: \(error.localizedDescription)")
            self.errorMessage = "Couldn't search for music"
        }
    }

    private func fallbackToSearch() {
        // Dismiss and trigger search view navigation
        // This would need to be wired up to the navigation system
        self.dismissCommandBar()
    }

    // MARK: - Content Routing

    /// Plays content from the best source based on the intent.
    private func playContent(intent: MusicIntent, query: String, description: String, source: ContentSource) async {
        switch source {
        case .moodsAndGenres:
            // Try to find matching playlist from Moods & Genres
            if let songs = await self.findSongsFromMoodsAndGenres(intent: intent) {
                await self.playerService.playQueue(songs, startingAt: 0)
                self.resultMessage = "Playing \(description.isEmpty ? "curated playlist" : description)"
            } else {
                // Fallback to search
                self.logger.info("No matching Moods & Genres playlist, falling back to search")
                await self.playSearchResult(query: query, description: description)
            }

        case .charts:
            // Try to get songs from Charts
            if let songs = await self.findSongsFromCharts() {
                await self.playerService.playQueue(songs, startingAt: 0)
                self.resultMessage = "Playing top songs"
            } else {
                // Fallback to search
                await self.playSearchResult(query: query, description: description)
            }

        case .search:
            await self.playSearchResult(query: query, description: description)
        }
    }

    /// Queues content from the best source based on the intent.
    private func queueContent(intent: MusicIntent, query: String, description: String, source: ContentSource) async {
        switch source {
        case .moodsAndGenres:
            if let songs = await self.findSongsFromMoodsAndGenres(intent: intent) {
                if self.playerService.queue.isEmpty {
                    await self.playerService.playQueue(songs, startingAt: 0)
                    self.resultMessage = "Playing \(description.isEmpty ? "curated playlist" : description)"
                } else {
                    self.playerService.appendToQueue(songs)
                    self.resultMessage = "Added \(description.isEmpty ? "curated songs" : description) to queue"
                }
            } else {
                await self.queueSearchResult(query: query, description: description)
            }

        case .charts:
            if let songs = await self.findSongsFromCharts() {
                if self.playerService.queue.isEmpty {
                    await self.playerService.playQueue(songs, startingAt: 0)
                    self.resultMessage = "Playing top songs"
                } else {
                    self.playerService.appendToQueue(songs)
                    self.resultMessage = "Added top songs to queue"
                }
            } else {
                await self.queueSearchResult(query: query, description: description)
            }

        case .search:
            await self.queueSearchResult(query: query, description: description)
        }
    }

    /// Finds songs from Moods & Genres that match the intent.
    private func findSongsFromMoodsAndGenres(intent: MusicIntent) async -> [Song]? {
        do {
            let response = try await client.getMoodsAndGenres()

            // Build search terms from intent
            let searchTerms = self.buildSearchTerms(from: intent)
            self.logger.info("Searching Moods & Genres with terms: \(searchTerms)")

            // Find matching section/playlist
            for section in response.sections {
                // Check section title match
                if self.matchesSearchTerms(section.title, searchTerms) {
                    // Found matching section, get first playlist
                    if let playlistItem = section.items.first(where: { $0.playlist != nil }),
                       let playlist = playlistItem.playlist
                    {
                        return try await self.fetchPlaylistSongs(playlistId: playlist.id)
                    }
                    // If section has songs directly, use those
                    let songs = section.items.compactMap { item -> Song? in
                        if case let .song(song) = item { return song }
                        return nil
                    }
                    if !songs.isEmpty {
                        return Array(songs.prefix(25))
                    }
                }

                // Check individual items for matches
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

    /// Finds top songs from Charts.
    private func findSongsFromCharts() async -> [Song]? {
        do {
            let response = try await client.getCharts()

            // Look for song sections in charts
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

    /// Fetches songs from a playlist by ID.
    private func fetchPlaylistSongs(playlistId: String) async throws -> [Song] {
        let detail = try await client.getPlaylist(id: playlistId)
        return Array(detail.tracks.prefix(25))
    }

    /// Builds search terms from intent components, including mood synonyms.
    private func buildSearchTerms(from intent: MusicIntent) -> [String] {
        var terms: [String] = []

        if !intent.mood.isEmpty {
            let mood = intent.mood.lowercased()
            terms.append(mood)
            // Add synonyms for common moods to improve Moods & Genres matching
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

    /// Returns synonyms for common moods to improve playlist matching.
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

    /// Checks if a title matches any of the search terms.
    private func matchesSearchTerms(_ title: String, _ terms: [String]) -> Bool {
        let titleLower = title.lowercased()
        return terms.contains { titleLower.contains($0) }
    }
}

// MARK: - SuggestionChip

@available(macOS 26.0, *)
private struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            Text(self.text)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    @Previewable @State var isPresented = true
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    CommandBarView(client: client, isPresented: $isPresented)
        .environment(PlayerService())
        .padding(40)
        .frame(width: 600, height: 300)
}
