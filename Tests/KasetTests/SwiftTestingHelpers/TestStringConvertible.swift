import Foundation
import Testing
@testable import Kaset

extension Song: CustomTestStringConvertible {
    public var testDescription: String {
        let artistsText = artists.isEmpty ? "Unknown Artist" : artistsDisplay
        let durationText = durationDisplay
        return "\"\(title)\" by \(artistsText) (\(durationText))"
    }
}

extension Playlist: CustomTestStringConvertible {
    public var testDescription: String {
        let countText = trackCountDisplay.isEmpty ? "unknown tracks" : trackCountDisplay
        let typeText = isAlbum ? "album" : "playlist"
        return "\"\(title)\" [\(typeText)] (\(countText))"
    }
}

extension Album: CustomTestStringConvertible {
    public var testDescription: String {
        let artistsText = artistsDisplay.isEmpty ? "Unknown Artist" : artistsDisplay
        let yearText = year.map { " (\($0))" } ?? ""
        return "\"\(title)\" by \(artistsText)\(yearText)"
    }
}

extension Artist: CustomTestStringConvertible {
    public var testDescription: String {
        "Artist: \"\(name)\""
    }
}

extension PlaylistDetail: CustomTestStringConvertible {
    public var testDescription: String {
        let typeText = isAlbum ? "album" : "playlist"
        let trackText = tracks.count == 1 ? "1 track" : "\(tracks.count) tracks"
        return "\"\(title)\" [\(typeText)] (\(trackText))"
    }
}

extension HomeSectionItem: CustomTestStringConvertible {
    public var testDescription: String {
        switch self {
        case let .song(song):
            "Song: \(song.testDescription)"
        case let .album(album):
            "Album: \(album.testDescription)"
        case let .playlist(playlist):
            "Playlist: \(playlist.testDescription)"
        case let .artist(artist):
            artist.testDescription
        }
    }
}

extension FavoriteItem: CustomTestStringConvertible {
    public var testDescription: String {
        switch itemType {
        case let .song(song):
            "Favorite[Song]: \(song.testDescription)"
        case let .album(album):
            "Favorite[Album]: \(album.testDescription)"
        case let .playlist(playlist):
            "Favorite[Playlist]: \(playlist.testDescription)"
        case let .artist(artist):
            "Favorite[Artist]: \(artist.testDescription)"
        case let .podcastShow(show):
            "Favorite[Podcast]: \(show.testDescription)"
        }
    }
}

extension PodcastShow: CustomTestStringConvertible {
    public var testDescription: String {
        let authorText = author.map { " by \($0)" } ?? ""
        return "Podcast: \"\(title)\"\(authorText)"
    }
}

extension PodcastEpisode: CustomTestStringConvertible {
    public var testDescription: String {
        let showText = showTitle.map { " from \($0)" } ?? ""
        let durationText = formattedDuration.map { " (\($0))" } ?? ""
        return "Episode: \"\(title)\"\(showText)\(durationText)"
    }
}

extension PodcastSectionItem: CustomTestStringConvertible {
    public var testDescription: String {
        switch self {
        case let .show(show):
            show.testDescription
        case let .episode(episode):
            episode.testDescription
        }
    }
}

extension SearchResultItem: CustomTestStringConvertible {
    public var testDescription: String {
        switch self {
        case let .song(song):
            "SearchResult[Song]: \(song.testDescription)"
        case let .video(video):
            "SearchResult[Video]: \(video.testDescription)"
        case let .album(album):
            "SearchResult[Album]: \(album.testDescription)"
        case let .audiobook(audiobook):
            "SearchResult[Audiobook]: \(audiobook.testDescription)"
        case let .artist(artist):
            "SearchResult[Artist]: \(artist.testDescription)"
        case let .profile(profile):
            "SearchResult[Profile]: \(profile.testDescription)"
        case let .playlist(playlist):
            "SearchResult[Playlist]: \(playlist.testDescription)"
        case let .podcastShow(show):
            "SearchResult[Podcast]: \(show.testDescription)"
        case let .podcastEpisode(episode):
            "SearchResult[Episode]: \(episode.title) [\(episode.id)]"
        }
    }
}
