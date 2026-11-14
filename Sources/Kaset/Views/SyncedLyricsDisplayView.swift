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
                LazyVStack(alignment: .leading, spacing: 20) {
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
                            displayTimeProvider: self.karaokeTimeMs,
                            isPlaying: self.isPlaying
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

    /// Reanchors interpolation to the latest observed playback time.
    private func updateKaraokeAnchor() {
        guard let displayTimeMs else { return }
        self.anchorMs = displayTimeMs
        self.anchorDate = Date()
    }

    /// Classifies each lyric line relative to the currently active line.
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

    /// Pauses display-link work while transport is stopped.
    var isPlaying = true

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
        VStack(alignment: .leading, spacing: 4) {
            if self.isKaraokeActive, let displayTimeProvider = self.displayTimeProvider {
                // One TimelineView drives both the original line and its
                // romanization so the sweep fronts stay in lockstep.
                TimelineView(.animation(paused: !self.isPlaying)) { _ in
                    let timeMs = displayTimeProvider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(self.sweptOriginal(at: timeMs))
                            .font(.system(size: self.originalFontSize, weight: .semibold, design: .default))
                        if let romaji = self.line.romanizedText {
                            Text(self.sweptRomanized(at: timeMs, text: romaji))
                                .font(.system(size: self.romanizedFontSize, weight: .regular, design: .default))
                                .foregroundStyle(.secondary)
                                .romanizationPill()
                        }
                    }
                }
            } else {
                // Original text (plain when no word timings or live clock)
                self.plainLyricText

                // Romanization in a capsule pill, matching the web client
                if let romaji = self.line.romanizedText {
                    Text(romaji)
                        .font(.system(size: self.romanizedFontSize, weight: .regular, design: .default))
                        .foregroundStyle(self.status == .current ? .secondary : .tertiary)
                        .romanizationPill()
                }
            }

            // Translation tier: bright on the current line, dimmed elsewhere
            if let translation = self.translation {
                Text(translation)
                    .font(.system(size: self.translationFontSize, weight: .regular, design: .default))
                    .foregroundStyle(self.status == .current ? .secondary : .tertiary)
            }
        }
        .opacity(self.status == .current ? 1.0 : (self.status == .previous ? 0.6 : 0.4))
        // Inactive lines are scaled down inside their full-size layout box, so
        // the wrap never changes between the active and inactive states.
        .scaleEffect(self.status == .current ? 1.0 : 0.9)
        .animation(self.animation, value: self.status)
        .multilineTextAlignment(.leading)
        .lineLimit(nil)
        // Use content shape to allow tapping on empty space around text too
        .contentShape(Rectangle())
        .onTapGesture {
            self.onTap()
        }
        .padding(.vertical, 4)
    }

    /// Karaoke is live when the current line carries usable word timings and a clock.
    private var isKaraokeActive: Bool {
        self.status == .current
            && self.displayTimeProvider != nil
            && !(self.line.words ?? []).isEmpty
            && self.sweepPlan() != nil
    }

    private var plainLyricText: some View {
        Text(self.line.text.isEmpty ? "♪" : self.line.text)
            .font(.system(size: self.originalFontSize, weight: .semibold, design: .default))
            .foregroundStyle(self.status == .current ? .primary : (self.status == .previous ? .secondary : .tertiary))
    }

    // MARK: Karaoke sweep

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

    /// The brightening front's character position at `timeMs`.
    private func sweepFront(at timeMs: Int, totalCharacters: Int, keyframes: [LyricsKaraokeSweep.Keyframe]) -> Double {
        LyricsKaraokeSweep.front(at: timeMs, totalCharacters: totalCharacters, keyframes: keyframes)
    }

    /// Brightness for the character at `index`.
    private func sungAlpha(front: Double, index: Int, dim: Double, bright: Double) -> Double {
        LyricsKaraokeSweep.sungAlpha(front: front, index: index, dim: dim, bright: bright)
    }

    /// Precomputed sweep geometry, cached per line so the 60fps TimelineView
    /// frames only assign per-character colors instead of re-deriving spans
    /// and keyframes every frame.
    private final class SweepPlan {
        let keyframes: [LyricsKaraokeSweep.Keyframe]
        let chunkTexts: [String]
        let chunkStartOffsets: [Int]
        let totalCharacters: Int

        init(
            keyframes: [LyricsKaraokeSweep.Keyframe],
            chunkTexts: [String],
            chunkStartOffsets: [Int],
            totalCharacters: Int
        ) {
            self.keyframes = keyframes
            self.chunkTexts = chunkTexts
            self.chunkStartOffsets = chunkStartOffsets
            self.totalCharacters = totalCharacters
        }
    }

    private static let sweepPlanCache = NSCache<NSString, SweepPlan>()

    private func sweepPlan() -> SweepPlan? {
        let cacheKey = self.line.id.uuidString as NSString
        if let cached = Self.sweepPlanCache.object(forKey: cacheKey) {
            return cached
        }
        guard let spans = self.wordSpans(), !spans.isEmpty else { return nil }
        let text = self.line.text
        var keyframes: [LyricsKaraokeSweep.Keyframe] = []
        var chunkTexts: [String] = []
        var chunkStartOffsets: [Int] = []
        for span in spans {
            let offset = text.distance(from: text.startIndex, to: span.range.lowerBound)
            keyframes.append(LyricsKaraokeSweep.Keyframe(timeMs: span.word.timeInMs, offset: Double(offset)))
            chunkTexts.append(String(text[span.range]))
            chunkStartOffsets.append(offset)
        }
        let lineEndMs = self.line.timeInMs + max(self.line.duration, 0)
        keyframes.append(LyricsKaraokeSweep.Keyframe(timeMs: lineEndMs, offset: Double(text.count)))
        let plan = SweepPlan(
            keyframes: keyframes,
            chunkTexts: chunkTexts,
            chunkStartOffsets: chunkStartOffsets,
            totalCharacters: text.count
        )
        Self.sweepPlanCache.setObject(plan, forKey: cacheKey)
        return plan
    }

    /// The line's text with the sweep applied: color only, never size or weight,
    /// so wrapping is identical to the plain rendering.
    private func sweptOriginal(at timeMs: Int) -> AttributedString {
        guard let plan = self.sweepPlan() else {
            return AttributedString(self.line.text)
        }
        let front = LyricsKaraokeSweep.front(
            at: timeMs, totalCharacters: plan.totalCharacters, keyframes: plan.keyframes
        )

        var attributed = AttributedString()
        for (index, chunkText) in plan.chunkTexts.enumerated() {
            var chunk = AttributedString(chunkText)
            // Floor of 0.55 keeps the current line reading as fully present
            // (web-client look) while the sweep still shows progress.
            let alpha = self.sungAlpha(front: front, index: plan.chunkStartOffsets[index], dim: 0.55, bright: 1.0)
            chunk.foregroundColor = Color.primary.opacity(alpha)
            attributed.append(chunk)
        }
        return attributed
    }

    /// The romanization shares the original line's sweep progress, mapped
    /// proportionally over its own length (the data model has no separate
    /// romanized word timings).
    private func sweptRomanized(at timeMs: Int, text: String) -> AttributedString {
        guard let plan = self.sweepPlan(), !text.isEmpty else {
            return AttributedString(text)
        }
        let front = LyricsKaraokeSweep.front(
            at: timeMs, totalCharacters: plan.totalCharacters, keyframes: plan.keyframes
        )
        let romanFront = front / Double(max(plan.totalCharacters, 1)) * Double(text.count)

        var attributed = AttributedString()
        for (index, character) in text.enumerated() {
            var chunk = AttributedString(String(character))
            let alpha = self.sungAlpha(front: romanFront, index: index, dim: 0.55, bright: 0.85)
            chunk.foregroundColor = Color.primary.opacity(alpha)
            attributed.append(chunk)
        }
        return attributed
    }
}

