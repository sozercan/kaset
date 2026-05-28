import SwiftUI

// MARK: - SyncedLyricsDisplayView

struct SyncedLyricsDisplayView: View {
    let lyrics: SyncedLyrics
    let currentTimeMs: Int
    var autoScrolls = true
    var scrollAnchor: UnitPoint = .top
    var verticalContentInset: CGFloat = 0
    let onSeek: (Int) -> Void

    @State private var currentLineId: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .center, spacing: 20) {
                    Spacer().frame(height: self.verticalContentInset)

                    ForEach(self.lyrics.lines) { line in
                        let status = self.currentStatus(for: line)
                        SyncedLineView(
                            line: line,
                            status: status,
                            onTap: { self.onSeek(line.timeInMs) }
                        )
                        .id(line.id)
                    }

                    Spacer().frame(height: self.verticalContentInset)
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                self.scrollToCurrentLine(proxy: proxy, timeMs: self.currentTimeMs, animated: false)
            }
            .onChange(of: self.lyrics) { _, _ in
                self.currentLineId = nil
                self.scrollToCurrentLine(proxy: proxy, timeMs: self.currentTimeMs, animated: false)
            }
            .onChange(of: self.currentTimeMs) { _, newTimeMs in
                guard self.autoScrolls else { return }
                self.scrollToCurrentLine(proxy: proxy, timeMs: newTimeMs, animated: true)
            }
        }
    }

    private func scrollToCurrentLine(proxy: ScrollViewProxy, timeMs: Int, animated: Bool) {
        guard let currentIdx = lyrics.currentLineIndex(at: timeMs) else { return }

        let newId = self.lyrics.lines[currentIdx].id
        guard newId != self.currentLineId else { return }

        self.currentLineId = newId
        let scroll = {
            proxy.scrollTo(newId, anchor: self.scrollAnchor)
        }

        if animated {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) {
                scroll()
            }
        } else {
            scroll()
        }
    }

    private func currentStatus(for line: SyncedLyricLine) -> SyncedLyrics.LineStatus {
        if line.timeInMs > self.currentTimeMs { return .upcoming }
        if self.currentTimeMs - line.timeInMs >= line.duration, line.duration > 0 { return .previous }
        return .current
    }
}

// MARK: - SyncedLineView

struct SyncedLineView: View {
    let line: SyncedLyricLine
    let status: SyncedLyrics.LineStatus
    let onTap: () -> Void

    private enum Metrics {
        static let lyricActiveFontSize: CGFloat = 26
        static let lyricInactiveFontSize: CGFloat = 20
        static let romanizedActiveFontSize: CGFloat = 18
        static let romanizedInactiveFontSize: CGFloat = 14

        static let lyricInactiveScale = Self.lyricInactiveFontSize / Self.lyricActiveFontSize
        static let romanizedInactiveScale = Self.romanizedInactiveFontSize / Self.romanizedActiveFontSize
    }

    /// Smooth transition
    private let animation = Animation.spring(response: 0.4, dampingFraction: 0.8)

    var body: some View {
        VStack(spacing: 4) {
            // Original text
            self.prewrappedText(
                self.line.text.isEmpty ? "♪" : self.line.text,
                activeFontSize: Metrics.lyricActiveFontSize,
                inactiveScale: Metrics.lyricInactiveScale,
                fontWeight: .bold
            )
            .foregroundStyle(self.primaryTextColor)

            // Romanized text (only if present and differs from original)
            if let romaji = self.line.romanizedText {
                self.prewrappedText(
                    romaji,
                    activeFontSize: Metrics.romanizedActiveFontSize,
                    inactiveScale: Metrics.romanizedInactiveScale,
                    fontWeight: .regular,
                    isItalic: true
                )
                .foregroundStyle(self.secondaryTextColor)
                .opacity(self.secondaryTextOpacity)
            }
        }
        .opacity(self.containerOpacity)
        .blur(radius: self.status == .current ? 0 : (self.status == .previous ? 1.0 : 0.15))
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

    private var primaryTextColor: Color {
        switch self.status {
        case .current:
            .primary
        case .upcoming:
            .secondary
        case .previous:
            Color.white.opacity(0.42)
        }
    }

    private var secondaryTextColor: Color {
        switch self.status {
        case .current:
            .secondary
        case .upcoming:
            .secondary
        case .previous:
            Color.white.opacity(0.28)
        }
    }

    private var containerOpacity: Double {
        switch self.status {
        case .current:
            1.0
        case .upcoming:
            0.85
        case .previous:
            0.34
        }
    }

    private var secondaryTextOpacity: Double {
        switch self.status {
        case .current:
            0.8
        case .upcoming:
            0.66
        case .previous:
            0.42
        }
    }

    private func prewrappedText(
        _ text: String,
        activeFontSize: CGFloat,
        inactiveScale: CGFloat,
        fontWeight: Font.Weight,
        isItalic: Bool = false
    ) -> some View {
        ZStack {
            self.lyricText(
                text,
                fontSize: activeFontSize,
                fontWeight: fontWeight,
                isItalic: isItalic
            )
            .hidden()
            .accessibilityHidden(true)

            self.lyricText(
                text,
                fontSize: activeFontSize,
                fontWeight: fontWeight,
                isItalic: isItalic
            )
            .scaleEffect(self.status == .current ? 1 : inactiveScale, anchor: .center)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func lyricText(
        _ text: String,
        fontSize: CGFloat,
        fontWeight: Font.Weight,
        isItalic: Bool
    ) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: fontWeight, design: .default))
            .italic(isItalic)
    }
}
