import Foundation

enum URLHandler {
    enum ParsedContent: Equatable {
        case song(videoId: String)

        case playlist(id: String)

        case album(id: String)

        case artist(id: String)

        case youtubeVideo(videoId: String)
    }

    static func parse(_ url: URL) -> ParsedContent? {
        if url.scheme == "kaset" {
            return self.parseKasetURL(url)
        }

        if self.isYouTubeMusicURL(url) {
            return self.parseYouTubeMusicURL(url)
        }

        if let youtubeContent = parseYouTubeVideoURL(url) {
            return youtubeContent
        }

        return nil
    }

    private static func isYouTubeMusicURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "music.youtube.com" || host == "www.music.youtube.com"
    }

    private static func parseYouTubeVideoURL(_ url: URL) -> ParsedContent? {
        guard let host = url.host?.lowercased() else { return nil }

        if host == "youtu.be" {
            let videoId = url.pathComponents.dropFirst().first ?? ""
            return videoId.isEmpty ? nil : .youtubeVideo(videoId: videoId)
        }

        guard host == "youtube.com" || host == "www.youtube.com" || host == "m.youtube.com" else {
            return nil
        }

        if url.path.lowercased() == "/watch" {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let videoId = Self.queryValue(for: "v", in: components?.queryItems ?? []),
               !videoId.isEmpty
            {
                return .youtubeVideo(videoId: videoId)
            }
        }

        return nil
    }

    private static func parseKasetURL(_ url: URL) -> ParsedContent? {
        guard url.scheme == "kaset" else { return nil }

        let host = url.host?.lowercased() ?? ""
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        switch host {
        case "play":
            if let videoId = Self.queryValue(for: "v", in: queryItems), !videoId.isEmpty {
                return .song(videoId: videoId)
            }

        case "playlist":
            if let listId = Self.queryValue(for: "list", in: queryItems), !listId.isEmpty {
                return .playlist(id: listId)
            }

        case "album":
            if let albumId = Self.queryValue(for: "id", in: queryItems), !albumId.isEmpty {
                return .album(id: albumId)
            }

        case "artist":
            if let artistId = Self.queryValue(for: "id", in: queryItems), !artistId.isEmpty {
                return .artist(id: artistId)
            }

        default:
            break
        }

        return nil
    }

    private static func parseYouTubeMusicURL(_ url: URL) -> ParsedContent? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let path = url.path
        let pathLower = path.lowercased()

        if pathLower == "/watch" || pathLower.hasPrefix("/watch") {
            if let videoId = Self.queryValue(for: "v", in: queryItems), !videoId.isEmpty {
                return .song(videoId: videoId)
            }
        }

        if pathLower == "/playlist" || pathLower.hasPrefix("/playlist") {
            if let listId = Self.queryValue(for: "list", in: queryItems), !listId.isEmpty {
                return .playlist(id: listId)
            }
        }

        if pathLower.hasPrefix("/browse/") {
            let browseId = String(path.dropFirst("/browse/".count))
            if !browseId.isEmpty {
                if browseId.hasPrefix("VLPL") {
                    let playlistId = String(browseId.dropFirst(2))
                    return .playlist(id: playlistId)
                }
                if browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK") {
                    return .album(id: browseId)
                }
                if Artist.isNavigableId(browseId) {
                    return .artist(id: browseId)
                }
                return .album(id: browseId)
            }
        }

        if pathLower.hasPrefix("/channel/") {
            let channelId = String(path.dropFirst("/channel/".count))
            if !channelId.isEmpty {
                return .artist(id: channelId)
            }
        }

        return nil
    }

    private static func queryValue(for name: String, in items: [URLQueryItem]) -> String? {
        items.first { $0.name == name }?.value
    }
}
