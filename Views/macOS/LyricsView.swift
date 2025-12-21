import FoundationModels
import SwiftUI

/// Right sidebar panel displaying lyrics for the current track.
@available(macOS 26.0, *)
struct LyricsView: View {
    @Environment(PlayerService.self) private var playerService

    let client: any YTMusicClientProtocol

    @State private var lyrics: Lyrics?
    @State private var isLoading = false
    @State private var lastLoadedVideoId: String?

    // AI explanation state
    @State private var lyricsSummary: LyricsSummary?
    @State private var isExplaining = false
    @State private var showExplanation = false

    private let logger = DiagnosticsLogger.ai

    var body: some View {
        VStack(spacing: 0) {
            // Header
            self.headerView

            Divider()

            // Content
            self.contentView
        }
        .frame(minWidth: 280, maxWidth: 280)
        .background(.background.opacity(0.95))
        .onChange(of: self.playerService.currentTrack?.videoId) { _, newVideoId in
            if let videoId = newVideoId, videoId != lastLoadedVideoId {
                // Reset explanation when track changes
                self.lyricsSummary = nil
                self.showExplanation = false
                Task {
                    await self.loadLyrics(for: videoId)
                }
            }
        }
        .task {
            if let videoId = playerService.currentTrack?.videoId {
                await self.loadLyrics(for: videoId)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Lyrics")
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()

            // Explain button (AI-powered)
            if self.lyrics?.isAvailable == true {
                Button {
                    if self.showExplanation {
                        self.showExplanation = false
                    } else if self.lyricsSummary != nil {
                        self.showExplanation = true
                    } else {
                        Task {
                            await self.explainLyrics()
                        }
                    }
                } label: {
                    if self.isExplaining {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: self.showExplanation ? "sparkles.rectangle.stack.fill" : "sparkles")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.showExplanation ? .purple : .secondary)
                .help("Explain lyrics with AI")
                .requiresIntelligence()
                .disabled(self.isExplaining)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        if self.isLoading {
            self.loadingView
        } else if let lyrics, lyrics.isAvailable {
            self.lyricsContentView(lyrics)
        } else {
            self.noLyricsView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading lyrics...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lyricsContentView(_ lyrics: Lyrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // AI Explanation section (if available)
                if self.showExplanation, let summary = lyricsSummary {
                    self.explanationSection(summary)
                    Divider()
                        .padding(.vertical, 12)
                }

                // Lyrics text
                Text(lyrics.text)
                    .font(.system(size: 15, weight: .medium))
                    .lineSpacing(8)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)

                // Source attribution
                if let source = lyrics.source {
                    Divider()
                        .padding(.horizontal, 16)

                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private func explanationSection(_ summary: LyricsSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Mood
            HStack(spacing: 8) {
                Image(systemName: "heart.circle.fill")
                    .foregroundStyle(.pink)
                Text(summary.mood.capitalized)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Themes
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(summary.themes, id: \.self) { theme in
                        Text(theme)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.purple.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
            }

            // Explanation
            Text(summary.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .background(.purple.opacity(0.05))
    }

    private var noLyricsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text("No Lyrics Available")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("There aren't any lyrics available for this song.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadLyrics(for videoId: String) async {
        self.isLoading = true
        self.lastLoadedVideoId = videoId

        do {
            let fetchedLyrics = try await client.getLyrics(videoId: videoId)
            // Only update if still relevant (user hasn't changed tracks)
            if self.playerService.currentTrack?.videoId == videoId {
                self.lyrics = fetchedLyrics
            }
        } catch {
            DiagnosticsLogger.api.error("Failed to load lyrics: \(error.localizedDescription)")
            self.lyrics = .unavailable
        }

        self.isLoading = false
    }

    private func explainLyrics() async {
        guard let lyrics, lyrics.isAvailable,
              let track = playerService.currentTrack
        else { return }

        self.isExplaining = true
        self.logger.info("Explaining lyrics for: \(track.title)")

        let instructions = """
        You are a music critic and lyricist. Analyze song lyrics and provide insights about
        their meaning, themes, and emotional content. Be insightful but accessible.
        Don't be overly academic or pretentious.
        """

        guard let session = FoundationModelsService.shared.createSession(instructions: instructions) else {
            self.logger.warning("Apple Intelligence not available for lyrics explanation")
            self.isExplaining = false
            return
        }

        let prompt = """
        Analyze these lyrics for "\(track.title)" by \(track.artistsDisplay):

        \(lyrics.text)

        Identify the key themes, overall mood, and explain what the song is about.
        """

        do {
            let response = try await session.respond(to: prompt, generating: LyricsSummary.self)
            self.lyricsSummary = response.content
            self.showExplanation = true
            self.logger.info("Generated lyrics explanation: mood=\(response.content.mood), themes=\(response.content.themes.joined(separator: ", "))")
        } catch {
            self.logger.error("Failed to explain lyrics: \(error.localizedDescription)")
        }

        self.isExplaining = false
    }
}

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    LyricsView(client: client)
        .environment(PlayerService())
        .frame(height: 600)
}
