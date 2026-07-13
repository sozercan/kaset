import SwiftUI

extension View {
    /// Marks this view as a drag source for `song` — e.g. to drop onto a sidebar playlist.
    ///
    /// The single seam for song drag behaviour: every song row and card routes through here, so a
    /// shared drag preview (or any change to how a song drags) has one place to live. Passing `nil`
    /// leaves the view undraggable.
    @ViewBuilder
    func songDraggable(_ song: Song?) -> some View {
        if let song {
            self.draggable(song)
        } else {
            self
        }
    }
}
