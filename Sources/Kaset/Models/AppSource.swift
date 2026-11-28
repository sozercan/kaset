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

enum AppExperience: String, CaseIterable, Identifiable {
    case both
    case musicOnly
    case videoOnly

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .both:
            String(localized: "Music & YouTube")
        case .musicOnly:
            String(localized: "Music Only")
        case .videoOnly:
            String(localized: "YouTube Only")
        }
    }

    var includesMusic: Bool {
        self != .videoOnly
    }

    var includesVideo: Bool {
        self != .musicOnly
    }

    var showsSourceToggle: Bool {
        self == .both
    }

    var enforcedSource: AppSource? {
        switch self {
        case .both:
            nil
        case .musicOnly:
            .music
        case .videoOnly:
            .video
        }
    }

    func resolvedSource(for requested: AppSource) -> AppSource {
        self.enforcedSource ?? requested
    }

    func allows(_ content: URLHandler.ParsedContent) -> Bool {
        switch content {
        case .song, .playlist, .album, .artist:
            self.includesMusic
        case .youtubeVideo:
            self.includesVideo
        }
    }
}
