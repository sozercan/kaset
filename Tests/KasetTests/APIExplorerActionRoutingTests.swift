import Foundation
import Testing

@Suite("API Explorer action routing", .tags(.api))
struct APIExplorerActionRoutingTests {
    @Test("Next uses redacted wire inspection without requiring a private request body")
    func nextUsesRedactedWireInspection() throws {
        let source = try Self.apiExplorerSource()
        let privateBodyRouting = try Self.section(
            in: source,
            startingWith: "func requiresPrivateBodySource",
            endingBefore: "func requiresRedactedWireInspection"
        )
        let redactedRouting = try Self.section(
            in: source,
            startingWith: "func requiresRedactedWireInspection",
            endingBefore: "func exploreWireAction"
        )
        let actionDispatch = try Self.section(
            in: source,
            startingWith: "case \"action\":",
            endingBefore: "case \"wire-action\":"
        )

        #expect(!privateBodyRouting.contains("\"next\""))
        #expect(redactedRouting.contains("\"next\""))
        #expect(actionDispatch.contains("requiresRedactedWireInspection(endpoint)"))
        #expect(actionDispatch.contains("await exploreWireAction("))
    }

    @Test("Non-redacted actions retain the standard verbose inspector")
    func ordinaryActionsRetainStandardInspector() throws {
        let source = try Self.apiExplorerSource()
        let actionDispatch = try Self.section(
            in: source,
            startingWith: "case \"action\":",
            endingBefore: "case \"wire-action\":"
        )

        #expect(actionDispatch.contains("await exploreAction("))
        #expect(actionDispatch.contains("verbose: verbose"))
        #expect(actionDispatch.contains("outputFile: outputFile"))
    }

    @Test("Redacted wire inspection never prints decoded response values")
    func redactedInspectorDoesNotPrintDecodedValues() throws {
        let source = try Self.apiExplorerSource()
        let inspector = try Self.section(
            in: source,
            startingWith: "func exploreWireAction",
            endingBefore: "private func auditSearchFilter"
        )

        #expect(inspector.contains("wireResponseAuditSummary("))
        #expect(inspector.contains("Raw response values stay hidden"))
        #expect(!inspector.contains("analyzeResponse("))
        #expect(!inspector.contains("Raw response (pretty-printed)"))
        let rawPrintCall = "print" + "(prettyString)"
        #expect(!inspector.contains(rawPrintCall))
    }

    private static func apiExplorerSource() throws -> String {
        let sourcePath = #filePath.replacingOccurrences(
            of: "Tests/KasetTests/APIExplorerActionRoutingTests.swift",
            with: "Sources/APIExplorer/main.swift"
        )
        return try String(contentsOfFile: sourcePath, encoding: .utf8)
    }

    private static func section(
        in source: String,
        startingWith startMarker: String,
        endingBefore endMarker: String
    ) throws -> Substring {
        let start = try #require(source.range(of: startMarker)?.lowerBound)
        let end = try #require(source.range(of: endMarker, range: start ..< source.endIndex)?.lowerBound)
        return source[start ..< end]
    }
}
