import Foundation
import Testing
@testable import Kaset

/// Provides readable test descriptions for Song in test failure logs.
///
/// When a test fails involving a Song, Swift Testing will display:
/// `"Never Gonna Give You Up" by Rick Astley (3:33)` instead of the full debug description.
extension Song: CustomTestStringConvertible {
    public var testDescription: String {
        let artistsText = artists.isEmpty ? "Unknown Artist" : artistsDisplay
        let durationText = durationDisplay
        return "\"\(title)\" by \(artistsText) (\(durationText))"
    }
}

/// Provides readable test descriptions for Playlist in test failure logs.
///
/// When a test fails involving a Playlist, Swift Testing will display:
/// `"My Playlist" (25 songs)` instead of the full debug description.
extension Playlist: CustomTestStringConvertible {
    public var testDescription: String {
        let countText = trackCountDisplay.isEmpty ? "unknown tracks" : trackCountDisplay
        let typeText = isAlbum ? "album" : "playlist"
        return "\"\(title)\" [\(typeText)] (\(countText))"
    }
}

/// Provides readable test descriptions for Album in test failure logs.
///
/// When a test fails involving an Album, Swift Testing will display:
/// `"Thriller" by Michael Jackson (1982)` instead of the full debug description.
extension Album: CustomTestStringConvertible {
    public var testDescription: String {
        let artistsText = artistsDisplay.isEmpty ? "Unknown Artist" : artistsDisplay
        let yearText = year.map { " (\($0))" } ?? ""
        return "\"\(title)\" by \(artistsText)\(yearText)"
    }
}

/// Provides readable test descriptions for Artist in test failure logs.
///
/// When a test fails involving an Artist, Swift Testing will display:
/// `Artist: "Taylor Swift"` instead of the full debug description.
extension Artist: CustomTestStringConvertible {
    public var testDescription: String {
        "Artist: \"\(name)\""
    }
}

/// Provides readable test descriptions for PlaylistDetail in test failure logs.
extension PlaylistDetail: CustomTestStringConvertible {
    public var testDescription: String {
        let typeText = isAlbum ? "album" : "playlist"
        let trackText = tracks.count == 1 ? "1 track" : "\(tracks.count) tracks"
        return "\"\(title)\" [\(typeText)] (\(trackText))"
    }
}

/// Provides readable test descriptions for HomeSectionItem in test failure logs.
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

/// Provides readable test descriptions for FavoriteItem in test failure logs.
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

/// Provides readable test descriptions for PodcastShow in test failure logs.
extension PodcastShow: CustomTestStringConvertible {
    public var testDescription: String {
        let authorText = author.map { " by \($0)" } ?? ""
        return "Podcast: \"\(title)\"\(authorText)"
    }
}

/// Provides readable test descriptions for PodcastEpisode in test failure logs.
extension PodcastEpisode: CustomTestStringConvertible {
    public var testDescription: String {
        let showText = showTitle.map { " from \($0)" } ?? ""
        let durationText = formattedDuration.map { " (\($0))" } ?? ""
        return "Episode: \"\(title)\"\(showText)\(durationText)"
    }
}

/// Provides readable test descriptions for PodcastSectionItem in test failure logs.
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

/// Provides readable test descriptions for SearchResultItem in test failure logs.
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
