import FoundationModels
import SwiftUI

@MainActor
enum LyricsPollLease {
    private static var holders = 0

    static func acquire() {
        self.holders += 1
    }

    static func release() {
        self.holders = max(0, self.holders - 1)
        if self.holders == 0 {
            SingletonPlayerWebView.shared.stopLyricsPoll()
        }
    }
}

@available(macOS 26.0, *)
struct LyricsView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(SyncedLyricsService.self) private var syncedLyricsService

    let client: any YTMusicClientProtocol
    var showsHeader = true
    var preferredWidth: CGFloat? = 280
    var showsPanel = true

    @State private var lastLoadedVideoId: String?
    @State private var isLoadingFallback = false

    @State private var lyricsSummary: LyricsSummary?
    @State private var partialSummary: LyricsSummary.PartiallyGenerated?
    @State private var isExplaining = false
    @State private var showExplanation = false
    @State private var explanationError: String?

    private let logger = DiagnosticsLogger.ai

    @Namespace private var lyricsNamespace

    var body: some View {
        CompatGlassContainer(spacing: 0) {
            VStack(spacing: 0) {
                if self.showsHeader {
                    self.headerView

                    Divider()
                        .opacity(0.3)
                }

                self.contentView
            }
            .frame(width: self.preferredWidth)
            .compatGlass(interactive: true, in: .rect(cornerRadius: 20), isEnabled: self.showsPanel)
            .compatGlassID("lyricsPanel", in: self.lyricsNamespace)
        }
        .compatGlassTransition(.materialize)
        .onChange(of: self.playerService.currentTrack?.videoId) { _, newVideoId in
            if let videoId = newVideoId, videoId != lastLoadedVideoId {
                self.lyricsSummary = nil
                self.partialSummary = nil
                self.showExplanation = false
                self.explanationError = nil
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
        .onChange(of: self.syncedLyricsService.currentLyrics) { _, newLyrics in
            self.updateLyricsPolling(for: newLyrics)
        }
        .onDisappear {
            LyricsPollLease.release()
        }
        .onAppear {
            LyricsPollLease.acquire()
            self.updateLyricsPolling(for: self.syncedLyricsService.currentLyrics)
        }
        .accessibilityIdentifier(AccessibilityID.Lyrics.panel)
    }

    private func updateLyricsPolling(for result: LyricResult) {
        if case let .synced(synced) = result {
            self.playerService.currentLyricsLineIndex = nil
            self.playerService.currentLyricsDisplayTimeMs = nil
            SingletonPlayerWebView.shared.startLyricsPoll(lineRanges: synced.bridgeLineRanges)
        } else {
            SingletonPlayerWebView.shared.stopLyricsPoll()
            self.playerService.currentLyricsLineIndex = nil
            self.playerService.currentLyricsDisplayTimeMs = nil
        }
    }

    private var headerView: some View {
        HStack {
            Text(String(localized: "Lyrics"))
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()

            if self.syncedLyricsService.currentLyrics.isAvailable {
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
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                    } else {
                        Image(systemName: self.showExplanation ? "sparkles.rectangle.stack.fill" : "sparkles")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.showExplanation ? .purple : .secondary)
                .help(String(localized: "Explain lyrics with AI"))
                .accessibilityLabel(self.showExplanation ? String(localized: "Hide lyrics explanation") : String(localized: "Explain lyrics with AI"))
                .requiresIntelligence()
                .disabled(self.isExplaining)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var contentView: some View {
        if self.playerService.currentTrack == nil {
            self.noTrackPlayingView
        } else if self.syncedLyricsService.isLoading || self.isLoadingFallback {
            self.loadingView
        } else {
            switch self.syncedLyricsService.currentLyrics {
            case let .synced(synced):
                self.syncedLyricsContentView(synced)
            case let .plain(plain):
                self.plainLyricsContentView(plain)
            case .unavailable:
                self.noLyricsView
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.regular)
                .frame(width: 20, height: 20)
            Text("Loading lyrics...", comment: "Lyrics panel loading state")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func syncedLyricsContentView(_ synced: SyncedLyrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if self.isExplaining || self.showExplanation || self.explanationError != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if self.isExplaining, let partial = partialSummary {
                            self.streamingExplanationSection(partial)
                        } else if self.showExplanation, let summary = lyricsSummary {
                            self.explanationSection(summary)
                        } else if let error = explanationError {
                            self.errorSection(error)
                        }
                    }
                }
                .frame(maxHeight: 200)
                Divider().opacity(0.3)
            }

            SyncedLyricsDisplayView(
                lyrics: synced,
                currentLineIndex: self.playerService.currentLyricsLineIndex,
                displayTimeMs: self.playerService.currentLyricsDisplayTimeMs,
                onSeek: { timeMs in
                    Task { await self.playerService.seek(to: Double(timeMs) / 1000.0) }
                }
            )
            .background(Color.clear)
        }
    }

    private func plainLyricsContentView(_ lyrics: Lyrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if self.isExplaining, let partial = partialSummary {
                    self.streamingExplanationSection(partial)
                    Divider()
                        .padding(.vertical, 12)
                } else if self.showExplanation, let summary = lyricsSummary {
                    self.explanationSection(summary)
                    Divider()
                        .padding(.vertical, 12)
                } else if let error = explanationError {
                    self.errorSection(error)
                    Divider()
                        .padding(.vertical, 12)
                }

                Text(lyrics.text)
                    .font(.system(size: self.showsPanel ? 15 : 20, weight: self.showsPanel ? .medium : .semibold))
                    .lineSpacing(self.showsPanel ? 8 : 12)
                    .foregroundStyle(self.showsPanel ? .primary : .secondary)
                    .multilineTextAlignment(self.showsPanel ? .leading : .center)
                    .frame(maxWidth: .infinity, alignment: self.showsPanel ? .leading : .center)
                    .textSelection(.enabled)
                    .padding(.horizontal, self.showsPanel ? 16 : 24)
                    .padding(.vertical, 20)

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
            HStack(spacing: 8) {
                Image(systemName: "heart.circle.fill")
                    .foregroundStyle(.pink)
                Text(summary.mood.capitalized)
                    .font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

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

            Text(summary.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .background(.purple.opacity(0.05))
    }

    private func streamingExplanationSection(_ partial: LyricsSummary.PartiallyGenerated) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "heart.circle.fill")
                    .foregroundStyle(.pink)
                if let mood = partial.mood {
                    Text(mood.capitalized)
                        .font(.subheadline.weight(.medium))
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if let themes = partial.themes, !themes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(themes, id: \.self) { theme in
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
            }

            if let explanation = partial.explanation {
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                    Text(String(localized: "Analyzing..."))
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .background(.purple.opacity(0.05))
    }

    private func errorSection(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "Retry")) {
                self.explanationError = nil
                Task {
                    await self.explainLyrics()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .background(.orange.opacity(0.05))
    }

    private var noLyricsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text(String(localized: "No Lyrics Available"))
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("There aren't any lyrics available for this song.", comment: "Lyrics unavailable message")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noTrackPlayingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text(String(localized: "No Song Playing"))
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Play a song to view its lyrics here.", comment: "No song playing lyrics message")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func loadLyrics(for videoId: String) async {
        self.lastLoadedVideoId = videoId
        self.isLoadingFallback = false

        guard let track = playerService.currentTrack else { return }

        guard track.videoId == videoId else { return }

        let info = LyricsSearchInfo(
            title: track.title,
            artist: track.artistsDisplay,
            album: track.album?.title,
            duration: track.duration,
            videoId: track.videoId
        )

        if SettingsManager.shared.syncedLyricsEnabled {
            await self.syncedLyricsService.fetchLyrics(for: info)
        } else {
            self.syncedLyricsService.currentLyrics = .unavailable
            self.syncedLyricsService.activeProvider = nil
        }

        guard self.lastLoadedVideoId == videoId else { return }
        guard self.playerService.currentTrack?.videoId == videoId else { return }

        if case .unavailable = self.syncedLyricsService.currentLyrics {
            self.isLoadingFallback = true
            defer {
                if self.lastLoadedVideoId == videoId {
                    self.isLoadingFallback = false
                }
            }

            do {
                let fetchedLyrics = try await client.getLyrics(videoId: videoId)
                if self.lastLoadedVideoId == videoId,
                   self.playerService.currentTrack?.videoId == videoId
                {
                    self.syncedLyricsService.fallbackToPlainLyrics(fetchedLyrics, videoId: videoId)
                }
            } catch {
                DiagnosticsLogger.api.error("Failed to load plain lyrics fallback: \(error.localizedDescription)")
            }
        }
    }

    private func explainLyrics() async {
        guard self.syncedLyricsService.currentLyrics.isAvailable,
              let track = playerService.currentTrack
        else { return }

        self.isExplaining = true
        self.explanationError = nil
        self.partialSummary = nil
        self.logger.info("Explaining lyrics for: \(track.title)")

        let promptVersion = FoundationModelsPromptVersion.current
        let instructions = FoundationModelsPromptLibrary.lyricsExplanationInstructions(
            version: promptVersion
        )
        self.logger.debug("Using Foundation Models lyrics prompt version \(promptVersion.logDescription)")

        guard let session = FoundationModelsService.shared.createAnalysisSession(instructions: instructions) else {
            self.logger.warning("Apple Intelligence not available for lyrics explanation")
            self.explanationError = "Apple Intelligence is not available"
            self.isExplaining = false
            return
        }

        var textToExplain: String
        switch self.syncedLyricsService.currentLyrics {
        case let .synced(synced):
            textToExplain = synced.lines.map(\.text).joined(separator: "\n")
        case let .plain(plain):
            textToExplain = plain.text
        case .unavailable:
            return
        }

        textToExplain = await FoundationModelsService.shared.fittedPromptContent(
            context: "lyrics explanation",
            instructions: instructions,
            content: textToExplain,
            generationSchema: LyricsSummary.generationSchema
        ) { fittedLyrics in
            FoundationModelsPromptLibrary.lyricsExplanationPrompt(
                trackTitle: track.title,
                artistsDisplay: track.artistsDisplay,
                lyrics: fittedLyrics,
                version: promptVersion
            )
        }

        let prompt = FoundationModelsPromptLibrary.lyricsExplanationPrompt(
            trackTitle: track.title,
            artistsDisplay: track.artistsDisplay,
            lyrics: textToExplain,
            version: promptVersion
        )

        do {
            let stream = session.streamResponse(
                to: prompt,
                generating: LyricsSummary.self
            )

            for try await snapshot in stream {
                self.partialSummary = snapshot.content
            }

            if let final = self.partialSummary,
               let mood = final.mood,
               let themes = final.themes,
               let explanation = final.explanation
            {
                self.lyricsSummary = LyricsSummary(
                    themes: themes,
                    mood: mood,
                    explanation: explanation
                )
                self.showExplanation = true
                self.logger.info("Generated lyrics explanation: mood=\(mood), themes=\(themes.joined(separator: ", "))")
            }
        } catch {
            if let message = AIErrorHandler.handleAndMessage(error, context: "lyrics explanation") {
                self.explanationError = message
            }
        }

        self.partialSummary = nil
        self.isExplaining = false
    }
}

@available(macOS 26.0, *)
#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    LyricsView(client: client)
        .environment(PlayerService())
        .frame(height: 600)
}
