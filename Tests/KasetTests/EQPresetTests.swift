import Foundation
import Testing
@testable import Kaset

/// Tests for `EQPreset` (band-count alignment, picker ordering, display
/// names, special-cased presets).
@Suite(.tags(.model))
struct EQPresetTests {
    @Test("Every preset's gain table matches the band layout")
    func gainTableLengthMatchesBands() {
        let bandCount = EQBand.defaultBands.count
        for preset in EQPreset.allCases {
            #expect(
                preset.bandGainsDB.count == bandCount,
                "\(preset.rawValue) has \(preset.bandGainsDB.count) gains, expected \(bandCount)"
            )
        }
    }

    @Test("Every gain stays within the legal ±12 dB range")
    func gainsStayInRange() {
        for preset in EQPreset.allCases {
            for gain in preset.bandGainsDB {
                #expect(
                    gain >= EQSettings.minGainDB && gain <= EQSettings.maxGainDB,
                    "\(preset.rawValue) has out-of-range gain \(gain)"
                )
            }
        }
    }

    @Test("Flat and Custom both produce a neutral curve")
    func flatAndCustomAreNeutral() {
        #expect(EQPreset.flat.bandGainsDB.allSatisfy { $0 == 0 })
        #expect(EQPreset.custom.bandGainsDB.allSatisfy { $0 == 0 })
    }

    @Test("Picker order excludes the Custom preset")
    func pickerOrderHidesCustom() {
        #expect(!EQPreset.pickerOrder.contains(.custom))
    }

    @Test("Picker order leads with Flat")
    func pickerOrderLeadsWithFlat() {
        #expect(EQPreset.pickerOrder.first == .flat)
    }

    @Test("Picker order is in sync with allCases (minus custom)")
    func pickerOrderMatchesAllCases() {
        let expected = EQPreset.allCases.filter { $0 != .custom }
        #expect(EQPreset.pickerOrder == expected)
    }

    @Test("Display names are non-empty and unique")
    func displayNamesAreUnique() {
        let names = EQPreset.allCases.map(\.displayName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    @Test("Bass-heavy presets really boost the low band")
    func bassPresetsBoostLow() {
        #expect(EQPreset.bassBooster.bandGainsDB[0] > 0)
        #expect(EQPreset.deep.bandGainsDB[0] > 0)
        #expect(EQPreset.bassReducer.bandGainsDB[0] < 0)
    }

    @Test("Treble-heavy presets really boost the high band")
    func treblePresetsBoostHigh() {
        let highIndex = EQBand.defaultBands.count - 1
        #expect(EQPreset.trebleBooster.bandGainsDB[highIndex] > 0)
        #expect(EQPreset.trebleReducer.bandGainsDB[highIndex] < 0)
    }
}
