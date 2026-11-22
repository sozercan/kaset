import Foundation

struct EQSettings: Codable, Equatable {
    static let minGainDB: Float = -12

    static let maxGainDB: Float = 12

    var isEnabled: Bool

    var preampDB: Float

    var bandGainsDB: [Float]

    var preset: EQPreset

    static let flat = EQSettings(
        isEnabled: false,
        preampDB: 0,
        bandGainsDB: Array(repeating: 0, count: EQBand.defaultBands.count),
        preset: .flat
    )

    mutating func clampGains() {
        self.preampDB = Self.clamp(self.preampDB)
        let expected = EQBand.defaultBands.count
        if self.bandGainsDB.count < expected {
            self.bandGainsDB.append(contentsOf: Array(repeating: 0, count: expected - self.bandGainsDB.count))
        } else if self.bandGainsDB.count > expected {
            self.bandGainsDB = Array(self.bandGainsDB.prefix(expected))
        }
        self.bandGainsDB = self.bandGainsDB.map(Self.clamp)
    }

    var autoTrimDB: Float {
        let peakBandGain = self.bandGainsDB.max() ?? 0
        let peak = self.preampDB + peakBandGain
        return -max(0, peak) * 0.2
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, self.minGainDB), self.maxGainDB)
    }
}
