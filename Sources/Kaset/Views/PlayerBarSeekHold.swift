import Foundation

// MARK: - PlayerBarSeekHold

struct PlayerBarSeekHold {
    private static let timeoutMilliseconds = 2200

    static let timeout: Duration = .milliseconds(Self.timeoutMilliseconds)

    private static let timeoutSeconds = TimeInterval(Self.timeoutMilliseconds) / 1000
    private static let minimumConfirmationAgeSeconds: TimeInterval = 0.35
    private static let confirmationTolerance: TimeInterval = 1.25

    private var target: TimeInterval?
    private var issuedAt: Date?
    private var id = UUID()

    var isActive: Bool {
        self.target != nil
    }

    var targetProgress: TimeInterval? {
        self.target
    }

    @discardableResult
    mutating func begin(target: TimeInterval, issuedAt: Date = Date()) -> UUID {
        let newID = UUID()
        self.target = max(0, target)
        self.issuedAt = issuedAt
        self.id = newID
        return newID
    }

    mutating func reconcile(observedProgress: TimeInterval, now: Date = Date()) {
        guard let target, let issuedAt else { return }

        let age = now.timeIntervalSince(issuedAt)
        if age >= Self.timeoutSeconds {
            self.clear()
            return
        }

        if age >= Self.minimumConfirmationAgeSeconds,
           abs(observedProgress - target) <= Self.confirmationTolerance
        {
            self.clear()
        }
    }

    mutating func clear() {
        self.target = nil
        self.issuedAt = nil
    }

    @discardableResult
    mutating func clearIfCurrent(_ id: UUID) -> Bool {
        guard self.target != nil, self.id == id else { return false }
        self.clear()
        return true
    }

    func displayProgress(observedProgress: TimeInterval) -> TimeInterval {
        self.target ?? observedProgress
    }
}
