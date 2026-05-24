import SwiftUI

// MARK: - DownloadContextMenu

/// Reusable context menu items for downloading/removing songs for offline access.
@available(macOS 26.0, *)
struct DownloadContextMenu: View {
    let song: Song

    var body: some View {
        if OfflineService.shared.isDownloaded(videoId: self.song.videoId) {
            Button(role: .destructive) {
                OfflineService.shared.removeSong(videoId: self.song.videoId)
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else {
            Button {
                OfflineService.shared.downloadSong(self.song)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
    }
}
