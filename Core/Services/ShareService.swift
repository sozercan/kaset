import Foundation

// MARK: - Shareable

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

// MARK: - Song + Shareable

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

// MARK: - Playlist + Shareable

extension Playlist: Shareable {
    var shareTitle: String {
        self.title
    }

    var shareSubtitle: String? {
        self.author
    }

    var shareURL: URL? {
        guard let encodedId = self.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "https://music.youtube.com/playlist?list=\(encodedId)")
    }
}

// MARK: - Album + Shareable

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

// MARK: - Artist + Shareable

extension Artist: Shareable {
    var shareTitle: String {
        self.name
    }

    var shareSubtitle: String? {
        nil // Artists don't have a subtitle
    }

    var shareURL: URL? {
        // Valid artist IDs start with "UC" and don't contain hyphens (UUIDs)
        guard self.id.hasPrefix("UC"), !self.id.contains("-") else { return nil }
        guard let encodedId = self.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://music.youtube.com/channel/\(encodedId)")
    }
}

// MARK: - PodcastShow + Shareable

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
