import Foundation

protocol Shareable {
    var shareTitle: String { get }

    var shareSubtitle: String? { get }

    var shareURL: URL? { get }
}

extension Shareable {
    var shareText: String {
        if let subtitle = shareSubtitle, !subtitle.isEmpty {
            return "\(shareTitle) by \(subtitle)"
        }
        return shareTitle
    }
}

extension Song: Shareable {
    var shareTitle: String {
        self.title
    }

    var shareSubtitle: String? {
        self.artistsDisplay
    }

    var shareURL: URL? {
        guard let encodedId = self.videoId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "https://music.youtube.com/watch?v=\(encodedId)")
    }
}

extension Playlist: Shareable {
    var shareTitle: String {
        self.title
    }

    var shareSubtitle: String? {
        self.author?.name
    }

    var shareURL: URL? {
        guard let encodedId = self.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "https://music.youtube.com/playlist?list=\(encodedId)")
    }
}

extension Album: Shareable {
    var shareTitle: String {
        self.title
    }

    var shareSubtitle: String? {
        self.artistsDisplay
    }

    var shareURL: URL? {
        guard self.hasNavigableId else { return nil }
        guard let encodedId = self.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://music.youtube.com/browse/\(encodedId)")
    }
}

extension Artist: Shareable {
    var shareTitle: String {
        self.name
    }

    var shareSubtitle: String? {
        nil
    }

    var shareURL: URL? {
        guard let publicChannelId = self.publicChannelId,
              let encodedId = publicChannelId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            return nil
        }

        return URL(string: "https://music.youtube.com/channel/\(encodedId)")
    }
}

extension PodcastShow: Shareable {
    var shareTitle: String {
        self.title
    }

    var shareSubtitle: String? {
        self.author
    }

    var shareURL: URL? {
        guard self.hasNavigableId else { return nil }
        guard let encodedId = self.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://music.youtube.com/browse/\(encodedId)")
    }
}
