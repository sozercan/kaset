import SwiftUI

// MARK: - CompactVisibleActionButtons

/// The always-visible action buttons shown in the player bar's compact layout
/// (narrow windows, below `PlayerBar.compactLayoutThreshold`). Extracted from
/// `PlayerBar.swift` to keep that file under the file-length limit.
struct CompactVisibleActionButtons: View {
    let playerNamespace: Namespace.ID

    @Environment(PlayerService.self) private var playerService

    var body: some View {
        @Bindable var player = self.playerService

        HStack(spacing: 12) {
            Button {
                HapticService.toggle()
                self.playerService.dislikeCurrentTrack()
            } label: {
                Image(systemName: self.playerService.currentTrackLikeStatus == .dislike
                    ? "hand.thumbsdown.fill"
                    : "hand.thumbsdown")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.currentTrackLikeStatus == .dislike ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .symbolEffect(.bounce, value: self.playerService.currentTrackLikeStatus == .dislike)
            .accessibilityLabel(String(localized: "Dislike"))
            .accessibilityValue(self.playerService.currentTrackLikeStatus == .dislike ? String(localized: "Disliked") : String(localized: "Not disliked"))
            .disabled(self.playerService.currentTrack == nil)

            Button {
                HapticService.toggle()
                self.playerService.likeCurrentTrack()
            } label: {
                Image(systemName: self.playerService.currentTrackLikeStatus == .like
                    ? "hand.thumbsup.fill"
                    : "hand.thumbsup")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.currentTrackLikeStatus == .like ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .symbolEffect(.bounce, value: self.playerService.currentTrackLikeStatus == .like)
            .accessibilityLabel(String(localized: "Like"))
            .accessibilityValue(self.playerService.currentTrackLikeStatus == .like ? String(localized: "Liked") : String(localized: "Not liked"))
            .disabled(self.playerService.currentTrack == nil)

            Button {
                HapticService.toggle()
                withAnimation(AppAnimation.standard) {
                    player.showLyrics.toggle()
                }
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.showLyrics ? .red : .primary.opacity(0.85))
            }
            .buttonStyle(.pressable)
            .compatGlassID("compactLyrics", in: self.playerNamespace)
            .accessibilityIdentifier(AccessibilityID.PlayerBar.lyricsButton)
            .accessibilityLabel(String(localized: "Lyrics"))
            .accessibilityValue(self.playerService.showLyrics ? String(localized: "Showing") : String(localized: "Hidden"))

            Button {
                guard self.playerService.currentTrackHasVideo else { return }
                HapticService.toggle()
                DiagnosticsLogger.player.debug(
                    "Video button clicked, toggling showVideo from \(self.playerService.showVideo)"
                )
                withAnimation(AppAnimation.standard) {
                    player.showVideo.toggle()
                }
            } label: {
                Image(systemName: self.playerService.showVideo ? "tv.fill" : "tv")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(self.playerService.showVideo ? .red : .primary.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .compatGlassID("compactVideo", in: self.playerNamespace)
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .accessibilityIdentifier(AccessibilityID.PlayerBar.videoButton)
            .accessibilityLabel(String(localized: "Video"))
            .accessibilityValue(self.playerService.showVideo ? String(localized: "Playing") : String(localized: "Off"))
            .disabled(self.playerService.currentTrack == nil || !self.playerService.currentTrackHasVideo)

            // Resolution picker — also exposed in compact layout so narrow
            // windows can change video quality (mirrors the standard bar).
            if self.playerService.showVideo, !self.playerService.videoQualityLevels.isEmpty {
                VideoQualityMenu(player: self.playerService)
            }
        }
    }
}
