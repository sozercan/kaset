import SwiftUI

// MARK: - SyncedLyricsDisplayView

struct SyncedLyricsDisplayView: View {
    let lyrics: SyncedLyrics
    let currentTimeMs: Int
    let onSeek: (Int) -> Void

    @State private var currentLineId: UUID?
    /// Whether the user has manually scrolled (pauses auto-scroll).
    @State private var userIsScrolling = false
    /// Timer task to resume auto-scroll after user interaction.
    @State private var scrollResumeTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Spacer().frame(height: 60)

                    ForEach(Array(self.lyrics.lines.enumerated()), id: \.element.id) { _, line in
                        let status = self.currentStatus(for: line)
                        SyncedLineView(
                            line: line,
                            status: status,
                            onTap: { self.onSeek(line.timeInMs) }
                        )
                        .id(line.id)
                    }

                    Spacer().frame(height: 120)
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        self.userIsScrolling = true
                        self.scrollResumeTask?.cancel()
                    }
                    .onEnded { _ in
                        self.scrollResumeTask = Task {
                            try? await Task.sleep(for: .seconds(4))
                            if !Task.isCancelled {
                                self.userIsScrolling = false
                            }
                        }
                    }
            )
            .onChange(of: self.currentTimeMs) { _, newTimeMs in
                if let currentIdx = lyrics.currentLineIndex(at: newTimeMs) {
                    let newId = self.lyrics.lines[currentIdx].id
                    if newId != self.currentLineId {
                        self.currentLineId = newId
                        if !self.userIsScrolling {
                            withAnimation(.spring(duration: 0.45, bounce: 0.0)) {
                                proxy.scrollTo(newId, anchor: .center)
                            }
                        }
                    }
                }
            }
            .onDisappear {
                self.scrollResumeTask?.cancel()
            }
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
        if self.line.text.trimmingCharacters(in: .whitespaces).isEmpty {
            HStack(spacing: 6) {
                ForEach(0 ..< 3, id: \.self) { dotIndex in
                    Circle()
                        .fill(Color.primary.opacity(self.status == .current ? 0.9 : 0.25))
                        .frame(width: 5, height: 5)
                        .scaleEffect(self.status == .current ? 1.4 : 1.0)
                        .animation(
                            self.status == .current
                                ? .easeInOut(duration: 0.5)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(dotIndex) * 0.15)
                                : .easeOut(duration: 0.3),
                            value: self.status
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        } else {
            Text(self.line.text)
                .font(.system(size: 16, weight: .bold))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.primary)
                .opacity(self.status == .current ? 1.0 : (self.status == .previous ? 0.3 : 0.45))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .animation(self.animation, value: self.status)
                .contentShape(Rectangle())
                .onTapGesture {
                    self.onTap()
                }
        }
    }
}
