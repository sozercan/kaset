import SwiftUI

// MARK: - SyncedLyricsDisplayView

struct SyncedLyricsDisplayView: View {
    let lyrics: SyncedLyrics
    let currentLineIndex: Int?
    let displayTimeMs: Int?
    let onSeek: (Int) -> Void
    /// Per-line translations keyed by `SyncedLyricLine.id`; empty when translation is off.
    var lineTranslations: [UUID: String] = [:]
    /// Multiplier applied to the base font sizes so a wider panel shows bigger lyrics.
    var fontSizeScale: CGFloat = 1.0
    /// Whether playback is running; freezes karaoke progress while paused.
    var isPlaying: Bool = true

    @State private var currentLineId: UUID?

    /// Karaoke time anchor: the last poll-provided display time and when it arrived.
    @State private var anchorMs: Int = -1
    @State private var anchorDate: Date = .distantPast

    private var effectiveDisplayTimeMs: Int {
        self.displayTimeMs ?? -1
    }

    /// Interpolated playback time for karaoke highlighting. Poll updates land on
    /// line boundaries; between them the time advances from the last anchor at
    /// 1x wall-clock. Paused playback freezes at the anchor.
    private func karaokeTimeMs() -> Int {
        guard self.anchorMs >= 0, self.isPlaying else { return self.anchorMs }
        return self.anchorMs + Int(Date().timeIntervalSince(self.anchorDate) * 1000)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .center, spacing: 20) {
                    Spacer().frame(height: 150) // Top padding

                    ForEach(self.lyrics.lines.indices, id: \.self) { lineIndex in
                        let line = self.lyrics.lines[lineIndex]
                        let status = self.currentStatus(for: line, at: lineIndex)
                        SyncedLineView(
                            line: line,
                            status: status,
                            onTap: { self.onSeek(line.timeInMs) },
                            translation: self.lineTranslations[line.id],
                            fontSizeScale: self.fontSizeScale,
                            displayTimeProvider: self.karaokeTimeMs
                        )
                        .id(line.id)
                    }

                    Spacer().frame(height: 150) // Bottom padding
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            .onChange(of: self.currentLineIndex, initial: true) { _, newLineIndex in
                self.updateKaraokeAnchor()
                guard let newLineIndex,
                      self.lyrics.lines.indices.contains(newLineIndex)
                else { return }

                let newId = self.lyrics.lines[newLineIndex].id
                guard newId != self.currentLineId else { return }

                self.currentLineId = newId
                withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) {
                    // Target center for natural scrolling
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
            .onChange(of: self.displayTimeMs) { _, _ in
                self.updateKaraokeAnchor()
            }
            .onChange(of: self.isPlaying) { _, nowPlaying in
                // Reanchor on both transitions: freezing must capture the
                // current interpolated position (not rewind to the last line
                // boundary), and resuming must not count paused time.
                if !nowPlaying {
                    if self.anchorMs >= 0 {
                        self.anchorMs += Int(Date().timeIntervalSince(self.anchorDate) * 1000)
                        self.anchorDate = Date()
                    }
                } else {
                    self.anchorDate = Date()
                }
            }
        }
    }

    private func updateKaraokeAnchor() {
        guard let displayTimeMs else { return }
        self.anchorMs = displayTimeMs
        self.anchorDate = Date()
    }

    private func currentStatus(for line: SyncedLyricLine, at lineIndex: Int) -> SyncedLyrics.LineStatus {
        if let currentLineIndex, self.lyrics.lines.indices.contains(currentLineIndex) {
            if lineIndex < currentLineIndex {
                return .previous
            }
            if lineIndex > currentLineIndex {
                return .upcoming
            }
            return .current
        }

        return line.timeInMs <= self.effectiveDisplayTimeMs ? .previous : .upcoming
    }
}

// MARK: - SyncedLineView

struct SyncedLineView: View {
    let line: SyncedLyricLine
    let status: SyncedLyrics.LineStatus
    let onTap: () -> Void
    /// Translation of this line; nil when untranslated or translation is off.
    var translation: String?
    /// Multiplier applied to the base font sizes (grows with the panel width).
    var fontSizeScale: CGFloat = 1.0
    /// Live playback time for karaoke highlighting; nil when no time source.
    var displayTimeProvider: (() -> Int)?

