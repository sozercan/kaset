import Foundation

/// A credential-free description of one YouTube Ask request configuration.
///
/// Boolean fields describe which runtime values the adapter should attach. The
/// values themselves never enter this shared core model.
package struct YouTubeAskRequestProfile: Equatable, Sendable {
    package static let productionClientVersion = "2.20260611.01.00"

    /// The request profile used by normal `YouTubeClient` requests today.
    package static let fixedProduction = YouTubeAskRequestProfile(
        clientVersion: Self.productionClientVersion,
        includesRuntimeAPIParameter: false,
        usesVisitorData: false,
        usesAllSIDProofs: false
    )

    /// The second parity probe: production configuration with every available
    /// SID proof scheme enabled by the adapter.
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

    /// Ordered profiles for read-only request parity validation.
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
