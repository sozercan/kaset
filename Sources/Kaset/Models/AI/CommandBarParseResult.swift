import Foundation
import FoundationModels

// MARK: - CommandBarParseResult

/// Stage-1 command-bar parse result.
///
/// This is intentionally narrower than `MusicIntent`: it is only responsible for
/// classifying the user's command and extracting the essential subject plus a few
/// search modifiers. Execution-specific behavior remains outside the model.
@available(macOS 26.0, *)
@Generable
struct CommandBarParseResult: Equatable {
    /// High-level action the user wants to perform.
    @Guide(description: "Action: play, queue, search, inspectQueue, shuffle, clearQueue, like, dislike, skip, previous, pause, or resume.")
    let action: CommandBarAction

    /// Essential search words for content requests.
    @Guide(description: "Essential search subject for play, queue, or search actions. Keep only the key content words, not filler or command words. Empty for pure playback controls.")
    let subject: String

    /// Optional shuffle scope.
    @Guide(description: "Shuffle scope when action is shuffle: queue, library, likes, or empty if unspecified.")
    let shuffleScope: String

    /// Optional artist name.
    @Guide(description: "Artist or band name only. Empty if not specified.")
    let artist: String

    /// Optional genre name.
    @Guide(description: "Genre or style such as rock, jazz, pop, hip-hop, electronic, country, or indie. Empty if not specified.")
    let genre: String

    /// Optional mood descriptor.
    @Guide(description: "Mood or energy such as chill, upbeat, energetic, relaxing, sad, or groovy. Empty if not specified.")
    let mood: String

    /// Optional time period.
    @Guide(description: "Era such as 1960s, 1970s, 1980s, 1990s, 2000s, 2010s, 2020s, or classic. Empty if not specified.")
    let era: String

    /// Optional recording version.
    @Guide(description: "Version such as acoustic, live, remix, instrumental, cover, unplugged, or remastered. Empty if not specified.")
    let version: String

    /// Optional activity context.
    @Guide(description: "Activity such as workout, study, sleep, party, driving, cooking, focus, running, or yoga. Empty if not specified.")
    let activity: String

    var isQueueInspection: Bool {
        self.action == .inspectQueue
    }

    var directRequest: CommandExecutor.Request? {
        switch self.action {
        case .shuffle:
            if self.shuffleScope == "queue" {
                .shuffleQueue
            } else {
                .toggleShuffle
            }
        case .clearQueue:
            .clearQueue
        case .like:
            .like
        case .dislike:
            .dislike
        case .skip:
            .skip
        case .previous:
            .previous
        case .pause:
            .pause
        case .resume:
            .resume
        case .play, .queue, .search, .inspectQueue:
            nil
        }
    }

    var musicIntent: MusicIntent? {
        guard let action = self.musicAction else { return nil }

        return MusicIntent(
            action: action,
            query: self.subject,
            shuffleScope: self.shuffleScope,
            artist: self.artist,
            genre: self.genre,
            mood: self.mood,
            era: self.era,
            version: self.version,
            activity: self.activity
        )
    }

    private var musicAction: MusicAction? {
        switch self.action {
        case .play:
            .play
        case .queue:
            .queue
        case .search:
            .search
        case .shuffle:
            .shuffle
        case .like:
            .like
        case .dislike:
            .dislike
        case .skip:
            .skip
        case .previous:
            .previous
        case .pause:
            .pause
        case .resume:
            .resume
        case .inspectQueue, .clearQueue:
            nil
        }
    }
}

// MARK: - CommandBarAction

@available(macOS 26.0, *)
@Generable
enum CommandBarAction: String, CaseIterable {
    case play
    case queue
    case search
    case inspectQueue
    case shuffle
    case clearQueue
    case like
    case dislike
    case skip
    case previous
    case pause
    case resume
}