    /// Base font sizes at scale 1. Every line is laid out at the same size
    /// regardless of status, so text never re-wraps when a line becomes
    /// current; inactive lines are visually scaled down instead.
    private var originalFontSize: CGFloat {
        26 * self.fontSizeScale
    }

    private var romanizedFontSize: CGFloat {
        18 * self.fontSizeScale
    }

    private var translationFontSize: CGFloat {
        17 * self.fontSizeScale
    }

    /// Smooth transition
    private let animation = Animation.spring(response: 0.4, dampingFraction: 0.8)

    var body: some View {
        VStack(spacing: 4) {
            // Original text (karaoke-animated when the line has word timings)
            self.lyricText

            // Romanized text (only if present and differs from original)
            if let romaji = self.line.romanizedText {
                Text(romaji)
                    .font(.system(size: self.romanizedFontSize, weight: .regular, design: .default))
                    .italic()
                    .foregroundStyle(self.status == .current ? .secondary : .tertiary)
                    .opacity(self.status == .current ? 0.8 : 0.5)
            }

            // Translation (plain, so it reads distinct from the romanization)
            if let translation = self.translation {
                Text(translation)
                    .font(.system(size: self.translationFontSize, weight: .regular, design: .default))
                    .foregroundStyle(self.status == .current ? .secondary : .tertiary)
                    .opacity(self.status == .current ? 0.9 : 0.55)
            }
        }
        .opacity(self.status == .current ? 1.0 : (self.status == .previous ? 0.6 : 0.4))
        // Inactive lines are scaled down inside their full-size layout box, so
        // the wrap never changes between the active and inactive states.
        .scaleEffect(self.status == .current ? 1.0 : 0.8)
        .blur(radius: self.status == .current ? 0 : 0.5)
        .animation(self.animation, value: self.status)
        .multilineTextAlignment(.center)
        .lineLimit(nil)
        // Use content shape to allow tapping on empty space around text too
        .contentShape(Rectangle())
        .onTapGesture {
            self.onTap()
        }
        .padding(.vertical, 4)
    }

    /// Line text, karaoke-styled when word timings and a live clock are
    /// available, plain otherwise. Karaoke styling only changes color and
    /// underline — never size or weight — so the wrap stays stable.
    @ViewBuilder private var lyricText: some View {
        if self.status == .current,
           let words = self.line.words,
           !words.isEmpty,
           let displayTimeProvider = self.displayTimeProvider
        {
            TimelineView(.animation) { _ in
                let attributed = self.karaokeAttributedString(at: displayTimeProvider())
                Text(attributed)
                    .font(.system(size: self.originalFontSize, weight: .semibold, design: .default))
            }
        } else {
            Text(self.line.text.isEmpty ? "♪" : self.line.text)
                .font(.system(size: self.originalFontSize, weight: .semibold, design: .default))
                .foregroundStyle(self.status == .current ? .primary : (self.status == .previous ? .secondary : .tertiary))
        }
    }

    // MARK: Karaoke attribution

    private struct WordSpan {
        let range: Range<String.Index>
        let word: TimedWord
    }

    /// Maps word timings onto character ranges of `line.text`. Returns nil when
    /// the words do not concatenate to exactly the line text (then no karaoke).
    private func wordSpans() -> [WordSpan]? {
        let text = self.line.text
        var spans: [WordSpan] = []
        var offset = text.startIndex

        for word in self.line.words ?? [] {
            guard let end = text.index(offset, offsetBy: word.word.count, limitedBy: text.endIndex) else {
                return nil
            }
            spans.append(WordSpan(range: offset ..< end, word: word))
            offset = end
        }

        guard offset == text.endIndex else { return nil }
        return spans
    }

    /// Karaoke styling: unsung text dimmed, sung text bright, the currently
    /// sung syllable additionally underlined. Layout never changes.
    private func karaokeAttributedString(at timeMs: Int) -> AttributedString {
        guard let spans = self.wordSpans() else {
            return AttributedString(self.line.text)
        }

        var activeIndex: Int?
        for (index, span) in spans.enumerated() where span.word.timeInMs <= timeMs {
            activeIndex = index
        }

        var attributed = AttributedString()
        for (index, span) in spans.enumerated() {
            var chunk = AttributedString(String(self.line.text[span.range]))
            chunk.foregroundColor = index <= (activeIndex ?? -1) ? Color.primary : Color.secondary
            if index == activeIndex {
                chunk.underlineStyle = .single
            }
            attributed.append(chunk)
        }

        return attributed
    }
}
