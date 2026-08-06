import Foundation
import Testing
@testable import YouTubeAskCore

// MARK: - YouTubeAskTestFixture

enum YouTubeAskTestFixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    static func envelope(_ name: String) throws -> YouTubeAskWireEnvelope {
        try YouTubeAskWireDecoder.decode(self.data(name))
    }

    static func object(from data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

func expectYouTubeAskError(
    _ expected: YouTubeAskCoreError,
    performing operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected YouTubeAskCoreError.\(expected)")
    } catch let error as YouTubeAskCoreError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected YouTubeAskCoreError, received a different error type")
    }
}
