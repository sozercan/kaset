import Foundation

@MainActor
protocol ScrobblingSettingsProviding: AnyObject {
    var scrobblePercentThreshold: Double { get }
    var scrobbleMinSeconds: TimeInterval { get }

    func isServiceEnabled(_ serviceName: String) -> Bool
}

extension SettingsManager: ScrobblingSettingsProviding {}
