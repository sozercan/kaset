import Foundation

/// A one-shot async gate for tests: `wait()` suspends until `open()` is called.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if self.isOpen { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func open() {
        self.isOpen = true
        let pending = self.waiters
        self.waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
