import Foundation
import FoundationModels

/// A tool that provides the current track's information to the language model.
///
/// This allows AI to understand context for commands like:
/// - "Play more like this"
/// - "Add similar songs to queue"
/// - "What genre is this?"
///
/// ## Usage
///
/// Register this tool when creating a command session:
/// ```swift
/// let nowPlayingTool = NowPlayingTool(playerService: playerService)
/// let session = FoundationModelsService.shared.createCommandSession(
///     instructions: instructions,
///     tools: [nowPlayingTool, searchTool]
/// )
/// ```
@available(macOS 26.0, *)
struct NowPlayingTool: Tool {
    /// The PlayerService to access current track info.
    private let playerService: PlayerService

    /// Logger for debugging.
    private let logger = DiagnosticsLogger.ai

    /// Creates a new NowPlayingTool.
    /// - Parameter playerService: The PlayerService to access current track from.
    init(playerService: PlayerService) {
        self.playerService = playerService
    }

    /// Human-readable name for the tool.
    let name = "getNowPlaying"

    /// Description of what the tool does.
    let description = """
    Gets information about the currently playing track.
    Use this to understand context for commands like "play more like this" or "what's playing".
    Returns the song title, artist, album, and video ID.
    """

    /// The arguments this tool accepts.
    @Generable
    struct Arguments: Sendable {
        @Guide(description: "Whether to include playback state (paused, progress, duration)")
        let includePlaybackState: Bool
    }

    /// Output type for the tool.
    typealias Output = String

    /// Returns the current track information.
    nonisolated func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            guard let track = self.playerService.currentTrack else {
                return "No track is currently playing."
            }

            var output = """
            Now Playing:
            Title: "\(track.title)"
            Artist: \(track.artistsDisplay)
            """

            if let album = track.album {
                output += "\nAlbum: \(album)"
            }

            output += "\n[videoId: \(track.videoId)]"

            if arguments.includePlaybackState {
                let state = self.playerService.isPlaying ? "Playing" : "Paused"
                let progress = Int(self.playerService.progress)
                let duration = Int(self.playerService.duration)
                output += "\nState: \(state)"
                output += "\nProgress: \(progress)s / \(duration)s"
            }

            self.logger.debug("NowPlayingTool returned: \(track.title)")
            return output
        }
    }
}
