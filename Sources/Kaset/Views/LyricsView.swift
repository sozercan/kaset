import FoundationModels
import SwiftUI
import Translation

/// Right sidebar panel displaying lyrics for the current track.
@available(macOS 26.0, *)
struct LyricsView: View {
    @Environment(PlayerService.self) private var playerService
    @Environment(SyncedLyricsService.self) private var syncedLyricsService

    let client: any YTMusicClientProtocol
    var showsHeader = true
    var preferredWidth: CGFloat? = 280
    var isEmbedded = false

    @State private var lastLoadedVideoId: String?
    @State private var isLoadingFallback = false

    // Translation state. Online (Google gtx) first; the Apple Translation
    // framework session is the on-device fallback when the online path fails.
    @State private var settings = SettingsManager.shared
    @State private var lineTranslations: [UUID: String] = [:]
    @State private var plainTranslation: String?
    @State private var translationConfiguration: TranslationSession.Configuration?
    /// Set when the online translation path failed entirely (e.g. offline);
    /// switches translation over to the on-device Apple session.
    @State private var onlineTranslationFailed = false
    @State private var onlineTranslationTask: Task<Void, Never>?

    // Resizable panel width (only used when the caller allows a fixed panel,
    // i.e. not the mini player, which sizes the panel itself).
    static let defaultPanelWidth: CGFloat = 280
    static let minimumPanelWidth: CGFloat = 280
    static let maximumPanelWidth: CGFloat = 640
    @State private var expandedWidth = SettingsManager.shared.lyricsPanelWidth.map { CGFloat($0) }
        ?? LyricsView.defaultPanelWidth
    @State private var dragStartWidth: CGFloat?
    @State private var hoveringResizeZone = false

    // AI explanation state
    @State private var lyricsSummary: LyricsSummary?
    @State private var partialSummary: LyricsSummary.PartiallyGenerated?
    @State private var isExplaining = false
    @State private var showExplanation = false
    @State private var explanationError: String?

    private let logger = DiagnosticsLogger.ai

    /// Namespace for glass effect morphing.
    @Namespace private var lyricsNamespace

    var body: some View {
        self.panelSurface
            // `@Sendable` keeps the action nonisolated: TranslationSession is not
            // Sendable, so its calls may not cross into the main actor.
            // This is the on-device fallback path; the online path lives in
            // runOnlineTranslation below.
            .translationTask(self.translationConfiguration) { @Sendable session in
                // The session is not Sendable: snapshot pending work on the main
                // actor, then run every session call inside this nonisolated
                // closure, and write results back with Sendable payloads only.
                guard let job = await self.translationJob() else { return }

                switch job {
                case let .lines(videoId, lines):
                    let requests = lines.map {
                        TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
                    }
                    do {
                        let responses = try await session.translations(from: requests)
                        await self.applyLineTranslations(responses, for: videoId)
                    } catch {
                        // Unsupported language pair or throttling: leave lines untranslated.
                    }
                case let .plain(videoId, text):
                    do {
                        let response = try await session.translate(text)
                        await self.applyPlainTranslation(response.targetText, for: videoId)
                    } catch {
                        // Unsupported language pair or throttling: leave untranslated.
                    }
                }
            }
            .onChange(of: self.playerService.currentTrack?.videoId) { _, newVideoId in
                if let videoId = newVideoId, videoId != lastLoadedVideoId {
                    // Reset explanation when track changes
                    self.lyricsSummary = nil
                    self.partialSummary = nil
                    self.showExplanation = false
                    self.explanationError = nil
                    self.lineTranslations = [:]
                    self.plainTranslation = nil
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
                self.restartTranslation()
            }
            .onChange(of: self.settings.lyricsTranslationEnabled) { _, _ in
                self.restartTranslation()
            }
            .onChange(of: self.settings.lyricsTranslationTargetLanguage) { _, _ in
                self.lineTranslations = [:]
                self.plainTranslation = nil
                self.restartTranslation()
            }
            .onDisappear {
                self.onlineTranslationTask?.cancel()
                SingletonPlayerWebView.shared.stopLyricsPoll()
            }
            .onAppear {
                self.updateLyricsPolling(for: self.syncedLyricsService.currentLyrics)
                self.restartTranslation()
            }
    }

    @ViewBuilder private var panelSurface: some View {
        if self.isEmbedded {
            self.panelContent
        } else {
            CompatGlassContainer(spacing: 0) {
                self.panelContent
                    .compatGlass(interactive: true, in: .rect(cornerRadius: 20))
                    .compatGlassID("lyricsPanel", in: self.lyricsNamespace)
                    .overlay(alignment: .leading) { self.panelResizeHandle }
            }
            .compatGlassTransition(.materialize)
        }
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            if self.showsHeader {
                self.headerView
                Divider().opacity(0.3)
            }
            self.contentView
        }
        .frame(width: self.displayWidth)
    }

