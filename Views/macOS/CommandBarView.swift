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

                SuggestionChip(text: "Skip this song") {
                    self.inputText = "Skip this song"
                }

                SuggestionChip(text: "I like this") {
                    self.inputText = "I like this"
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
        and determine what action they want to perform. Use the searchMusic tool if you need
        to find specific songs, artists, or albums. Return a MusicIntent with the appropriate action.

        Common patterns:
        - "play X" or "put on X" → action: play, query: X
        - "queue X" or "add X to queue" → action: queue, query: X
        - "shuffle my library" → action: shuffle, shuffleScope: library
        - "like this" or "love this song" → action: like
        - "skip" or "next" → action: skip
        - "go back" or "previous" → action: previous
        - "pause" or "stop" → action: pause
        - "play" or "resume" → action: resume
        """

        let searchTool = MusicSearchTool(client: self.client)

        guard let session = FoundationModelsService.shared.createSession(
            instructions: instructions,
            tools: [searchTool]
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
        self.logger.info("Executing intent: \(intent.action.rawValue), query: \(intent.query)")

        switch intent.action {
        case .play:
            if intent.query.isEmpty {
                await self.playerService.resume()
                self.resultMessage = "Resuming playback"
            } else {
                await self.playSearchResult(query: intent.query)
            }

        case .queue:
            if !intent.query.isEmpty {
                await self.queueSearchResult(query: intent.query)
            }

        case .shuffle:
            self.playerService.toggleShuffle()
            let status = self.playerService.shuffleEnabled ? "on" : "off"
            self.resultMessage = "Shuffle is now \(status)"

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

    private func playSearchResult(query: String) async {
        do {
            let response = try await client.search(query: query)
            if let firstSong = response.songs.first {
                await self.playerService.play(song: firstSong)
                self.resultMessage = "Playing \"\(firstSong.title)\""
            } else {
                self.errorMessage = "No songs found for \"\(query)\""
            }
        } catch {
            self.logger.error("Search failed: \(error.localizedDescription)")
            self.errorMessage = "Couldn't search for music"
        }
    }

    private func queueSearchResult(query: String) async {
        do {
            let response = try await client.search(query: query)
            if let firstSong = response.songs.first {
                // For now, just play it (queue management would need more implementation)
                await self.playerService.play(song: firstSong)
                self.resultMessage = "Playing \"\(firstSong.title)\""
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
