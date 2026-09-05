import SwiftUI

/// A small toast-style view that appears when mini player is shown.
/// Uses Liquid Glass materialize transition for smooth appearance.
struct MiniPlayerToast: View {
    let videoId: String

    var body: some View {
        PersistentPlayerView(videoId: self.videoId, isExpanded: true)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .compatGlassTransition(.materialize)
    }
}
