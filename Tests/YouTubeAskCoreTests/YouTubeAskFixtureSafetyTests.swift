import Foundation
import Testing

@Suite("YouTubeAsk fixture and source safety")
struct YouTubeAskFixtureSafetyTests {
    @Test("Every checked-in Ask fixture is placeholder-only and structurally safe")
    func fixturesAreSafe() throws {
        let resourceURL = try #require(Bundle.module.resourceURL)
        let enumerator = try #require(FileManager.default.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ))
        let fixtureURLs = enumerator.compactMap { element -> URL? in
            guard let url = element as? URL, url.pathExtension == "json" else { return nil }
            return url
        }
        #expect(!fixtureURLs.isEmpty)

        for url in fixtureURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            #expect(values.isRegularFile == true)
            #expect(values.isSymbolicLink != true)
            #expect((values.fileSize ?? 0) <= 256 * 1024)

            let data = try Data(contentsOf: url)
            let text = try #require(String(data: data, encoding: .utf8))
            let json = try JSONSerialization.jsonObject(with: data)
            let violations = Self.rawTextViolations(in: text)
                + Self.jsonViolations(in: json, path: "$")
            for violation in violations {
                Issue.record(
                    "Unsafe fixture rule \(violation.rule) at \(violation.path) in \(url.lastPathComponent)"
                )
            }
        }
    }

    @Test("Safety scanner rejects authorization material and realistic opaque values")
    func scannerRejectsUnsafeSyntheticExamples() {
        let syntheticOpaque = String(repeating: "Ab3_Cd4-Ef5.Gh6_", count: 4)
        let sample: [String: Any] = [
            "authorization": "Bearer REDACTED",
            "continuation": syntheticOpaque,
            "contact": "placeholder@example.invalid",
        ]

        let violations = Self.jsonViolations(in: sample, path: "$")
        #expect(violations.count >= 3)
        #expect(violations.contains { $0.rule == "sensitive-key" })
        #expect(violations.contains { $0.rule == "opaque-placeholder-required" })
        #expect(violations.contains { $0.rule == "email-address" })
    }

    @Test("YouTubeAskCore source imports Foundation only")
    func coreImportsFoundationOnly() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = repositoryRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("YouTubeAskCore", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let imports = source
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("import ") }
            #expect(imports == ["import Foundation"])
        }
    }

    @Test("API Explorer free text delegates parsing and request encoding to YouTubeAskCore")
    func apiExplorerUsesSharedFreeTextCore() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("APIExplorer", isDirectory: true)
            .appendingPathComponent("AskVideoAudit.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let loadStart = try #require(source.range(of: "private func loadAskFreeTextCommand("))
        let sendStart = try #require(source.range(
            of: "private func sendAskFreeTextRequest(",
            range: loadStart.upperBound ..< source.endIndex
        ))
        let liveStart = try #require(source.range(
            of: "func liveTestAskVideoFreeText(",
            range: sendStart.upperBound ..< source.endIndex
        ))
        let loadFunction = source[loadStart.lowerBound ..< sendStart.lowerBound]
        let sendFunction = source[sendStart.lowerBound ..< liveStart.lowerBound]

        #expect(loadFunction.contains("YouTubeAskParser.parseBootstrap"))
        #expect(loadFunction.contains("YouTubeAskRequestBuilder.makePanelBootstrapBody"))
        #expect(loadFunction.contains("YouTubeAskParser.parseConversation"))
        #expect(loadFunction.contains("panelConversation.freeTextCommand"))
        #expect(sendFunction.contains("YouTubeAskRequestBuilder.makeFreeTextBody"))
        #expect(sendFunction.contains("YouTubeAskRequestBuilder.makeFreeTextClickTrackingContext"))
        #expect(!source.contains("private struct AskFreeTextCommand"))
        #expect(!source.contains("collectAskFreeTextCommands"))
    }

    @Test("API Explorer freezes one authenticated request snapshot for guarded free text")
    func apiExplorerFreeTextUsesSingleRequestSnapshot() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("APIExplorer", isDirectory: true)
            .appendingPathComponent("AskVideoAudit.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let captureStart = try #require(source.range(
            of: "private func captureAskFreeTextRequestSnapshot()"
        ))
        let wireStart = try #require(source.range(
            of: "private func makeRuntimeAskFreeTextWireRequest(",
            range: captureStart.upperBound ..< source.endIndex
        ))
        let loadStart = try #require(source.range(
            of: "private func loadAskFreeTextCommand(",
            range: wireStart.upperBound ..< source.endIndex
        ))
        let sendStart = try #require(source.range(
            of: "private func sendAskFreeTextRequest(",
            range: loadStart.upperBound ..< source.endIndex
        ))
        let liveStart = try #require(source.range(
            of: "func liveTestAskVideoFreeText(",
            range: sendStart.upperBound ..< source.endIndex
        ))
        let nextFunctionStart = try #require(source.range(
            of: "private func makeAskSummaryRequest(",
            range: liveStart.upperBound ..< source.endIndex
        ))

        let captureFunction = source[captureStart.lowerBound ..< wireStart.lowerBound]
        let wireFunction = source[wireStart.lowerBound ..< loadStart.lowerBound]
        let loadFunction = source[loadStart.lowerBound ..< sendStart.lowerBound]
        let sendFunction = source[sendStart.lowerBound ..< liveStart.lowerBound]
        let liveFunction = source[liveStart.lowerBound ..< nextFunctionStart.lowerBound]

        #expect(captureFunction.contains("resolveAskRuntimeWEBConfiguration(cookies: cookies)"))
        #expect(captureFunction.contains("currentAskFreeTextBackingState()"))
        #expect(captureFunction.contains("requestSnapshotChanged"))

        #expect(wireFunction.contains("requestSnapshot.contextData"))
        #expect(wireFunction.contains("requestSnapshot.headers"))
        #expect(wireFunction.contains("requestSnapshot.runtimeAPIIdentifier"))
        #expect(wireFunction.contains("validateAskFreeTextRequestSnapshot(requestSnapshot)"))
        #expect(!wireFunction.contains("resolveAPIKey("))
        #expect(!wireFunction.contains("buildContext("))
        #expect(!wireFunction.contains("buildHeaders("))
        #expect(!wireFunction.contains("loadCookiesFromAppBackup("))

        #expect(loadFunction.contains("requestSnapshot: AskFreeTextRequestSnapshot"))
        #expect(loadFunction.contains("requestSnapshot: requestSnapshot"))
        #expect(loadFunction.contains("endpoint: \"get_panel\""))
        #expect(loadFunction.contains("bodyData: panelBody"))
        #expect(loadFunction.contains("validateBackingStateBeforeSending: true"))
        #expect(!loadFunction.contains("YouTubeAskRequestBuilder.makeFreeTextBody"))
        #expect(sendFunction.contains("requestSnapshot: AskFreeTextRequestSnapshot"))
        #expect(sendFunction.contains("validateBackingStateBeforeSending: true"))
        #expect(liveFunction.contains("let requestSnapshot = try await captureAskFreeTextRequestSnapshot()"))
        #expect(liveFunction.contains("requestSnapshot: requestSnapshot"))
        let rawVideoIDOutput = "pri" + "nt(\"Video ID: \\(videoID)\")"
        #expect(!liveFunction.contains(rawVideoIDOutput))
    }

    @Test("API Explorer reports free-text capability provenance without opaque values")
    func apiExplorerReportsRedactedFreeTextCapability() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("APIExplorer", isDirectory: true)
            .appendingPathComponent("AskVideoAudit.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let reportStart = try #require(source.range(of: "private struct AskParityReport"))
        let evaluationStart = try #require(source.range(
            of: "private struct AskParityEvaluation",
            range: reportStart.upperBound ..< source.endIndex
        ))
        let nextStart = try #require(source.range(of: "private func evaluateAskParityNext("))
        let panelStart = try #require(source.range(
            of: "private func evaluateAskParityPanel(",
            range: nextStart.upperBound ..< source.endIndex
        ))
        let profileStart = try #require(source.range(
            of: "private func evaluateAskParityProfile(",
            range: panelStart.upperBound ..< source.endIndex
        ))
        let reportFunction = source[reportStart.lowerBound ..< evaluationStart.lowerBound]
        let nextFunction = source[nextStart.lowerBound ..< panelStart.lowerBound]
        let panelFunction = source[panelStart.lowerBound ..< profileStart.lowerBound]

        #expect(reportFunction.contains("free-text-capability: next="))
        #expect(reportFunction.contains("panelFreeTextCapability.rawValue"))
        #expect(!reportFunction.contains("continuation"))
        #expect(!reportFunction.contains("clickTrackingParams"))
        #expect(nextFunction.contains("bootstrap.freeTextCommand == nil ? .absent : .present"))
        #expect(
            panelFunction.contains(
                "panelConversation.freeTextCommand == nil ? .absent : .present"
            )
        )
    }

    private struct Violation {
        let rule: String
        let path: String
    }

    private static let sensitiveKeys: Set<String> = [
        "apisid",
        "authorization",
        "cookie",
        "hsid",
        "sapisid",
        "setcookie",
        "ssid",
    ]

    private static let opaqueValueKeys: Set<String> = [
        "accountid",
        "apikey",
        "channelid",
        "clicktrackingparams",
        "clientmessageid",
        "continuation",
        "conversationid",
        "token",
        "trackingparams",
        "videoid",
        "visitordata",
    ]

    private static func rawTextViolations(in text: String) -> [Violation] {
        var violations: [Violation] = []
        let patterns = [
            ("authorization-scheme", #"(?i)\b(?:bearer|sapisidhash|sapisid1phash|sapisid3phash)\s+\S+"#),
            ("cookie-assignment", #"(?i)(?:^|[;\s])(?:__secure-)?(?:sid|sapisid|hsid|ssid)\s*="#),
        ]
        for (rule, pattern) in patterns
            where text.range(of: pattern, options: .regularExpression) != nil
        {
            violations.append(Violation(rule: rule, path: "$"))
        }
        return violations
    }

    private static func jsonViolations(
        in value: Any,
        path: String
    ) -> [Violation] {
        if let object = value as? [String: Any] {
            return object.flatMap { key, nested -> [Violation] in
                let canonicalKey = Self.canonical(key)
                let nestedPath = "\(path).\(key)"
                var violations: [Violation] = []
                if Self.sensitiveKeys.contains(canonicalKey) {
                    violations.append(Violation(rule: "sensitive-key", path: nestedPath))
                }
                if Self.opaqueValueKeys.contains(canonicalKey),
                   let string = nested as? String,
                   !Self.isSafePlaceholder(string)
                {
                    violations.append(Violation(
                        rule: "opaque-placeholder-required",
                        path: nestedPath
                    ))
                }
                violations.append(contentsOf: Self.jsonViolations(in: nested, path: nestedPath))
                return violations
            }
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, nested in
                Self.jsonViolations(in: nested, path: "\(path)[\(index)]")
            }
        }
        guard let string = value as? String else { return [] }

        var violations: [Violation] = []
        if string.range(
            of: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            options: .regularExpression
        ) != nil {
            violations.append(Violation(rule: "email-address", path: path))
        }
        if Self.containsLongOpaqueCandidate(string), !Self.isSafePlaceholder(string) {
            violations.append(Violation(rule: "high-entropy-value", path: path))
        }
        return violations
    }

    private static func canonical(_ value: String) -> String {
        value.lowercased().unicodeScalars.reduce(into: "") { result, scalar in
            if (0x30 ... 0x39).contains(scalar.value)
                || (0x61 ... 0x7A).contains(scalar.value)
            {
                result.unicodeScalars.append(scalar)
            }
        }
    }

    private static func isSafePlaceholder(_ value: String) -> Bool {
        value.range(
            of: #"^(?:fixture|mock|placeholder|test)-[a-z0-9-]+$"#,
            options: .regularExpression
        ) != nil
            || value.range(of: #"^youchat-[0-9]+$"#, options: .regularExpression) != nil
    }

    private static func containsLongOpaqueCandidate(_ value: String) -> Bool {
        value.range(
            of: #"(?<![A-Za-z0-9_.=-])[A-Za-z0-9_.=-]{48,}(?![A-Za-z0-9_.=-])"#,
            options: .regularExpression
        ) != nil
    }
}
