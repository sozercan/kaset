import Foundation

// MARK: - TrackCredits

struct TrackCredits: Equatable {
    struct Section: Equatable, Identifiable {
        let title: String
        let names: [String]

        var id: String {
            self.title
        }
    }

    let title: String?
    let sections: [Section]

    var isAvailable: Bool {
        !self.sections.isEmpty
    }

    static let unavailable = TrackCredits(title: nil, sections: [])
}
