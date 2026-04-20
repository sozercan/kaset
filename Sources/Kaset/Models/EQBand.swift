import Foundation

// MARK: - EQBand

/// A single band of the equalizer.
///
/// Mirrors Spotify's mobile equalizer layout: six bands with a fixed centre
/// frequency. The two edge bands (60 Hz, 15 kHz) are **shelving filters** so
/// boosting them lifts everything below / above the centre — without that,
/// a peaking filter at 60 Hz only affects ~30–120 Hz and the sub-bass below
/// the centre stays flat. Middle bands stay parametric (peaking) so cutting
/// or boosting feels surgical.
struct EQBand: Identifiable, Hashable {
    /// Type of biquad filter for this band.
    enum FilterType: Hashable {
        /// Classic peaking / parametric EQ section.
        case peaking
        /// Low-shelf: lifts or attenuates everything **below** the centre.
        case lowShelf
        /// High-shelf: lifts or attenuates everything **above** the centre.
        case highShelf
    }

    /// Stable identifier derived from the centre frequency.
    var id: Int {
        Int(self.frequencyHz)
    }

    /// Centre frequency in Hertz.
    let frequencyHz: Float

    /// Q (peaking) or shelf slope (shelving). For shelves, ~0.7 gives a
    /// Butterworth-like response; for peaking ~1.0 reads as "musical".
    let q: Float

    /// Filter topology used for this band.
    let type: FilterType

    /// Short label rendered below each slider (e.g. "60", "1K").
    var displayLabel: String {
        if self.frequencyHz >= 1000 {
            let kilo = self.frequencyHz / 1000
            return kilo.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(kilo))K"
                : String(format: "%.1fK", kilo)
        }
        return "\(Int(self.frequencyHz))"
    }

    /// Default six-band Spotify layout.
    ///
    /// Order is preserved; ``EQSettings/bandGainsDB`` is indexed against it.
    /// Edge bands use shelving so adjustments behave like a tone control;
    /// middle bands use peaking with band-specific Q values chosen to feel
    /// musical (wider lows, slightly narrower around the presence region).
    static let defaultBands: [EQBand] = [
        EQBand(frequencyHz: 60, q: 0.71, type: .lowShelf),
        EQBand(frequencyHz: 150, q: 0.55, type: .peaking),
        EQBand(frequencyHz: 400, q: 0.5, type: .peaking),
        EQBand(frequencyHz: 1000, q: 0.5, type: .peaking),
        EQBand(frequencyHz: 2400, q: 0.55, type: .peaking),
        EQBand(frequencyHz: 15000, q: 0.71, type: .highShelf),
    ]
}
