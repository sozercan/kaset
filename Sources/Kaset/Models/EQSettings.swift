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

    /// Headroom protection applied automatically on top of the user preamp.
    ///
    /// When the user pushes bands into positive gain, overlapping biquad
    /// sections compound their boosts and the signal can exceed 0 dBFS by
    /// 20–30 dB at frequencies between band centres. We pre-attenuate by
    /// roughly a third of the maximum positive band gain so peaks usually
    /// stay below 0 dBFS without flattening the perceived effect; the soft
    /// limiter in the audio engine catches whatever still pokes above.
    ///
    /// The factor is intentionally lighter than the "halve the peak" rule
    /// used by some EQs because Kaset doesn't get the loudness-normalised
    /// source Spotify-style players start from — too much attenuation here
    /// makes presets feel inaudible.
    var autoTrimDB: Float {
        let peak = self.bandGainsDB.max() ?? 0
        return peak > 0 ? -peak * 0.3 : 0
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, self.minGainDB), self.maxGainDB)
    }
}
