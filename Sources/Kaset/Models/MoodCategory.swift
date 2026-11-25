import Foundation
import SwiftUI

struct MoodCategoryEndpoint: Codable, Hashable {
    let browseId: String
    let params: String?
}

struct MoodCategory: Identifiable, Hashable {
    let browseId: String

    let params: String?

    let title: String

    let color: Color?

    init(browseId: String, params: String?, title: String, color: Color? = nil) {
        self.browseId = browseId
        self.params = params
        self.title = title
        self.color = color
    }

    var id: String {
        if let params {
            "\(self.browseId)_\(params)"
        } else {
            self.browseId
        }
    }

    static func isMoodCategory(_ browseId: String) -> Bool {
        browseId.hasPrefix("FEmusic_moods_and_genres")
    }

    static func parseId(_ combinedId: String) -> (browseId: String, params: String?)? {
        guard combinedId.hasPrefix("FEmusic_moods_and_genres") else {
            return nil
        }

        let baseId = "FEmusic_moods_and_genres_category"
        if combinedId == baseId {
            return (baseId, nil)
        }

        if combinedId.hasPrefix(baseId + "_") {
            let params = String(combinedId.dropFirst(baseId.count + 1))
            return (baseId, params)
        }

        return (combinedId, nil)
    }
}

extension Playlist {
    var resolvedMoodCategoryEndpoint: MoodCategoryEndpoint? {
        if let moodCategoryEndpoint {
            return moodCategoryEndpoint
        }
        guard let parsed = MoodCategory.parseId(self.id) else { return nil }
        return MoodCategoryEndpoint(browseId: parsed.browseId, params: parsed.params)
    }
}
