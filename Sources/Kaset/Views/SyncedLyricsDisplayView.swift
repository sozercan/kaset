import SwiftUI

// MARK: - SyncedLyricsDisplayView

struct SyncedLyricsDisplayView: View {
    let lyrics: SyncedLyrics
    let currentTimeMs: Int
    let onSeek: (Int) -> Void

    @State private var currentLineId: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .center, spacing: 20) {
                    Spacer().frame(height: 150) // Top padding

                    ForEach(self.lyrics.lines) { line in
                        let status = self.currentStatus(for: line)
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
            .onAppear {
                self.scrollToCurrentLine(proxy: proxy, timeMs: self.currentTimeMs, animated: false)
            }
            .onChange(of: self.lyrics) { _, _ in
                self.currentLineId = nil
                self.scrollToCurrentLine(proxy: proxy, timeMs: self.currentTimeMs, animated: false)
            }
            .onChange(of: self.currentTimeMs) { _, newTimeMs in
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
            proxy.scrollTo(newId, anchor: .center)
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
