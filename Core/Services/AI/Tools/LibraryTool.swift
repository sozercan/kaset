import Foundation
import FoundationModels

/// A tool that provides access to the user's library for AI commands.
///
/// This enables commands like:
/// - "Shuffle my library"
/// - "Play my favorites"
/// - "Add to my liked songs"
///
/// The tool provides information about the user's saved content,
/// allowing the AI to make grounded suggestions based on their actual library.
///
/// ## Privacy
///
/// This tool only exposes song metadata (title, artist, IDs) to the on-device model.
/// No data leaves the device as Foundation Models runs entirely locally.
@available(macOS 26.0, *)
struct LibraryTool: Tool {
    /// The YTMusicClient for API calls.
    private let client: any YTMusicClientProtocol

    /// Logger for debugging.
    private let logger = DiagnosticsLogger.ai

    /// Creates a new LibraryTool.
    /// - Parameter client: The YTMusicClient to fetch library content with.
    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    /// Human-readable name for the tool.
    let name = "getUserLibrary"

    /// Description of what the tool does.
    let description = """
    Gets the user's music library contents (liked songs, playlists).
    Use this for commands like "shuffle my library", "play my favorites", or "what's in my library".
    Returns a summary of saved content with IDs for playback.
    """

    /// The arguments this tool accepts.
    @Generable
    struct Arguments: Sendable {
        @Guide(description: "What to fetch: 'liked' for liked songs, 'playlists' for user playlists, 'all' for summary")
        let contentType: String

        @Guide(description: "Maximum items to return (default 20, max 50)")
        let limit: Int
    }

    /// Output type for the tool.
    typealias Output = String

    /// Fetches and formats library contents.
    nonisolated func call(arguments: Arguments) async throws -> String {
        self.logger.info("LibraryTool fetching: \(arguments.contentType)")

        let limit = min(max(arguments.limit, 1), 50)
        let contentType = arguments.contentType.lowercased()

        switch contentType {
        case "liked", "likes", "favorites":
            return try await self.fetchLikedSongs(limit: limit)
        case "playlists":
            return try await self.fetchPlaylists(limit: limit)
        default:
            return try await self.fetchSummary(limit: limit)
        }
    }

    /// Fetches liked songs.
    private func fetchLikedSongs(limit: Int) async throws -> String {
        let songs = try await client.getLikedSongs()
        let limited = songs.prefix(limit)

        var output = "Liked Songs (\(songs.count) total"
        if songs.count > limit {
            output += ", showing \(limit)"
        }
        output += "):\n"

        for (index, song) in limited.enumerated() {
            output += "\(index + 1). \"\(song.title)\" by \(song.artistsDisplay) [videoId: \(song.videoId)]\n"
        }

        self.logger.debug("LibraryTool returned \(limited.count) liked songs")
        return output
    }

    /// Fetches user playlists.
    private func fetchPlaylists(limit: Int) async throws -> String {
        let playlists = try await client.getLibraryPlaylists()
        let limited = playlists.prefix(limit)

        var output = "Your Playlists (\(playlists.count) total"
        if playlists.count > limit {
            output += ", showing \(limit)"
        }
        output += "):\n"

        for (index, playlist) in limited.enumerated() {
            let trackCount = playlist.trackCount ?? 0
            output += "\(index + 1). \"\(playlist.title)\" (\(trackCount) tracks) [playlistId: \(playlist.id)]\n"
        }

        self.logger.debug("LibraryTool returned \(limited.count) playlists")
        return output
    }

    /// Fetches a summary of all library content.
    private func fetchSummary(limit _: Int) async throws -> String {
        // Fetch counts in parallel
        async let songs = self.client.getLikedSongs()
        async let playlists = self.client.getLibraryPlaylists()

        let (songList, playlistList) = try await (songs, playlists)

        var output = """
        Library Summary:
        - \(songList.count) liked songs
        - \(playlistList.count) playlists

        """

        // Include a few examples from each
        let songSample = songList.prefix(3)
        if !songSample.isEmpty {
            output += "\nRecent liked songs:\n"
            for song in songSample {
                output += "- \"\(song.title)\" by \(song.artistsDisplay) [videoId: \(song.videoId)]\n"
            }
        }

        let playlistSample = playlistList.prefix(3)
        if !playlistSample.isEmpty {
            output += "\nPlaylists:\n"
            for playlist in playlistSample {
                output += "- \"\(playlist.title)\" [playlistId: \(playlist.id)]\n"
            }
        }

        self.logger.debug("LibraryTool returned library summary")
        return output
    }
}
