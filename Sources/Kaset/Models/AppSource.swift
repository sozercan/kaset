import Foundation

enum AppSource: String, CaseIterable, Identifiable {
    case music

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

    var icon: String {
        switch self {
        case .music:
            "music.note"
        case .video:
            "play.rectangle.fill"
        }
    }
}
