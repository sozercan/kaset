import Darwin
import Foundation
import Testing

@Suite("API Explorer queue probe privacy", .tags(.api))
struct APIExplorerQueueProbePrivacyTests {
    @Test("Queue probe hides personalized values in standard, verbose, saved, and error output")
    func queueProbeOutputIsPrivate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaset-queue-probe-privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = Self.syntheticQueueResponse()
        let fixtureURL = directory.appendingPathComponent("fixture.json")
        try JSONSerialization.data(withJSONObject: fixture).write(to: fixtureURL)
        let scriptURL = directory.appendingPathComponent("probe.swift")
        try Self.harnessSource().write(to: scriptURL, atomically: true, encoding: .utf8)
        let savedURL = directory.appendingPathComponent("saved.json")
        try Data("test-old-output".utf8).write(to: savedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: savedURL.path)

        let output = try await Self.runHarness(
            scriptURL: scriptURL,
            fixtureURL: fixtureURL,
            savedURL: savedURL,
            directory: directory
        )
        #expect(!output.contains("test-"))
        #expect(!output.contains("424242"))

        let standard = try Self.modeOutput("default", in: output)
        #expect(standard.contains("Parsed songs: 3"))
        #expect(standard.contains("Seed positions: 0, 2"))
        #expect(standard.contains("Has first parsed song: yes"))
        #expect(standard.contains("Has second parsed song: yes"))
        #expect(standard.contains("Has autoplay overlay: yes"))
        #expect(standard.contains("Has continuation: yes"))
        #expect(!standard.contains("Sanitized response"))

        let verbose = try Self.modeOutput("verbose", in: output)
        let jsonStart = try #require(verbose.firstIndex(of: "{"))
        let verboseJSON = verbose[jsonStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        let savedData = try Data(contentsOf: savedURL)
        let savedJSON = try #require(String(bytes: savedData, encoding: .utf8))
        #expect(verboseJSON == savedJSON)
        #expect(verboseJSON.contains("\"playlistPanelRenderer\""))
        let sanitized = try JSONSerialization.jsonObject(with: savedData)
        #expect(Self.diagnosticShape(fixture) == Self.diagnosticShape(sanitized))
        Self.expectRedactedValues(sanitized)
        let attributes = try FileManager.default.attributesOfItem(atPath: savedURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)

        let saved = try Self.modeOutput("saved", in: output)
        #expect(saved.contains("Saved sanitized response"))
        #expect(!saved.contains("playlistPanelRenderer"))
        let empty = try Self.modeOutput("empty", in: output)
        #expect(empty.contains("Parsed songs: 0"))
        #expect(empty.contains("Seed positions: none"))
        #expect(empty.contains("Has first parsed song: no"))
        #expect(empty.contains("Has second parsed song: no"))
        #expect(empty.contains("Has autoplay overlay: no"))
        #expect(empty.contains("Has continuation: no"))
        let error = try Self.modeOutput("error", in: output)
        #expect(error.contains("Queue probe failed (error code: 17)"))
    }

