import Foundation

// MARK: - MusicPlaybackOccurrence

/// Identifies one playback of one Music media element.
///
/// Web occurrences are scoped to a committed document generation. Native
/// occurrences cover the interval before the observer binds a Web occurrence,
/// including deterministic unit-test playback.
struct MusicPlaybackOccurrence: Hashable {
    let documentGeneration: UInt64?
    let mediaGeneration: UInt64
    let nativeGeneration: UInt64
    let videoId: String?

    static func web(
        documentGeneration: UInt64,
        mediaGeneration: UInt64,
        nativeGeneration: UInt64 = 0,
        videoId: String? = nil
    ) -> Self {
        Self(
            documentGeneration: documentGeneration,
            mediaGeneration: mediaGeneration,
            nativeGeneration: nativeGeneration,
            videoId: videoId
        )
    }

    static func native(generation: UInt64, videoId: String? = nil) -> Self {
        Self(
            documentGeneration: nil,
            mediaGeneration: generation,
            nativeGeneration: generation,
            videoId: videoId
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.documentGeneration == rhs.documentGeneration
            && lhs.mediaGeneration == rhs.mediaGeneration
            && lhs.nativeGeneration == rhs.nativeGeneration
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.documentGeneration)
        hasher.combine(self.mediaGeneration)
        hasher.combine(self.nativeGeneration)
    }
}
