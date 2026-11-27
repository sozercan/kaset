import Foundation
import FoundationModels

@available(macOS 26.0, *)
struct MusicSearchTool: Tool {
    private let client: any YTMusicClientProtocol

    private let logger = DiagnosticsLogger.ai

    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    let name = "searchMusic"

    let description = """
    Searches the YouTube Music catalog for songs, albums, artists, and playlists.
    Use this tool to find real music content before suggesting playback or queuing.
    Returns formatted results with video IDs that can be used for playback.
    """

    @Generable
    struct Arguments {
        @Guide(description: "The search query (song title, artist name, album, etc.)")
        let query: String

        @Guide(description: "Optional filter: 'songs', 'albums', 'artists', 'playlists', or 'all' for no filter")
        let filter: String
    }

    typealias Output = String

    func call(arguments: Arguments) async throws -> String {
        self.logger.info("MusicSearchTool searching for: \(arguments.query)")

        let response = try await client.search(query: arguments.query)

        var results: [String] = []

        let includeAll = arguments.filter.isEmpty || arguments.filter == "all"

        if includeAll || arguments.filter == "songs" {
            let songs = response.songs.prefix(5)
            for song in songs {
                results.append("SONG: \"\(song.title)\" by \(song.artistsDisplay) [videoId: \(song.videoId)]")
            }
        }

        if includeAll || arguments.filter == "albums" {
            let albums = response.albums.prefix(3)
            for album in albums {
                results.append("ALBUM: \"\(album.title)\" by \(album.artistsDisplay) [browseId: \(album.id)]")
            }
        }

        if includeAll || arguments.filter == "artists" {
            let artists = response.artists.prefix(3)
            for artist in artists {
                results.append("ARTIST: \(artist.name) [channelId: \(artist.id)]")
            }
        }

        if includeAll || arguments.filter == "playlists" {
            let playlists = response.playlists.prefix(3)
            for playlist in playlists {
                let author = playlist.author?.name ?? "Unknown"
                results.append("PLAYLIST: \"\(playlist.title)\" by \(author) [playlistId: \(playlist.id)]")
            }
        }

        if results.isEmpty {
            return "No results found for '\(arguments.query)'"
        }

        let output = """
        Search results for '\(arguments.query)':
        \(results.joined(separator: "\n"))
        """

        self.logger.debug("MusicSearchTool found \(results.count) results")
        return output
    }
}
