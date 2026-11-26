import Foundation
import FoundationModels

@available(macOS 26.0, *)
@MainActor
struct QueueTool: Tool {
    private let playerService: PlayerService

    private let logger = DiagnosticsLogger.ai

    init(playerService: PlayerService) {
        self.playerService = playerService
    }

    let name = "getCurrentQueue"

    let description = """
    Gets the current playback queue with track details.
    Use this to understand what's in the queue before making changes.
    Returns the current track, upcoming tracks, and queue length.
    """

    @Generable
    struct Arguments {
        @Guide(description: "Maximum number of tracks to return (default 20)")
        let limit: Int
    }

    typealias Output = String

    nonisolated func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            let queue = self.playerService.queue
            let currentIndex = self.playerService.activePlaybackQueueIndex
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
