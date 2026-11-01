import SwiftUI

// MARK: - LyricsToggleButton

// Shared by the player bar and the now-playing showcase panel, which host
// the same controls (the bar hides its copy while the showcase is open).
// Callers add their own chrome (glass IDs) around these.

struct LyricsToggleButton: View {
    let player: PlayerService

    var body: some View {
        PlayerBarIconButton(
            action: {
                HapticService.toggle()
                withAnimation(AppAnimation.standard) {
                    self.player.showLyrics.toggle()
                }
            },
            isSelected: self.player.showLyrics,
            accessibilityID: AccessibilityID.PlayerBar.lyricsButton,
            accessibilityLabel: String(localized: "Lyrics"),
            accessibilityValue: self.player.showLyrics ? String(localized: "Showing") : String(localized: "Hidden"),
            icon: {
                Image(systemName: self.player.showLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 10, height: 16)
                    .foregroundStyle(self.player.showLyrics ? PackageResourceLookup.brandAccent : .primary)
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
                .disabled(!self.player.canShowCurrentTrackVideo)
        }
        .background {
            // A default macOS Button draws a bezel even with an empty label.
            Button(action: self.toggleVideo) { EmptyView() }
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!self.player.canShowCurrentTrackVideo)
        }
    }

    /// Closes an active video even if availability changes, gating only entry into video.
    private func toggleVideo() {
        guard self.player.canShowCurrentTrackVideo else { return }
        self.player.showVideo.toggle()
    }
}
