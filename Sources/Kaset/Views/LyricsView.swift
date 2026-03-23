import FoundationModels
import SwiftUI

/// Right sidebar panel displaying lyrics for the current track.
/// Supports time-synced lyrics with auto-scroll and karaoke-style highlighting
/// via LRCLIB, with fallback to plain lyrics from YouTube Music.
@available(macOS 26.0, *)
struct LyricsView: View {
    @Environment(PlayerService.self) private var playerService

    let client: any YTMusicClientProtocol

    // Plain lyrics (YTMusic)
    @State private var lyrics: Lyrics?
    // Synced lyrics (LRCLIB)
    @State private var syncedLyrics: SyncedLyrics?
    @State private var isLoading = false
    @State private var lastLoadedTrackKey: String?

    /// Index of the currently highlighted synced line.
    @State private var currentLineIndex: Int?
    /// Whether the user has manually scrolled (pauses auto-scroll).
    @State private var userIsScrolling = false
    /// Timer to resume auto-scroll after user interaction.
    @State private var scrollResumeTask: Task<Void, Never>?

    // AI explanation state
    @State private var lyricsSummary: LyricsSummary?
    @State private var partialSummary: LyricsSummary.PartiallyGenerated?
    @State private var isExplaining = false
    @State private var showExplanation = false
    @State private var explanationError: String?

    private let logger = DiagnosticsLogger.ai

    /// Namespace for glass effect morphing.
    @Namespace private var lyricsNamespace

