import Foundation
import Testing
@testable import Kaset

/// Tests for `EQSettings` (clamping, automatic headroom trim, JSON
/// round-tripping through the persistence layer).
@Suite(.tags(.model))
struct EQSettingsTests {
    // MARK: - Clamping

    @Test("clampGains caps every band at maxGainDB")
    func clampGainsCapsAtMax() {
        var settings = EQSettings.flat
        settings.bandGainsDB = [99, 99, 99, 99, 99, 99]
        settings.preampDB = 99
        settings.clampGains()
        #expect(settings.bandGainsDB.allSatisfy { $0 == EQSettings.maxGainDB })
        #expect(settings.preampDB == EQSettings.maxGainDB)
    }

    @Test("clampGains floors every band at minGainDB")
    func clampGainsFloorsAtMin() {
        var settings = EQSettings.flat
        settings.bandGainsDB = [-99, -99, -99, -99, -99, -99]
        settings.preampDB = -99
        settings.clampGains()
        #expect(settings.bandGainsDB.allSatisfy { $0 == EQSettings.minGainDB })
        #expect(settings.preampDB == EQSettings.minGainDB)
    }

    @Test("clampGains leaves in-range values untouched")
    func clampGainsLeavesInRangeAlone() {
        var settings = EQSettings.flat
        settings.bandGainsDB = [-3, 0, 5.5, 7, -7.5, 11]
        settings.preampDB = -2
        settings.clampGains()
        #expect(settings.bandGainsDB == [-3, 0, 5.5, 7, -7.5, 11])
        #expect(settings.preampDB == -2)
    }

    // MARK: - autoTrimDB

    @Test("autoTrimDB is zero when net gain never boosts above unity")
    func autoTrimZeroWhenFlat() {
        #expect(EQSettings.flat.autoTrimDB == 0)

        var negative = EQSettings.flat
        negative.bandGainsDB = [-3, -6, -1, 0, -2, -4]
        #expect(negative.autoTrimDB == 0)

        var cutPreamp = EQSettings.flat
        cutPreamp.preampDB = -6
        cutPreamp.bandGainsDB = [4, 0, 0, 0, 0, 0]
        #expect(cutPreamp.autoTrimDB == 0)
    }

    @Test("autoTrimDB scales with the highest net positive gain at 0.2x")
    func autoTrimScalesWithPeak() {
        var settings = EQSettings.flat
        settings.bandGainsDB = [3, 0, 0, 0, 0, 0]
        #expect(abs(settings.autoTrimDB - -0.6) < 0.001)

        settings.bandGainsDB = [0, 0, 0, 6, 0, 0]
        #expect(abs(settings.autoTrimDB - -1.2) < 0.001)

        settings.bandGainsDB = [0, 0, 0, 12, 0, 0]
        #expect(abs(settings.autoTrimDB - -2.4) < 0.001)

        settings.bandGainsDB = [3, 7, 1, -2, 5, 4]
        #expect(abs(settings.autoTrimDB - -1.4) < 0.001)

        settings.preampDB = 6
        settings.bandGainsDB = [0, 0, 0, 0, 0, 0]
        #expect(abs(settings.autoTrimDB - -1.2) < 0.001)

        settings.bandGainsDB = [0, 0, 0, 6, 0, 0]
        #expect(abs(settings.autoTrimDB - -2.4) < 0.001)

        settings.preampDB = -6
        settings.bandGainsDB = [0, 0, 0, 12, 0, 0]
        #expect(abs(settings.autoTrimDB - -1.2) < 0.001)
    }

    // MARK: - Codable round-trip

    @Test("EQSettings round-trips through JSON")
    func codableRoundTrip() throws {
        var settings = EQSettings.flat
        settings.isEnabled = true
        settings.preampDB = -1.5
        settings.bandGainsDB = [3, -2, 4.5, 0, 6, -1]
        settings.preset = .rock

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(EQSettings.self, from: data)

        #expect(decoded == settings)
    }

    // MARK: - Defaults

    @Test("EQSettings.flat starts disabled with neutral bands")
    func flatDefaults() {
        let flat = EQSettings.flat
        #expect(flat.isEnabled == false)
        #expect(flat.preampDB == 0)
        #expect(flat.preset == .flat)
        #expect(flat.bandGainsDB.count == EQBand.defaultBands.count)
        #expect(flat.bandGainsDB.allSatisfy { $0 == 0 })
    }
}
