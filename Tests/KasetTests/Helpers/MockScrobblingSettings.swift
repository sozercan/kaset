import Foundation
@testable import Kaset

@MainActor
final class MockScrobblingSettings: ScrobblingSettingsProviding {
    var scrobblePercentThreshold: Double
    var scrobbleMinSeconds: TimeInterval
    private var enabledServices: [String: Bool]

    init(
        scrobblePercentThreshold: Double = 0.5,
        scrobbleMinSeconds: TimeInterval = 240,
        enabledServices: [String: Bool] = [:]
    ) {
        self.scrobblePercentThreshold = scrobblePercentThreshold
        self.scrobbleMinSeconds = scrobbleMinSeconds
        self.enabledServices = enabledServices
    }

    func isServiceEnabled(_ serviceName: String) -> Bool {
        self.enabledServices[serviceName] ?? false
    }

    func setServiceEnabled(_ serviceName: String, _ enabled: Bool) {
        self.enabledServices[serviceName] = enabled
    }
}
