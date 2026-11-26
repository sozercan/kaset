import Foundation

package struct YouTubeAskRequestProfile: Equatable, Sendable {
    package static let productionClientVersion = "2.20260611.01.00"

    package static let fixedProduction = YouTubeAskRequestProfile(
        clientVersion: Self.productionClientVersion,
        includesRuntimeAPIParameter: false,
        usesVisitorData: false,
        usesAllSIDProofs: false
    )

    package static let fixedProductionWithAllSIDProofs = YouTubeAskRequestProfile(
        clientVersion: Self.productionClientVersion,
        includesRuntimeAPIParameter: false,
        usesVisitorData: false,
        usesAllSIDProofs: true
    )

    package let clientVersion: String
    package let includesRuntimeAPIParameter: Bool
    package let usesVisitorData: Bool
    package let usesAllSIDProofs: Bool

    package init(
        clientVersion: String,
        includesRuntimeAPIParameter: Bool,
        usesVisitorData: Bool,
        usesAllSIDProofs: Bool
    ) {
        self.clientVersion = clientVersion
        self.includesRuntimeAPIParameter = includesRuntimeAPIParameter
        self.usesVisitorData = usesVisitorData
        self.usesAllSIDProofs = usesAllSIDProofs
    }

    package static func orderedParityProfiles(
        runtimeClientVersion: String
    ) -> [YouTubeAskRequestProfile] {
        [
            self.fixedProduction,
            self.fixedProductionWithAllSIDProofs,
            YouTubeAskRequestProfile(
                clientVersion: runtimeClientVersion,
                includesRuntimeAPIParameter: true,
                usesVisitorData: true,
                usesAllSIDProofs: true
            ),
        ]
    }
}
