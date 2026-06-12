import Foundation

/// The active content source for the app-wide experience.
///
/// Kaset presents two parallel experiences over the same Google login:
/// YouTube Music (the default) and regular YouTube video. The source toggle
/// at the bottom of the sidebar flips between them. Switching sources only
/// swaps the visible surface — playback from the other source continues.
enum AppSource: String, CaseIterable, Identifiable {
    /// The YouTube Music experience (default).
    case music

    /// The regular YouTube video experience.
    case video

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .music:
            String(localized: "Music")
        case .video:
            String(localized: "YouTube")
        }
    }

    /// SF Symbol shown on the source toggle segment.
    var icon: String {
        switch self {
        case .music:
            "music.note"
        case .video:
            "play.rectangle.fill"
        }
    }
}
