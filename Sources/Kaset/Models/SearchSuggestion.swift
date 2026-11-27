import Foundation

struct SearchSuggestion: Identifiable, Hashable {
    let id: String

    let query: String

    init(query: String) {
        self.id = UUID().uuidString
        self.query = query
    }

    init(id: String, query: String) {
        self.id = id
        self.query = query
    }
}
