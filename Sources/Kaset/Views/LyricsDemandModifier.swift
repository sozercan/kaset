import SwiftUI

// MARK: - LyricsDemandModifier

/// Registers a view's synced-lyrics demand with the shared `LyricsDemandCoordinator`
/// so multiple lyric surfaces can share high-frequency WebView polling safely.
private struct LyricsDemandModifier: ViewModifier {
    @Environment(\.lyricsDemandCoordinator) private var lyricsDemandCoordinator

    let consumerID: NowPlayingSurfaceID
    let result: LyricResult

    @State private var isActive = false

    func body(content: Content) -> some View {
        content
            .onChange(of: self.result) { _, newResult in
                self.setActive(Self.hasSyncedLyrics(newResult))
            }
            .onAppear {
                self.setActive(Self.hasSyncedLyrics(self.result))
            }
            .onDisappear {
                self.setActive(false)
            }
    }

    private func setActive(_ active: Bool) {
        guard self.isActive != active else { return }
        self.isActive = active
        self.lyricsDemandCoordinator?.setDemand(for: self.consumerID, isActive: active)
    }

    private static func hasSyncedLyrics(_ result: LyricResult) -> Bool {
        if case .synced = result { true } else { false }
    }
}

extension View {
    /// Drives synced-lyrics polling demand for the given consumer based on the current lyric result.
    func lyricsDemand(consumerID: NowPlayingSurfaceID, for result: LyricResult) -> some View {
        self.modifier(LyricsDemandModifier(consumerID: consumerID, result: result))
    }
}