// MARK: - RomanizationPill

private extension View {
    /// The translucent capsule behind romanized lyric lines, matching the
    /// web client's romaji badge.
    func romanizationPill() -> some View {
        self.padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
    }
}

// MARK: - LyricsKaraokeSweep

/// Pure math for the Apple Music-style karaoke sweep, internal for unit tests.
enum LyricsKaraokeSweep {
    struct Keyframe: Equatable {
        let timeMs: Int
        let offset: Double
    }

    /// The brightening front's character position at `timeMs`: linearly
    /// interpolated between word-timing keyframes, so it speeds up and slows
    /// down with the singer instead of stepping word by word.
    static func front(
        at timeMs: Int,
        totalCharacters: Int,
        keyframes: [Keyframe]
    ) -> Double {
        guard let first = keyframes.first else { return 0 }
        if timeMs <= first.timeMs {
            return 0
        }
        if let last = keyframes.last, timeMs >= last.timeMs {
            return Double(totalCharacters)
        }
        for (index, keyframe) in keyframes.enumerated() where keyframe.timeMs > timeMs {
            let previous = keyframes[max(index - 1, 0)]
            let span = keyframe.timeMs - previous.timeMs
            guard span > 0 else { return keyframe.offset }
            let fraction = Double(timeMs - previous.timeMs) / Double(span)
            return previous.offset + (keyframe.offset - previous.offset) * fraction
        }
        return Double(totalCharacters)
    }

    /// Brightness for the character at `index`: fully dim ahead of the front,
    /// fully bright behind it, smoothstep-eased across a few-character window.
    static func sungAlpha(front: Double, index: Int, dim: Double, bright: Double) -> Double {
        let feather = 3.0
        let x = min(max((front - Double(index)) / feather + 0.5, 0), 1)
        let eased = x * x * (3 - 2 * x)
        return dim + (bright - dim) * eased
    }
}
