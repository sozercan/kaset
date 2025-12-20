import Foundation

/// Response from the YouTube Music home/browse endpoint.
struct HomeResponse: Sendable {
    let sections: [HomeSection]

    /// Whether the home response is empty.
    var isEmpty: Bool {
        sections.isEmpty || sections.allSatisfy(\.items.isEmpty)
    }

    static let empty = HomeResponse(sections: [])
}
