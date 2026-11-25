import Foundation

struct EQBand: Identifiable, Hashable {
    enum FilterType: Hashable {
        case peaking
        case lowShelf
        case highShelf
    }

    var id: Int {
        Int(self.frequencyHz)
    }

    let frequencyHz: Float

    let q: Float

    let type: FilterType

    var displayLabel: String {
        if self.frequencyHz >= 1000 {
            let kilo = self.frequencyHz / 1000
            return kilo.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(kilo))K"
                : String(format: "%.1fK", kilo)
        }
        return "\(Int(self.frequencyHz))"
    }

    static let defaultBands: [EQBand] = [
        EQBand(frequencyHz: 60, q: 0.71, type: .lowShelf),
        EQBand(frequencyHz: 150, q: 0.55, type: .peaking),
        EQBand(frequencyHz: 400, q: 0.5, type: .peaking),
        EQBand(frequencyHz: 1000, q: 0.5, type: .peaking),
        EQBand(frequencyHz: 2400, q: 0.55, type: .peaking),
        EQBand(frequencyHz: 15000, q: 0.71, type: .highShelf),
    ]
}
