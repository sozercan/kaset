import SwiftUI

@MainActor
enum StartRadioContextMenu {
    static func menuItem(for song: Song, playerService: PlayerService) -> some View {
        Button {
            let intent = playerService.beginRadioPlaybackIntent(for: song)
            Task {
                await playerService.playWithRadio(song: song, intent: intent)
            }
        } label: {
            Label(String(localized: "Start Radio"), systemImage: "dot.radiowaves.left.and.right")
        }
    }
}
