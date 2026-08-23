// MARK: - ScrobblingSettingsProviding

import Foundation

// MARK: - ScrobblingSettingsProviding

/// Settings surface needed by scrobbling coordination. Keeping this narrow makes playback tests
/// independent from the process-wide SettingsManager singleton.
@MainActor
protocol ScrobblingSettingsProviding: AnyObject {
    var scrobblePercentThreshold: Double { get }
    var scrobbleMinSeconds: TimeInterval { get }

    func isServiceEnabled(_ serviceName: String) -> Bool
}

// MARK: - SettingsManager + ScrobblingSettingsProviding

extension SettingsManager: ScrobblingSettingsProviding {}
