import Testing
@testable import YouTubeAskCore

@Suite("YouTubeAsk request profiles")
struct YouTubeAskRequestProfileTests {
    @Test("Fixed production profile matches YouTubeClient without credential-bearing values")
    func fixedProductionProfile() {
        let profile = YouTubeAskRequestProfile.fixedProduction

        #expect(profile.clientVersion == "2.20260611.01.00")
        #expect(profile.clientVersion == YouTubeAskRequestProfile.productionClientVersion)
        #expect(!profile.includesRuntimeAPIParameter)
        #expect(!profile.usesVisitorData)
        #expect(!profile.usesAllSIDProofs)
    }

    @Test("Parity profiles preserve the required validation order")
    func orderedParityProfiles() {
        let profiles = YouTubeAskRequestProfile.orderedParityProfiles(
            runtimeClientVersion: "runtime-version-placeholder"
        )

        #expect(profiles.count == 3)
        #expect(profiles[0] == .fixedProduction)
        #expect(profiles[1] == .fixedProductionWithAllSIDProofs)
        #expect(profiles[2] == YouTubeAskRequestProfile(
            clientVersion: "runtime-version-placeholder",
            includesRuntimeAPIParameter: true,
            usesVisitorData: true,
            usesAllSIDProofs: true
        ))
    }
}
