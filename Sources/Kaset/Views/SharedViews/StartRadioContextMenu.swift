import SwiftUI

@MainActor
enum StartRadioContextMenu {
    static func menuItem(for song: Song, queueEntryID: UUID? = nil, playerService: PlayerService) -> some View {
        Button {
            let intent = playerService.beginRadioPlaybackIntent(for: song, queueEntryID: queueEntryID)
            Task {
                await playerService.startRadio(song: song, queueEntryID: queueEntryID, intent: intent)
            }
        } label: {
            Label(String(localized: "Start Radio"), systemImage: "dot.radiowaves.left.and.right")
        }
    }
}
