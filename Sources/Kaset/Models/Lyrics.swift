import Foundation

struct Lyrics: Equatable {
    let text: String

    let source: String?

    var isAvailable: Bool {
        !self.text.isEmpty
    }

    var lines: [String] {
        self.text.components(separatedBy: "\n")
    }

    static let unavailable = Lyrics(text: "", source: nil)
}
