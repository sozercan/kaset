import Foundation

struct HomeResponse {
    let sections: [HomeSection]

    var isEmpty: Bool {
        self.sections.isEmpty || self.sections.allSatisfy(\.items.isEmpty)
    }

    static let empty = HomeResponse(sections: [])
}
