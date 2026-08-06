import Foundation

@MainActor
final class YouTubeAskMessageIDGenerator {
    private let nowMilliseconds: () -> Int64
    private var lastMilliseconds: Int64 = 0

    init(nowMilliseconds: @escaping () -> Int64 = {
        Int64(Date().timeIntervalSince1970 * 1000)
    }) {
        self.nowMilliseconds = nowMilliseconds
    }

    func next() -> String {
        let current = self.nowMilliseconds()
        let next = max(current, self.lastMilliseconds &+ 1)
        self.lastMilliseconds = next
        return "youchat-\(next)"
    }
}
