import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
struct MusicIntent: Equatable {
    @Guide(description: "The action to perform: play, queue, shuffle, like, dislike, skip, previous, pause, resume, search")
    let action: MusicAction

    @Guide(description: "The search query, song title, or artist name. Empty for actions like skip, pause, resume.")
    let query: String

    @Guide(description: "The scope for shuffle: all, library, likes, or empty for single song actions.")
    let shuffleScope: String

    @Guide(description: "Artist name if mentioned (e.g., 'Rolling Stones'). Empty if not specified.")
    let artist: String

    @Guide(description: "Genre if mentioned (rock, jazz, hip-hop, classical, electronic, pop, country, r&b, indie, metal, folk, latin, k-pop). Empty if not specified.")
    let genre: String

    @Guide(description: "Mood if mentioned (upbeat, chill, sad, happy, energetic, relaxing, melancholic, romantic, aggressive, peaceful, groovy, dark). Empty if not specified.")
    let mood: String

    @Guide(description: "Era if mentioned. Use decade format: '1960s', '1970s', '1980s', '1990s', '2000s', '2010s', '2020s'. Or 'classic' for oldies. Empty if not specified.")
    let era: String

    @Guide(description: "Version type if mentioned (acoustic, live, remix, instrumental, cover, unplugged). Empty if not specified.")
    let version: String

    @Guide(description: "Activity if mentioned (workout, study, sleep, party, driving, cooking, focus, running, yoga). Empty if not specified.")
    let activity: String

    func buildSearchQuery() -> String {
        ContentSourceResolver.buildSearchQuery(from: self)
    }

    func queryDescription() -> String {
        ContentSourceResolver.queryDescription(for: self)
    }

    func suggestedContentSource() -> ContentSource {
        ContentSourceResolver.suggestedContentSource(for: self)
    }
}

@available(macOS 26.0, *)
@Generable
enum MusicAction: String, CaseIterable {
    case play
    case queue
    case shuffle
    case like
    case dislike
    case skip
    case previous
    case pause
    case resume
    case search
}

enum ContentSource: String, CustomStringConvertible {
    case search
    case moodsAndGenres
    case charts

    var description: String {
        rawValue
    }
}
