import Foundation

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        self.lock.withLock {
            self.value += 1
            return self.value
        }
    }

    var count: Int {
        self.lock.withLock { self.value }
    }

    var isEmpty: Bool {
        self.lock.withLock { self.value == 0 }
    }
}
