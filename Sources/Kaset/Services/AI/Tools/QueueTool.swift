import Foundation
import FoundationModels

/// A tool that provides the current playback queue context to the language model.
/// This allows AI to understand what's in the queue before making changes.
@available(macOS 26.0, *)
@MainActor
struct QueueTool: Tool {
    /// The PlayerService used to access queue state.
    private let playerService: PlayerService

    /// Logger for debugging.
    private let logger = DiagnosticsLogger.ai

    /// Creates a new QueueTool.
    /// - Parameter playerService: The PlayerService to access queue state from.
    init(playerService: PlayerService) {
        self.playerService = playerService
    }

    /// Human-readable name for the tool.
    let name = "getCurrentQueue"

    /// Description of what the tool does.
    let description = """
    Gets the current playback queue with track details.
    Use this to understand what's in the queue before making changes.
    Returns the current track, upcoming tracks, and queue length.
    """

    /// The arguments this tool accepts.
    @Generable
    struct Arguments: Sendable {
        @Guide(description: "Maximum number of tracks to return (default 20)")
        let limit: Int
    }

    /// Output type for the tool.
    typealias Output = String

    /// Returns the current queue state as a formatted string.
    nonisolated func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let queue = self.playerService.queue
            let currentIndex = self.playerService.currentIndex
            let limit = arguments.limit > 0 ? arguments.limit : 20

            guard !queue.isEmpty else {
                return "Queue is empty. No tracks are queued."
            }

            var output = "Current Queue (\(queue.count) tracks):\n"

            for (index, song) in queue.prefix(limit).enumerated() {
                let marker = index == currentIndex ? "▶ NOW PLAYING" : "  "
                output += "\(marker) \(index + 1). \"\(song.title)\" by \(song.artistsDisplay) [videoId: \(song.videoId)]\n"
            }

            if queue.count > limit {
                output += "... and \(queue.count - limit) more tracks"
            }

            self.logger.debug("QueueTool returned \(queue.count) tracks")
            return output
        }
    }
}
