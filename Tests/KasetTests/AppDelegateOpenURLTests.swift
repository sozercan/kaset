import AppKit
import Testing
@testable import Kaset

@Suite("App delegate URL delivery", .serialized)
@MainActor
struct AppDelegateOpenURLTests {
    private final class DeliveryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[URL]] = []

        var deliveries: [[URL]] {
            self.lock.withLock { self.storage }
        }

        func record(_ notification: Notification) {
            guard let urls = notification.object as? [URL] else { return }
            self.lock.withLock {
                self.storage.append(urls)
            }
        }
    }

    private func makeURL(_ value: String) throws -> URL {
        try #require(URL(string: value))
    }

    private func observeDeliveries(_ recorder: DeliveryRecorder) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .kasetOpenURLs,
            object: nil,
            queue: nil
        ) { notification in
            recorder.record(notification)
        }
    }

    @Test("Cold-launch URLs are emitted once in arrival order when delivery begins")
    func coldLaunchURLsDrainInOrder() throws {
        let delegate = AppDelegate()
        let recorder = DeliveryRecorder()
        let observer = self.observeDeliveries(recorder)
        defer { NotificationCenter.default.removeObserver(observer) }

        let first = try self.makeURL("kaset://play?v=first")
        let second = try self.makeURL("kaset://play?v=second")

        delegate.application(NSApplication.shared, open: [first])
        delegate.application(NSApplication.shared, open: [second])
        #expect(recorder.deliveries.isEmpty)

        delegate.beginOpenURLDelivery()
        #expect(recorder.deliveries == [[first, second]])

        delegate.beginOpenURLDelivery()
        #expect(recorder.deliveries == [[first, second]])
    }

    @Test("URLs received after delivery begins are emitted immediately")
    func readyDeliveryEmitsImmediately() throws {
        let delegate = AppDelegate()
        let recorder = DeliveryRecorder()
        let observer = self.observeDeliveries(recorder)
        defer { NotificationCenter.default.removeObserver(observer) }

        let first = try self.makeURL("kaset://play?v=first")
        let second = try self.makeURL("kaset://play?v=second")

        delegate.beginOpenURLDelivery()
        delegate.application(NSApplication.shared, open: [first])
        #expect(recorder.deliveries == [[first]])

        delegate.application(NSApplication.shared, open: [second])
        #expect(recorder.deliveries == [[first], [second]])
    }
}
