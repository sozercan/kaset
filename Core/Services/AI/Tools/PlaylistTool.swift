import Foundation
import FoundationModels

/// A tool that fetches playlist contents for AI-powered playlist refinement.
///
/// This allows the AI to understand playlist contents before making suggestions,
/// enabling grounded responses rather than hallucinated song IDs.
///
/// ## Usage
///
/// ```swift
/// let playlistTool = PlaylistTool(client: ytMusicClient)
/// let session = FoundationModelsService.shared.createAnalysisSession(
///     instructions: "You are a playlist curator..."
/// )
/// // The model can call this tool to get playlist contents
/// ```
@available(macOS 26.0, *)
struct PlaylistTool: Tool {
    /// The YTMusicClient for API calls.
    private let client: any YTMusicClientProtocol

    /// Logger for debugging.
    private let logger = DiagnosticsLogger.ai

    /// Creates a new PlaylistTool.
    /// - Parameter client: The YTMusicClient to fetch playlists with.
    init(client: any YTMusicClientProtocol) {
        self.client = client
    }

    /// Human-readable name for the tool.
    let name = "getPlaylistContents"

    /// Description of what the tool does.
    let description = """
    Gets the contents of a playlist by its ID.
    Use this to understand playlist contents before suggesting changes.
    Returns the playlist name, description, and list of tracks with their IDs.
    """

    /// The arguments this tool accepts.
    @Generable
    struct Arguments: Sendable {
        @Guide(description: "The playlist ID to fetch (e.g., 'VLPL...' or 'PL...')")
        let playlistId: String

        @Guide(description: "Maximum number of tracks to return (default 25, max 50)")
        let limit: Int
    }

    /// Output type for the tool.
    typealias Output = String

    /// Fetches and formats playlist contents.
    nonisolated func call(arguments: Arguments) async throws -> String {
        self.logger.info("PlaylistTool fetching playlist: \(arguments.playlistId)")

        let playlist = try await client.getPlaylist(id: arguments.playlistId)

        let limit = min(max(arguments.limit, 1), 50)
        let tracks = playlist.tracks.prefix(limit)

        var output = """
        Playlist: "\(playlist.title)"
        """

        if let description = playlist.description {
            output += "\nDescription: \(description)"
        }

        output += "\nTotal tracks: \(playlist.tracks.count)"

        if playlist.tracks.count > limit {
            output += " (showing first \(limit))"
        }

        output += "\n\nTracks:"

        for (index, track) in tracks.enumerated() {
            output += "\n\(index + 1). \"\(track.title)\" by \(track.artistsDisplay) [videoId: \(track.videoId)]"
        }

        self.logger.debug("PlaylistTool returned \(tracks.count) tracks")
        return output
    }
}
