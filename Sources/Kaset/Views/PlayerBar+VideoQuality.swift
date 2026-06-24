import SwiftUI

// MARK: - VideoQualityMenu

/// Resolution menu for music video mode. Mirrors the YouTube side's quality
/// menu and reuses ``YouTubeQuality/displayName(for:)`` since the music
/// `#movie_player` reports the same level identifiers.
///
/// A standalone view so both the standard player bar (`PlayerBar.actionButtons`)
/// and the compact layout (`CompactVisibleActionButtons`) can render the same
/// picker. Callers gate visibility on `showVideo && !videoQualityLevels.isEmpty`.
struct VideoQualityMenu: View {
    let player: PlayerService

    var body: some View {
        Menu {
            ForEach(self.player.videoQualityLevels, id: \.self) { level in
                Button {
                    self.player.selectVideoQuality(level)
                } label: {
                    if self.player.currentVideoQuality == level {
                        Label(YouTubeQuality.displayName(for: level), systemImage: "checkmark")
                    } else {
                        Text(YouTubeQuality.displayName(for: level))
                    }
                }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.PlayerBar.videoQualityButton)
        .accessibilityLabel(String(localized: "Video quality"))
    }
}
