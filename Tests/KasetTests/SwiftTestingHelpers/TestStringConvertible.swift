import Foundation
import Testing
@testable import Kaset

// MARK: - Song + CustomTestStringConvertible

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

// MARK: - Playlist + CustomTestStringConvertible

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

// MARK: - Album + CustomTestStringConvertible

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

// MARK: - Artist + CustomTestStringConvertible

/// Provides readable test descriptions for Artist in test failure logs.
///
/// When a test fails involving an Artist, Swift Testing will display:
/// `Artist: "Taylor Swift"` instead of the full debug description.
extension Artist: CustomTestStringConvertible {
    public var testDescription: String {
        "Artist: \"\(name)\""
    }
}

// MARK: - PlaylistDetail + CustomTestStringConvertible

/// Provides readable test descriptions for PlaylistDetail in test failure logs.
extension PlaylistDetail: CustomTestStringConvertible {
    public var testDescription: String {
        let typeText = isAlbum ? "album" : "playlist"
        let trackText = tracks.count == 1 ? "1 track" : "\(tracks.count) tracks"
        return "\"\(title)\" [\(typeText)] (\(trackText))"
    }
}

// MARK: - HomeSectionItem + CustomTestStringConvertible

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

// MARK: - PodcastShow + CustomTestStringConvertible

/// Provides readable test descriptions for PodcastShow in test failure logs.
extension PodcastShow: CustomTestStringConvertible {
    public var testDescription: String {
        let authorText = author.map { " by \($0)" } ?? ""
        return "Podcast: \"\(title)\"\(authorText)"
    }
}

// MARK: - SearchResultItem + CustomTestStringConvertible

/// Provides readable test descriptions for SearchResultItem in test failure logs.
extension SearchResultItem: CustomTestStringConvertible {
    public var testDescription: String {
        switch self {
        case let .song(song):
            "SearchResult[Song]: \(song.testDescription)"
        case let .album(album):
            "SearchResult[Album]: \(album.testDescription)"
        case let .artist(artist):
            "SearchResult[Artist]: \(artist.testDescription)"
        case let .playlist(playlist):
            "SearchResult[Playlist]: \(playlist.testDescription)"
        case let .podcastShow(show):
            "SearchResult[Podcast]: \(show.testDescription)"
        }
    }
}