    // MARK: - Panel resizing

    /// Width the panel renders at. The mini player (`preferredWidth == nil`)
    /// keeps caller-controlled sizing; the main window panel is resizable.
    private var displayWidth: CGFloat? {
        guard self.preferredWidth != nil else { return nil }
        return min(max(self.expandedWidth, Self.minimumPanelWidth), Self.maximumPanelWidth)
    }

    /// Fonts grow with the panel width, capped so extreme widths stay readable.
    private var fontSizeScale: CGFloat {
        let width = self.displayWidth ?? Self.defaultPanelWidth
        return min(max(width / Self.defaultPanelWidth, 1.0), 2.0)
    }

    @ViewBuilder private var panelResizeHandle: some View {
        if self.preferredWidth != nil {
            Color.clear
                .frame(width: 10)
                .contentShape(Rectangle())
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(self.hoveringResizeZone ? 0.6 : 0))
                        .frame(width: 3, height: 40)
                        .padding(.leading, 3)
                }
                .onHover { hovering in
                    self.hoveringResizeZone = hovering
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if self.dragStartWidth == nil {
                                self.dragStartWidth = self.expandedWidth
                            }
                            let start = self.dragStartWidth ?? self.expandedWidth
                            // The handle sits on the panel's leading edge, so
                            // dragging left widens the panel.
                            self.expandedWidth = min(
                                max(start - value.translation.width, Self.minimumPanelWidth),
                                Self.maximumPanelWidth
                            )
                        }
                        .onEnded { _ in
                            self.dragStartWidth = nil
                            self.settings.lyricsPanelWidth = Double(self.expandedWidth)
                        }
                )
        }
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

    // MARK: - Translation

    private var targetTranslationLanguage: Locale.Language {
        if let identifier = self.settings.lyricsTranslationTargetLanguage {
            return Locale.Language(identifier: identifier)
        }
        return Locale.current.language
    }

    /// BCP-47 identifier of the translation target, or the system language.
    private var targetTranslationIdentifier: String {
        self.settings.lyricsTranslationTargetLanguage ?? Locale.current.language.languageCode?.identifier ?? "en"
    }

    /// Restarts translation: cancels any online attempt, then runs the online
    /// path, falling back to the on-device Apple session when it fails.
    private func restartTranslation() {
        self.onlineTranslationTask?.cancel()
        self.onlineTranslationFailed = false
        self.rebuildTranslationConfiguration()

        guard self.settings.lyricsTranslationEnabled,
              self.syncedLyricsService.currentLyrics.isAvailable
        else { return }

        self.onlineTranslationTask = Task {
            await self.runOnlineTranslation()
        }
    }

    /// Runs the keyless online translation for all pending lines (or the plain
    /// lyrics block). On total failure, marks the fallback so the Apple
    /// Translation session takes over.
    private func runOnlineTranslation() async {
        guard let job = self.translationJob() else { return }

        let target = GoogleTranslateService.targetCode(for: self.targetTranslationIdentifier)
        do {
            switch job {
            case let .lines(videoId, pending):
                let responses = try await GoogleTranslateService.translateLines(
                    pending.map(\.text), target: target
                )
                // A track change during the request would otherwise stamp the
                // old track's translation onto the new track's lyrics.
                guard !Task.isCancelled,
                      self.playerService.currentTrack?.videoId == videoId
                else { return }
                for (index, line) in pending.enumerated() where !responses[index].isEmpty {
                    self.lineTranslations[line.id] = responses[index]
                }
            case let .plain(videoId, text):
                let translated = try await GoogleTranslateService.translate(text, target: target)
                guard !Task.isCancelled,
                      self.playerService.currentTrack?.videoId == videoId
                else { return }
                self.plainTranslation = translated
            }
        } catch {
            guard !Task.isCancelled else { return }
            DiagnosticsLogger.api.warning("Online lyrics translation failed; falling back to on-device: \(error.localizedDescription)")
            self.onlineTranslationFailed = true
            // Start the on-device Apple Translation session.
            self.rebuildTranslationConfiguration()
        }
    }

    /// (Re)starts the on-device translation session whenever the lyrics, the
    /// toggle, or the target language change. Only used as the offline fallback
    /// (online translation runs first).
    private func rebuildTranslationConfiguration() {
        guard self.settings.lyricsTranslationEnabled,
              self.onlineTranslationFailed,
              self.syncedLyricsService.currentLyrics.isAvailable
        else {
            self.translationConfiguration = nil
            return
        }

        var configuration = TranslationSession.Configuration(target: self.targetTranslationLanguage)
        // Forces translationTask to rerun even when the languages did not change.
        configuration.invalidate()
        self.translationConfiguration = configuration
    }

    /// The remaining translation work for the current lyrics, or nil when
    /// everything is translated or translation is off. The job carries the
    /// videoId it was built from so stale results can be dropped on track
    /// change.
    private enum TranslationJob: Sendable {
        case lines(videoId: String?, lines: [(id: UUID, text: String)])
        case plain(videoId: String?, text: String)
    }

    private func translationJob() -> TranslationJob? {
        guard self.settings.lyricsTranslationEnabled else { return nil }
        let videoId = self.playerService.currentTrack?.videoId

        switch self.syncedLyricsService.currentLyrics {
        case let .synced(synced):
            let pending = synced.lines.filter { !$0.text.isEmpty && self.lineTranslations[$0.id] == nil }
            guard !pending.isEmpty else { return nil }
            return .lines(videoId: videoId, lines: pending.map { (id: $0.id, text: $0.text) })
        case let .plain(lyrics):
            guard lyrics.isAvailable, self.plainTranslation == nil else { return nil }
            return .plain(videoId: videoId, text: lyrics.text)
        case .unavailable:
            return nil
        }
    }

    private func applyLineTranslations(_ responses: [TranslationSession.Response], for videoId: String?) {
        guard self.playerService.currentTrack?.videoId == videoId else { return }
        for response in responses {
            guard let identifier = response.clientIdentifier,
                  let lineID = UUID(uuidString: identifier)
            else { continue }
            self.lineTranslations[lineID] = response.targetText
        }
    }

    private func applyPlainTranslation(_ text: String, for videoId: String?) {
        guard self.playerService.currentTrack?.videoId == videoId else { return }
        self.plainTranslation = text
    }

    // MARK: - Header

    private var translationOptionsMenu: some View {
        Menu {
            Toggle(String(localized: "Pronunciation"), isOn: self.$settings.romanizationEnabled)
            Toggle(String(localized: "Translation"), isOn: self.$settings.lyricsTranslationEnabled)

            if self.settings.lyricsTranslationEnabled {
                Picker(String(localized: "Translate To"), selection: self.$settings.lyricsTranslationTargetLanguage) {
                    ForEach(SettingsManager.ContentLanguage.allCases) { language in
                        Text(language.displayName).tag(language.languageCode)
                    }
                }
            }
        } label: {
            Image(systemName: "character.bubble")
        }
        .fixedSize()
        .help(String(localized: "Lyrics Display Options"))
        .accessibilityLabel(String(localized: "Lyrics Display Options"))
    }

    private var headerView: some View {
        HStack {
            Text(String(localized: "Lyrics"))
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()

            // Display options: pronunciation and translation
            if self.syncedLyricsService.currentLyrics.isAvailable {
                self.translationOptionsMenu
            }

            // Explain button (AI-powered)
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

    // MARK: - Content

    @ViewBuilder private var contentView: some View {
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
            // AI Explanation section (streaming or complete)
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
                },
                lineTranslations: self.settings.lyricsTranslationEnabled ? self.lineTranslations : [:],
                fontSizeScale: self.fontSizeScale,
                isPlaying: self.playerService.isPlaying
            )
            .background(Color.clear)
        }
    }

    private func plainLyricsContentView(_ lyrics: Lyrics) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // AI Explanation section (streaming or complete)
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

                // Lyrics text
                Text(lyrics.text)
                    .font(.system(size: 15, weight: .medium))
                    .lineSpacing(8)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)

                // Translation of the plain lyrics block
                if self.settings.lyricsTranslationEnabled, let plainTranslation = self.plainTranslation {
                    Text(plainTranslation)
                        .font(.system(size: 15, weight: .regular))
                        .lineSpacing(8)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                }

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

    /// Shows error state for failed AI explanation.
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

    // MARK: - Data Loading

    @MainActor
    private func loadLyrics(for videoId: String) async {
        self.lastLoadedVideoId = videoId
        self.isLoadingFallback = false

        guard let track = playerService.currentTrack else { return }

        // Don't search if it's not the current track anymore
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

        guard self.lastLoadedVideoId == videoId, self.playerService.currentTrack?.videoId == videoId else { return }

        // As a fallback to provide plain lyrics
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

@available(macOS 26.0, *)
#Preview {
    let authService = AuthService()
    let client = YTMusicClient(authService: authService, webKitManager: .shared)
    LyricsView(client: client)
        .environment(PlayerService())
        .frame(height: 600)
}
