import SwiftUI

/// Line-by-line synced lyrics viewer for Spotlight presentation mode.
struct SpotlightLyricsDisplayView: View {
    let lyricsText: String?
    let currentTime: TimeInterval
    let onSeekToLine: (TimeInterval) -> Void

    @State private var parsedLines: [LyricLine] = []

    struct LyricLine: Identifiable {
        let id = UUID()
        let timestamp: TimeInterval
        let text: String
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    if self.parsedLines.isEmpty {
                        if let lyrics = self.lyricsText, !lyrics.isEmpty {
                            Text(lyrics)
                                .font(.system(size: 20, weight: .medium))
                                .lineSpacing(12)
                                .multilineTextAlignment(.center)
                                .padding(24)
                        } else {
                            ContentUnavailableView(
                                "No Lyrics Available",
                                systemImage: "quote.bubble",
                                description: Text("Synced lyrics are not available for this track.")
                            )
                            .padding(.top, 48)
                        }
                    } else {
                        ForEach(self.parsedLines) { line in
                            let isActive = self.isLineActive(line)
                            Text(line.text)
                                .font(.system(size: isActive ? 24 : 18, weight: isActive ? .bold : .regular))
                                .foregroundStyle(isActive ? Color.primary : Color.secondary.opacity(0.6))
                                .scaleEffect(isActive ? 1.05 : 1.0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
                                .multilineTextAlignment(.center)
                                .id(line.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    self.onSeekToLine(line.timestamp)
                                }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
            .onChange(of: self.currentTime) { _, newTime in
                if let activeLine = self.parsedLines.last(where: { $0.timestamp <= newTime }) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(activeLine.id, anchor: .center)
                    }
                }
            }
        }
        .task(id: self.lyricsText) {
            self.parseLRCContent()
        }
    }

    private func isLineActive(_ line: LyricLine) -> Bool {
        guard let index = self.parsedLines.firstIndex(where: { $0.id == line.id }) else { return false }
        let currentTimestamp = line.timestamp
        let nextTimestamp = (index + 1 < self.parsedLines.count) ? self.parsedLines[index + 1].timestamp : Double.infinity
        return self.currentTime >= currentTimestamp && self.currentTime < nextTimestamp
    }

    private func parseLRCContent() {
        guard let rawText = self.lyricsText else {
            self.parsedLines = []
            return
        }

        var lines: [LyricLine] = []
        let rawLines = rawText.components(separatedBy: .newlines)

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.contains("]") {
                let parts = trimmed.split(separator: "]", maxSplits: 1)
                if parts.count == 2 {
                    let timestampString = String(parts[0]).dropFirst()
                    let lyricString = String(parts[1]).trimmingCharacters(in: .whitespaces)

                    if let seconds = Self.parseTimestamp(String(timestampString)) {
                        lines.append(LyricLine(timestamp: seconds, text: lyricString))
                    }
                }
            }
        }

        self.parsedLines = lines.sorted(by: { $0.timestamp < $1.timestamp })
    }

    private static func parseTimestamp(_ timestamp: String) -> TimeInterval? {
        let components = timestamp.split(separator: ":")
        guard components.count == 2,
              let minutes = Double(components[0]),
              let seconds = Double(components[1]) else { return nil }
        return (minutes * 60.0) + seconds
    }
}