    /// Unique key for the current track, combining videoId + title + artist.
    /// This ensures lyrics reload even when videoId doesn't change (e.g. YouTube autoplay).
    private var trackKey: String? {
        guard let track = playerService.currentTrack else { return nil }
        return "\(track.videoId)|\(track.title)|\(track.artistsDisplay)"
    }

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 0) {
                // Header
                self.headerView

                Divider()
                    .opacity(0.3)

                // Content
                self.contentView
            }
            .frame(width: 280)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
            .glassEffectID("lyricsPanel", in: self.lyricsNamespace)
        }
        .glassEffectTransition(.materialize)
        .onChange(of: self.trackKey) { _, newKey in
            if let key = newKey, key != lastLoadedTrackKey {
                // Reset state on track change
                self.lyricsSummary = nil
                self.partialSummary = nil
                self.showExplanation = false
                self.explanationError = nil
                self.currentLineIndex = nil
                self.syncedLyrics = nil
                self.lyrics = nil
                Task {
                    await self.loadLyrics(for: self.playerService.currentTrack?.videoId ?? "")
                }
            }
        }
        .onChange(of: self.playerService.progress) { _, newProgress in
            self.updateCurrentLine(at: newProgress)
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

            // Synced indicator
            if self.syncedLyrics?.hasSyncedLines == true {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help("Synced lyrics")
            }

            Spacer()

            // Explain button (AI-powered)
            if self.hasAnyLyrics {
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
                .help("Explain lyrics with AI")
                .accessibilityLabel(self.showExplanation ? "Hide lyrics explanation" : "Explain lyrics with AI")
                .requiresIntelligence()
                .disabled(self.isExplaining)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Whether any form of lyrics (synced or plain) is available.
    private var hasAnyLyrics: Bool {
        self.syncedLyrics?.hasSyncedLines == true
            || self.syncedLyrics?.plainText?.isEmpty == false
            || self.lyrics?.isAvailable == true
    }

    // MARK: - Content

    @ViewBuilder
    private var contentView: some View {
        if self.playerService.currentTrack == nil {
            self.noTrackPlayingView
        } else if self.isLoading {
            self.loadingView
        } else if let synced = syncedLyrics, synced.hasSyncedLines {
            self.syncedLyricsContentView(synced)
        } else if let lyrics, lyrics.isAvailable {
            self.plainLyricsContentView(lyrics)
        } else if let synced = syncedLyrics, let plain = synced.plainText, !plain.isEmpty {
            self.plainFallbackView(plain, source: synced.source)
        } else {
            self.noLyricsView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.regular)
                .frame(width: 20, height: 20)
            Text("Loading lyrics...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Synced Lyrics View

    private func syncedLyricsContentView(_ synced: SyncedLyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // AI Explanation section
                    self.explanationBanner

                    // Top spacer for visual centering
                    Spacer()
                        .frame(height: 60)

                    // Synced lyrics lines
                    ForEach(Array(synced.lines.enumerated()), id: \.element.id) { index, line in
                        self.syncedLineView(line, index: index, total: synced.lines.count)
                            .id(index)
                    }

                    // Bottom spacer
                    Spacer()
                        .frame(height: 120)

                    // Source attribution
                    if let source = synced.source {
                        Divider()
                            .padding(.horizontal, 16)
                        Text("Source: \(source)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        self.userIsScrolling = true
                        self.scrollResumeTask?.cancel()
                    }
                    .onEnded { _ in
                        // Resume auto-scroll after 4 seconds of inactivity
                        self.scrollResumeTask = Task {
                            try? await Task.sleep(for: .seconds(4))
                            if !Task.isCancelled {
                                self.userIsScrolling = false
                            }
                        }
                    }
            )
            .onChange(of: self.currentLineIndex) { _, newIndex in
                guard let newIndex, !self.userIsScrolling else { return }
                withAnimation(.spring(duration: 0.45, bounce: 0.0)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func syncedLineView(_ line: SyncedLyricsLine, index: Int, total: Int) -> some View {
        let isCurrent = index == self.currentLineIndex
        let isPast = if let current = self.currentLineIndex { index < current } else { false }

        if line.isInterlude {
            // Instrumental / interlude indicator – white dots, animation only while active
            HStack(spacing: 6) {
                ForEach(0 ..< 3, id: \.self) { dotIndex in
                    Circle()
                        .fill(Color.primary.opacity(isCurrent ? 0.9 : 0.25))
                        .frame(width: 5, height: 5)
                        .scaleEffect(isCurrent ? 1.4 : 1.0)
                        .animation(
                            isCurrent
                                ? .easeInOut(duration: 0.5)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(dotIndex) * 0.15)
                                : .easeOut(duration: 0.3),
                            value: isCurrent
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else {
            // Use constant font size & weight so text never reflows when a line becomes active.
            // Differentiation is purely through color and opacity (like Apple Music).
            Text(line.text)
                .font(.system(size: 16, weight: .bold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.primary)
                .opacity(isCurrent ? 1.0 : isPast ? 0.3 : 0.45)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .animation(.spring(duration: 0.35, bounce: 0.0), value: isCurrent)
                .animation(.easeOut(duration: 0.4), value: isPast)
                .contentShape(Rectangle())
                .onTapGesture {
                    SingletonPlayerWebView.shared.seek(to: line.time)
                }
        }
    }

    // MARK: - Plain Lyrics Views

    private func plainLyricsContentView(_ lyrics: Lyrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // AI Explanation section
                self.explanationBanner

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

    private func plainFallbackView(_ text: String, source: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(text)
                    .font(.system(size: 15, weight: .medium))
                    .lineSpacing(8)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)

                if let source {
                    Divider()
                        .padding(.horizontal, 16)
                    Text("Source: \(source)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    // MARK: - AI Explanation Banner

    @ViewBuilder
    private var explanationBanner: some View {
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

    /// Shows partial content as it streams in from the AI.
    private func streamingExplanationSection(_ partial: LyricsSummary.PartiallyGenerated) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Mood (shows when available)
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

            // Themes (shows as they arrive)
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

            // Explanation (shows progressively)
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
                    Text("Analyzing...")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .background(.purple.opacity(0.05))
    }

    /// Shows error state for failed AI explanation.
    private func errorSection(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Retry") {
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

    private var noTrackPlayingView: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text("No Song Playing")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Play a song to view its lyrics here.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Synced Line Tracking

    /// Small look-ahead offset (seconds) to compensate for rendering + IPC latency.
    /// This makes lyrics appear slightly *before* the audio so they feel perfectly in sync.
    private static let timingOffset: TimeInterval = 0.3

    private func updateCurrentLine(at time: TimeInterval) {
        guard let synced = syncedLyrics, synced.hasSyncedLines else { return }
        let adjustedTime = time + Self.timingOffset
        let newIndex = synced.currentLineIndex(at: adjustedTime)
        if newIndex != self.currentLineIndex {
            self.currentLineIndex = newIndex
        }
    }

    // MARK: - Data Loading

    private func loadLyrics(for videoId: String) async {
        self.isLoading = true
        let currentKey = self.trackKey
        self.lastLoadedTrackKey = currentKey

        // Capture main-actor values before launching parallel tasks
        let track = playerService.currentTrack
        let currentDuration = playerService.duration

        // Fetch both sources in parallel
        async let plainTask: Lyrics? = {
            do {
                return try await client.getLyrics(videoId: videoId)
            } catch {
                DiagnosticsLogger.api.error("Failed to load plain lyrics: \(error.localizedDescription)")
                return nil
            }
        }()

        async let syncedTask: SyncedLyrics? = {
            guard let track else { return nil }
            return await SyncedLyricsService.shared.fetchLyrics(
                title: track.title,
                artist: track.artistsDisplay,
                duration: currentDuration > 0 ? currentDuration : nil
            )
        }()

        let (plain, synced) = await (plainTask, syncedTask)

        // Only update if still relevant (user hasn't changed tracks)
        if self.trackKey == currentKey {
            self.lyrics = plain ?? .unavailable
            self.syncedLyrics = synced

            // Set initial line
            if let synced, synced.hasSyncedLines {
                self.updateCurrentLine(at: self.playerService.progress)
            }
        }

        self.isLoading = false
    }

    private func explainLyrics() async {
        // Use synced lyrics text if available, otherwise plain lyrics
        let lyricsText: String? = if let synced = syncedLyrics, synced.hasSyncedLines {
            synced.lines.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
        } else if let synced = syncedLyrics, let plain = synced.plainText, !plain.isEmpty {
            plain
        } else if let lyrics, lyrics.isAvailable {
            lyrics.text
        } else {
            nil
        }

        guard let lyricsText, !lyricsText.isEmpty,
              let track = playerService.currentTrack
        else { return }

        self.isExplaining = true
        self.explanationError = nil
        self.partialSummary = nil
        self.logger.info("Explaining lyrics for: \(track.title)")

        let instructions = """
        You are a music critic and lyricist. Analyze song lyrics and provide insights about
        their meaning, themes, and emotional content. Be insightful but accessible.
        Don't be overly academic or pretentious.
        """

        guard let session = FoundationModelsService.shared.createAnalysisSession(instructions: instructions) else {
            self.logger.warning("Apple Intelligence not available for lyrics explanation")
            self.explanationError = "Apple Intelligence is not available"
            self.isExplaining = false
            return
        }

        let prompt = """
        Analyze these lyrics for "\(track.title)" by \(track.artistsDisplay):

        \(lyricsText)

        Identify the key themes, overall mood, and explain what the song is about.
        """

        do {
            // Use streaming for progressive UI updates
            let stream = session.streamResponse(
                to: prompt,
                generating: LyricsSummary.self
            )

            for try await snapshot in stream {
                // Extract partial content from snapshot for streaming UI updates
                self.partialSummary = snapshot.content
            }

            // Stream complete - convert final partial to complete summary
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

#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    LyricsView(client: client)
        .environment(PlayerService())
        .frame(height: 600)
}
