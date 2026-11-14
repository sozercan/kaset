import SwiftUI

// MARK: - LyricsToggleButton

// Shared by the player bar and the now-playing showcase panel, which host
// the same controls. While the showcase is open, the bar's copies morph the
// showcase's panel in place.
// Callers add their own chrome (glass IDs) around these.

struct LyricsToggleButton: View {
    let player: PlayerService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// While the showcase is open the lyrics surface lives in the morphing
    /// panel, so the button reflects panel state — the showcase didSets reset
    /// the side-panel flag the moment it opens.
    private var isLyricsShowing: Bool {
        if self.player.showNowPlayingShowcase {
            return self.player.nowPlayingPanel == .lyrics
        }
        return self.player.showLyrics
    }

    var body: some View {
        PlayerBarIconButton(
            action: {
                HapticService.toggle()
                // Mirrors the showcase tab path: no tween when opening from a
                // collapsed panel or under reduce motion.
                let swapsPanel = self.player.showNowPlayingShowcase && self.player.nowPlayingPanel != nil
                withAnimation(swapsPanel && !self.reduceMotion ? AppAnimation.quick : nil) {
                    self.player.showLyrics.toggle()
                }
            },
            isSelected: self.isLyricsShowing,
            accessibilityID: AccessibilityID.PlayerBar.lyricsButton,
            accessibilityLabel: String(localized: "Lyrics"),
            accessibilityValue: self.isLyricsShowing ? String(localized: "Showing") : String(localized: "Hidden"),
            icon: {
                Image(systemName: self.isLyricsShowing ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 10, height: 16)
                    .foregroundStyle(self.isLyricsShowing ? PackageResourceLookup.brandAccent : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
        )
    }
}

// MARK: - MiniPlayerToggleButton

struct MiniPlayerToggleButton: View {
    let player: PlayerService
    var size: CGFloat = 28

    var body: some View {
        PlayerBarIconButton(
            action: {
                HapticService.toggle()
                self.player.showVideo = false
                _ = self.player.toggleMiniPlayer(mode: .switchFromMainWindow)
            },
            isSelected: self.player.isMiniPlayerVisible,
            size: self.size,
            accessibilityID: AccessibilityID.PlayerBar.miniPlayerButton,
            accessibilityLabel: self.player.isMiniPlayerVisible ? String(localized: "Return to Kaset") : String(localized: "Switch to Mini Player"),
            accessibilityValue: self.player.isMiniPlayerVisible ? String(localized: "Showing") : String(localized: "Hidden"),
            icon: {
                Image(systemName: self.player.isMiniPlayerVisible ? "arrow.up.left.and.arrow.down.right" : "macwindow")
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 15, height: 15)
                    .foregroundStyle(self.player.isMiniPlayerVisible ? PackageResourceLookup.brandAccent : .primary)
                    .contentTransition(.symbolEffect(.replace))
            }
        )
        .contextMenu {
            Button(self.player.showVideo ? String(localized: "Hide Video") : String(localized: "Video"), action: self.toggleVideo)
                .disabled(!self.player.showVideo && !self.player.canShowLoadedTrackVideo)
        }
        .background {
            // A default macOS Button draws a bezel even with an empty label.
            Button(action: self.toggleVideo) { EmptyView() }
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!self.player.showVideo && !self.player.canShowLoadedTrackVideo)
        }
    }

    /// Closing stays available even when extraction temporarily hides video-availability evidence.
    private func toggleVideo() {
        guard self.player.showVideo || self.player.canShowLoadedTrackVideo else { return }
        self.player.showVideo.toggle()
    }
}
