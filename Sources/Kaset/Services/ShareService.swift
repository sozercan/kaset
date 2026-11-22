import Foundation

/// Protocol for items that can be shared with a URL and formatted text.
protocol Shareable {
    /// The title to display in share text.
    var shareTitle: String { get }

    /// Optional subtitle (e.g., artist/author). Nil for artists.
    var shareSubtitle: String? { get }

    /// The YouTube Music URL for sharing. Nil if not shareable.
    var shareURL: URL? { get }
}

extension Shareable {
    /// Formatted share text: "Title by Artist" or just "Title" if no subtitle.
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
        // Only albums with navigable IDs (MPRE or OLAK prefixes) can be shared
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
        nil // Artists don't have a subtitle
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
        // Podcast show IDs start with "MPSPP" prefix
        guard self.hasNavigableId else { return nil }
        guard let encodedId = self.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://music.youtube.com/browse/\(encodedId)")
    }
}