    /// Compile the real CLI functions once with only network and cookie loading replaced.
    /// This keeps the test offline without adding a test-only command to API Explorer.
    private static func harnessSource() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/APIExplorer/main.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let textParser = try Self.section(
            in: source,
            startingWith: "func joinedRunsText(",
            endingBefore: "private func findFirstRenderer("
        )
        let queueProbe = try Self.section(
            in: source,
            startingWith: "// MARK: - QueueProbeSong",
            endingBefore: "// MARK: - Commands"
        )
        let outputWriter = try Self.section(
            in: source,
            startingWith: "private func posixError(",
            endingBefore: "private func readBoundedData("
        )
        let outputFunction = "Swift." + "print"
        return """
        import Darwin
        import Foundation

        let forceUnauthenticatedRequests = true
        func loadCookiesFromAppBackup() -> [HTTPCookie]? { nil }
        func makeRequest(endpoint: String, body: [String: Any], authenticated: Bool) async throws
            -> (data: [String: Any], statusCode: Int)
        {
            if body["videoId"] as? String == "test-error-seed" {
                throw NSError(domain: "test-error-domain", code: 17,
                    userInfo: [NSLocalizedDescriptionKey: "test-private-error-description"])
            }
            if body["videoId"] as? String == "test-empty-seed" { return ([:], 200) }
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return (response, 200)
        }

        \(textParser)
        \(queueProbe)
        \(outputWriter)

        for mode in ["default", "verbose", "saved", "empty", "error"] {
            \(outputFunction)("MODE \\(mode) BEGIN")
            let seed = mode == "empty" ? "test-empty-seed" : mode == "error" ? "test-error-seed" : "test-seed-video"
            await probeQueue(
                videoId: seed,
                playlistId: mode == "verbose" ? nil : "test-private-request-playlist",
                verbose: mode == "verbose",
                outputFile: mode == "saved" ? CommandLine.arguments[2] : nil
            )
            \(outputFunction)("MODE \\(mode) END")
        }
        """
    }

    private static func runHarness(
        scriptURL: URL,
        fixtureURL: URL,
        savedURL: URL,
        directory: URL
    ) async throws -> String {
        let stdoutURL = directory.appendingPathComponent("stdout.txt")
        let stderrURL = directory.appendingPathComponent("stderr.txt")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "-swift-version", "6", scriptURL.path, fixtureURL.path, savedURL.path]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        defer {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(!process.isRunning, "Offline queue probe harness exceeded 60 seconds")
        let diagnostic = try String(contentsOf: stderrURL, encoding: .utf8)
        try #require(process.terminationStatus == 0, "Offline queue probe harness failed: \(diagnostic)")
        return try String(contentsOf: stdoutURL, encoding: .utf8)
    }

    private static func syntheticQueueResponse() -> [String: Any] {
        let seed: [String: Any] = ["playlistPanelVideoRenderer": [
            "videoId": "test-seed-video",
            "title": ["runs": [["text": "test-private-title"]]],
            "longBylineText": ["runs": [["text": "test-private-artist"]]],
        ]]
        let wrapped: [String: Any] = ["playlistPanelVideoWrapperRenderer": [
            "primaryRenderer": ["playlistPanelVideoRenderer": ["videoId": "test-second-video"]],
        ]]
        let panel: [String: Any] = [
            "contents": [seed, wrapped, seed, ["playlistPanelVideoRenderer": ["title": "test-unplayable-title"]]],
            "continuations": [["nextRadioContinuationData": ["continuation": "test-private-continuation"]]],
        ]
        let tab: [String: Any] = ["tabRenderer": ["content": ["musicQueueRenderer": [
            "content": ["playlistPanelRenderer": panel],
        ]]]]
        return [
            "test-private-response-key": "test-private-response-value",
            "contents": ["singleColumnMusicWatchNextResultsRenderer": [
                "tabbedRenderer": ["watchNextTabbedResultsRenderer": ["tabs": [tab]]],
            ]],
            "playerOverlays": ["playerOverlayRenderer": ["autoplay": ["playerOverlayAutoplayRenderer": [
                "item": ["compactVideoRenderer": ["videoId": "test-autoplay-video"]],
            ]]]],
            "privateFields": [
                "test-private-identifier": ["test-private-nested-key": "test-private-nested-value"],
                "test-privateRenderer": "test-private-renderer-value",
                "[REDACTED_KEY_0]": "test-private-placeholder-value",
                "videoId": "test-private-video",
                "playlistId": "test-private-playlist",
                "browseId": "test-private-browse",
                "label": "test-private-label",
                "text": "test-private-text",
                "simpleText": "test-private-simple-text",
                "iconType": "test-private-icon",
                "musicVideoType": "test-private-music-video-type",
                "pageType": "test-private-page-type",
                "webPageType": "test-private-web-page-type",
                "unknownField": "test-private-unknown",
                "numericIdentifier": 424_242,
                "selected": true,
                "missing": NSNull(),
                "emptyObject": [:] as [String: Any],
                "emptyArray": [] as [Any],
                "nestedValues": ["test-private-nested", ["text": "test-private-nested-text"], NSNull()],
                "session": ["text": "test-private-session-text", "value": "test-private-session-value"],
                "token": "test-private-token",
                "cookie": "test-cookie",
            ],
        ]
    }

    // swiftformat:disable redundantStaticSelf
    /// Compare container structure without relying on names or ordering of redacted object keys.
    private static func diagnosticShape(_ value: Any) -> String {
        if let object = value as? [String: Any] {
            return "{\(object.values.map(Self.diagnosticShape).sorted().joined(separator: ","))}"
        }
        if let array = value as? [Any] {
            return "[\(array.map(Self.diagnosticShape).joined(separator: ","))]"
        }
        return value is NSNull ? "null" : "scalar"
    }

    private static func expectRedactedValues(_ value: Any) {
        if let object = value as? [String: Any] {
            for nested in object.values {
                Self.expectRedactedValues(nested)
            }
        } else if let array = value as? [Any] {
            for nested in array {
                Self.expectRedactedValues(nested)
            }
        } else if !(value is NSNull) {
            #expect(value as? String == "[REDACTED]")
        }
    }

    // swiftformat:enable redundantStaticSelf

    private static func modeOutput(_ mode: String, in output: String) throws -> Substring {
        let startMarker = "MODE \(mode) BEGIN\n"
        return try Self.section(in: output, startingWith: startMarker, endingBefore: "MODE \(mode) END")
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
