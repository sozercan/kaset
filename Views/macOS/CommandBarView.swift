import FoundationModels
import SwiftUI

// MARK: - CommandBarView

/// A floating command bar for natural language music control.
/// Accessible via Cmd+K, allows users to control playback with voice-like commands.
@available(macOS 26.0, *)
struct CommandBarView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(\.dismiss) private var dismiss

    /// The YTMusicClient for search operations.
    let client: any YTMusicClientProtocol

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
            self.dismiss()
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
                    self.inputText = "Play something chill"
                }

                SuggestionChip(text: "Add jazz to queue") {
                    self.inputText = "Add jazz to queue"
                }

                SuggestionChip(text: "Shuffle my queue") {
                    self.inputText = "Shuffle my queue"
                }
            }

            HStack(spacing: 8) {
                SuggestionChip(text: "Skip this song") {
                    self.inputText = "Skip this song"
                }

                SuggestionChip(text: "I like this") {
                    self.inputText = "I like this"
                }

                SuggestionChip(text: "Clear queue") {
                    self.inputText = "Clear queue"
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

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

        // Create session with search tool for grounded responses
        let instructions = """
        You are a music assistant for the Kaset app. Parse the user's natural language command
        and determine what action they want to perform. Return a MusicIntent with:
        1. The action (play, queue, shuffle, like, skip, pause, etc.)
        2. Parsed query components (artist, genre, mood, era, version, activity)

        PARSE NATURAL LANGUAGE INTO STRUCTURED COMPONENTS:

        Example: "upbeat rolling stones songs from the 90s"
        → action: play
        → artist: "Rolling Stones"
        → mood: "upbeat"
        → era: "1990s"

        Example: "chill jazz for studying"
        → action: play
        → genre: "jazz"
        → mood: "chill"
        → activity: "study"

        Example: "acoustic covers of pop hits"
        → action: play
        → genre: "pop"
        → version: "acoustic cover"

        Example: "80s synthwave"
        → action: play
        → genre: "synthwave"
        → era: "1980s"

        Example: "add some energetic workout music to queue"
        → action: queue
        → mood: "energetic"
        → activity: "workout"

        COMPONENT EXTRACTION RULES:
        - artist: Extract artist name if mentioned ("Beatles", "Taylor Swift", "Kendrick Lamar")
        - genre: rock, pop, jazz, classical, hip-hop, r&b, electronic, country, folk, metal, indie, latin, k-pop, etc.
        - mood: upbeat, chill, sad, happy, energetic, relaxing, melancholic, romantic, aggressive, peaceful, groovy, dark
        - era: Use decade format (1960s, 1970s, 1980s, 1990s, 2000s, 2010s, 2020s) or "classic" for oldies
        - version: acoustic, live, remix, instrumental, cover, unplugged, remastered
        - activity: workout, study, sleep, party, driving, cooking, focus, running, yoga, meditation

        For simple commands:
        - "skip" or "next" → action: skip
        - "pause" or "stop" → action: pause
        - "play" or "resume" → action: resume
        - "shuffle my queue" → action: shuffle, shuffleScope: queue
        - "like this" → action: like
        - "clear queue" → action: queue, query: "__clear__"
        """

        let searchTool = MusicSearchTool(client: self.client)
        let queueTool = QueueTool(playerService: self.playerService)

        guard let session = FoundationModelsService.shared.createSession(
            instructions: instructions,
            tools: [searchTool, queueTool]
        ) else {
            self.errorMessage = "Could not create AI session"
            self.isProcessing = false
            return
        }

        do {
            let response = try await session.respond(to: query, generating: MusicIntent.self)
            await self.executeIntent(response.content)
        } catch let error as LanguageModelSession.GenerationError {
            self.logger.error("Generation error: \(error.localizedDescription)")
            self.errorMessage = "I couldn't understand that command"
        } catch {
            self.logger.error("Command processing error: \(error.localizedDescription)")
            self.errorMessage = "Something went wrong. Try again?"
        }

        self.isProcessing = false
    }

    private func executeIntent(_ intent: MusicIntent) async {
        // Build the search query from parsed components
        let searchQuery = intent.buildSearchQuery()
        let description = intent.queryDescription()

        self.logger.info("Executing intent: \(intent.action.rawValue)")
        self.logger.info("  Raw query: \(intent.query)")
        self.logger.info("  Artist: \(intent.artist), Genre: \(intent.genre), Mood: \(intent.mood)")
        self.logger.info("  Era: \(intent.era), Version: \(intent.version), Activity: \(intent.activity)")
        self.logger.info("  Built search query: \(searchQuery)")

        switch intent.action {
        case .play:
            if searchQuery.isEmpty, intent.query.isEmpty {
                await self.playerService.resume()
                self.resultMessage = "Resuming playback"
            } else {
                await self.playSearchResult(query: searchQuery, description: description)
            }

        case .queue:
            if intent.query == "__clear__" {
                self.playerService.clearQueue()
                self.resultMessage = "Queue cleared"
            } else if !searchQuery.isEmpty {
                await self.queueSearchResult(query: searchQuery, description: description)
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
            self.dismiss()
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
        self.dismiss()
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
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    CommandBarView(client: client)
        .environment(PlayerService())
        .padding(40)
        .frame(width: 600, height: 300)
}
