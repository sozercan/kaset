import Foundation
@testable import Kaset

@MainActor
final class MockDiscordPresenceService: DiscordPresenceServiceProtocol {
    private(set) var state: DiscordPresenceState = .disconnected
    private(set) var lastPayload: DiscordPresencePayload?
    private(set) var connectCalled = false
    private(set) var disconnectCalled = false
    private(set) var clearPresenceCalled = false

    func connect() async {
        self.connectCalled = true
        self.state = .connected
    }

    func disconnect() async {
        self.disconnectCalled = true
        self.state = .disconnected
        self.lastPayload = nil
    }

    func updatePresence(_ payload: DiscordPresencePayload?) async throws {
        self.lastPayload = payload
    }

    func clearPresence() async {
        self.clearPresenceCalled = true
        self.lastPayload = nil
    }
}
