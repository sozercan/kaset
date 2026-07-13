import SwiftUI

// MARK: - SyncedLyricsDisplayView

struct SyncedLyricsDisplayView: View {
    let lyrics: SyncedLyrics
    let currentLineIndex: Int?
    let displayTimeMs: Int?
    let onSeek: (Int) -> Void

    @State private var currentLineId: UUID?

    private var effectiveDisplayTimeMs: Int {
        self.displayTimeMs ?? -1
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
                            onTap: { self.onSeek(line.timeInMs) }
                        )
                        .id(line.id)
                    }

                    Spacer().frame(height: 150) // Bottom padding
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            .onChange(of: self.currentLineIndex, initial: true) { _, newLineIndex in
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
        }
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

    /// Smooth transition
    private let animation = Animation.spring(response: 0.4, dampingFraction: 0.8)

    var body: some View {
        VStack(spacing: 4) {
            // Original text
            Text(self.line.text.isEmpty ? "♪" : self.line.text)
                .font(.system(size: self.status == .current ? 26 : 20, weight: self.status == .current ? .bold : .medium, design: .default))
                .foregroundStyle(self.status == .current ? .primary : (self.status == .previous ? .secondary : .tertiary))

            // Romanized text (only if present and differs from original)
            if let romaji = self.line.romanizedText {
                Text(romaji)
                    .font(.system(size: self.status == .current ? 18 : 14, weight: .regular, design: .default))
                    .italic()
                    .foregroundStyle(self.status == .current ? .secondary : .tertiary)
                    .opacity(self.status == .current ? 0.8 : 0.5)
            }
        }
        .opacity(self.status == .current ? 1.0 : (self.status == .previous ? 0.6 : 0.4))
        .scaleEffect(self.status == .current ? 1.05 : 1.0)
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
}
