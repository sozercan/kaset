import Foundation

// MARK: - URLHandler

/// Handles parsing and routing of YouTube Music URLs.
///
/// Supports URLs like:
/// - `https://music.youtube.com/watch?v=dQw4w9WgXcQ` - Play song
/// - `https://music.youtube.com/playlist?list=PLxxx` - Open playlist
/// - `https://music.youtube.com/browse/MPRExxx` - Open album
/// - `https://music.youtube.com/browse/VLPLxxx` - Open playlist (browse format)
/// - `https://music.youtube.com/channel/UCxxx` - Open artist
/// - `kaset://play?v=dQw4w9WgXcQ` - Custom scheme for song
/// - `kaset://playlist?list=PLxxx` - Custom scheme for playlist
/// - `kaset://album?id=MPRExxx` - Custom scheme for album
/// - `kaset://artist?id=UCxxx` - Custom scheme for artist
enum URLHandler {
    // MARK: - Types

    /// Represents the type of content from a parsed URL.
    enum ParsedContent: Sendable, Equatable {
        /// A song/video to play.
        case song(videoId: String)

        /// A playlist to open.
        case playlist(id: String)

        /// An album to open.
        case album(id: String)

        /// An artist/channel to open.
        case artist(id: String)
    }

    // MARK: - URL Parsing

    /// Parses a YouTube Music URL and returns the content type.
    /// - Parameter url: The URL to parse.
    /// - Returns: The parsed content, or nil if the URL is not recognized.
    static func parse(_ url: URL) -> ParsedContent? {
        // Handle custom scheme
        if url.scheme == "kaset" {
            return self.parseKasetURL(url)
        }

        // Handle YouTube Music web URLs
        if self.isYouTubeMusicURL(url) {
            return self.parseYouTubeMusicURL(url)
        }

        return nil
    }

    /// Checks if a URL is a YouTube Music URL.
    private static func isYouTubeMusicURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "music.youtube.com" || host == "www.music.youtube.com"
    }

    /// Parses a kaset:// custom scheme URL.
    private static func parseKasetURL(_ url: URL) -> ParsedContent? {
        guard url.scheme == "kaset" else { return nil }

        let host = url.host?.lowercased() ?? ""
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        switch host {
        case "play":
            // kaset://play?v=videoId
            if let videoId = Self.queryValue(for: "v", in: queryItems), !videoId.isEmpty {
                return .song(videoId: videoId)
            }

        case "playlist":
            // kaset://playlist?list=playlistId
            if let listId = Self.queryValue(for: "list", in: queryItems), !listId.isEmpty {
                return .playlist(id: listId)
            }

        case "album":
            // kaset://album?id=albumId
            if let albumId = Self.queryValue(for: "id", in: queryItems), !albumId.isEmpty {
                return .album(id: albumId)
            }

        case "artist":
            // kaset://artist?id=artistId
            if let artistId = Self.queryValue(for: "id", in: queryItems), !artistId.isEmpty {
                return .artist(id: artistId)
            }

        default:
            break
        }

        return nil
    }

    /// Parses a music.youtube.com URL.
    private static func parseYouTubeMusicURL(_ url: URL) -> ParsedContent? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let path = url.path
        let pathLower = path.lowercased()

        // /watch?v=videoId - Play song
        if pathLower == "/watch" || pathLower.hasPrefix("/watch") {
            if let videoId = Self.queryValue(for: "v", in: queryItems), !videoId.isEmpty {
                return .song(videoId: videoId)
            }
        }

        // /playlist?list=playlistId - Open playlist
        if pathLower == "/playlist" || pathLower.hasPrefix("/playlist") {
            if let listId = Self.queryValue(for: "list", in: queryItems), !listId.isEmpty {
                return .playlist(id: listId)
            }
        }

        // /browse/XXX - Album, Playlist (VLPL prefix), or other browse content
        if pathLower.hasPrefix("/browse/") {
            // Extract browseId preserving original case
            let browseId = String(path.dropFirst("/browse/".count))
            if !browseId.isEmpty {
                // VLPL prefix indicates a playlist in browse format
                if browseId.hasPrefix("VLPL") {
                    // Convert VLPL... to PL... for playlist ID
                    let playlistId = String(browseId.dropFirst(2))
                    return .playlist(id: playlistId)
                }
                // MPRE or OLAK prefix indicates an album
                if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
                    return .album(id: browseId)
                }
                // UC prefix indicates a channel/artist
                if browseId.hasPrefix("UC") {
                    return .artist(id: browseId)
                }
                // Other browse IDs could be albums or playlists
                // Default to treating as album since it's under /browse
                return .album(id: browseId)
            }
        }

        // /channel/UCxxx - Open artist
        if pathLower.hasPrefix("/channel/") {
            // Extract channelId preserving original case
            let channelId = String(path.dropFirst("/channel/".count))
            if !channelId.isEmpty {
                return .artist(id: channelId)
            }
        }

        return nil
    }

    /// Gets a query parameter value.
    private static func queryValue(for name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name == name }?.value
    }
}
