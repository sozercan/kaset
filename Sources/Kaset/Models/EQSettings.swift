import Foundation

// MARK: - EQSettings

/// Persistent user-facing equalizer settings.
///
/// Designed to mirror Spotify's mobile equalizer:
/// six parametric bands at 60 / 150 / 400 / 1 000 / 2 400 / 15 000 Hz plus a
/// preamp slider and a preset selector. Stored as JSON in `UserDefaults` so it
/// round-trips cleanly between launches.
struct EQSettings: Codable, Equatable {
    /// Minimum gain (dB) allowed on any band or on the preamp.
    static let minGainDB: Float = -12

    /// Maximum gain (dB) allowed on any band or on the preamp.
    static let maxGainDB: Float = 12

    /// Whether the equalizer is active.
    var isEnabled: Bool

    /// Preamp gain applied before the band filters, in dB.
    var preampDB: Float

    /// Per-band gains in dB, ordered by ``EQBand/defaultBands``.
    var bandGainsDB: [Float]

    /// Currently applied preset (or `.custom` if the user has edited a band).
    var preset: EQPreset

    /// A completely flat, disabled equalizer.
    static let flat = EQSettings(
        isEnabled: false,
        preampDB: 0,
        bandGainsDB: Array(repeating: 0, count: EQBand.defaultBands.count),
        preset: .flat
    )

    /// Clamps all gains to the legal range defined by ``minGainDB``/``maxGainDB``,
    /// and normalises the band-gain array length to ``EQBand/defaultBands``
    /// so settings persisted by an older build (with a different band count)
    /// still load cleanly.
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

    /// Automatic headroom applied ahead of the biquad chain.
    ///
    /// Balanced so the envelope limiter handles only occasional
    /// transients rather than continuously riding the signal — when the
    /// limiter fires constantly you start hearing its gain reduction as
    /// low-level pumping / raised noise floor. A 0.25 coefficient
    /// reserves enough headroom that normal content sits below the
    /// threshold while presets keep most of their perceptual boost.
    ///
    /// Formula: `-max(0, peak) × 0.25`. Examples:
    ///   peak = +3 dB  → trim = −0.75 dB
    ///   peak = +6 dB  → trim = −1.5 dB
    ///   peak = +12 dB → trim = −3.0 dB
    var autoTrimDB: Float {
        let peak = self.bandGainsDB.max() ?? 0
        return -max(0, peak) * 0.25
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, self.minGainDB), self.maxGainDB)
    }
}
