import SwiftUI

// MARK: - StartRadioContextMenu

/// Shared context menu item for starting radio from a song.
@available(macOS 26.0, *)
@MainActor
enum StartRadioContextMenu {
    /// Creates a context menu button for starting radio based on a song.
    /// Starts playing the song immediately and loads similar songs in the background.
    @ViewBuilder
    static func menuItem(for song: Song, playerService: PlayerService) -> some View {
        Button {
            Task {
                await playerService.playWithRadio(song: song)
            }
        } label: {
            Label("Start Radio", systemImage: "dot.radiowaves.left.and.right")
        }
    }
}
