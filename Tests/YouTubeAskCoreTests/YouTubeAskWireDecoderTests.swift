import Foundation
import Testing
@testable import YouTubeAskCore

@Suite("YouTubeAsk wire decoder")
struct YouTubeAskWireDecoderTests {
    @Test("Decodes JSON objects and preserves JSON arrays as one root")
    func decodesJSONRoots() throws {
        let objectEnvelope = try YouTubeAskWireDecoder.decode(Data(#"{"value":true}"#.utf8))
        #expect(objectEnvelope.format == .jsonObject)
        #expect(objectEnvelope.frameCount == 1)
        #expect(objectEnvelope.roots.first?["value"] == .bool(true))

        let arrayEnvelope = try YouTubeAskWireDecoder.decode(Data(#"[{"index":1},{"index":2}]"#.utf8))
        #expect(arrayEnvelope.format == .jsonArray)
        #expect(arrayEnvelope.frameCount == 1)
        guard case let .array(items) = try #require(arrayEnvelope.roots.first) else {
            Issue.record("Expected one preserved JSON array root")
            return
        }
        #expect(items.count == 2)
        #expect(items[0]["index"] == .number(1))
        #expect(items[1]["index"] == .number(2))
    }

    @Test("Decodes every supported XSSI prefix after BOM and whitespace", arguments: [")]}'", "for(;;);", "while(1);"])
    func decodesXSSIPrefix(prefix: String) throws {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data(" \n\(prefix),\n{\"value\":\"safe\"}".utf8)
        let envelope = try YouTubeAskWireDecoder.decode(bytes)

        #expect(envelope.hadXSSIPrefix)
        #expect(envelope.format == .jsonObject)
        #expect(envelope.roots.first?["value"] == .string("safe"))
    }

    @Test("Decodes NDJSON with blank lines and CRLF while preserving frame order")
    func decodesNDJSON() throws {
        let data = Data("\r\n{\"index\":1}\r\n\r\n{\"index\":2}\n".utf8)
        let envelope = try YouTubeAskWireDecoder.decode(data)

        #expect(envelope.format == .newlineDelimitedJSON)
        #expect(envelope.frameCount == 2)
        #expect(envelope.roots[0]["index"] == .number(1))
        #expect(envelope.roots[1]["index"] == .number(2))
    }

    @Test("Decodes byte-counted length-prefixed frames with Unicode")
    func decodesLengthPrefixedFrames() throws {
        let first = Data(#"{"text":"Résumé"}"#.utf8)
        let second = Data(#"[{"index":2}]"#.utf8)
        let data = Self.lengthPrefixed([first, second], lineEnding: "\r\n")

        let envelope = try YouTubeAskWireDecoder.decode(data)

        #expect(envelope.format == .lengthPrefixedJSON)
        #expect(envelope.frameCount == 2)
        #expect(envelope.roots[0]["text"] == .string("Résumé"))
        guard case let .array(items) = envelope.roots[1] else {
            Issue.record("Expected array frame")
            return
        }
        #expect(items.first?["index"] == .number(2))
    }

    @Test("Incremental decoding is independent of transport chunk boundaries")
    func incrementalChunkBoundaries() throws {
        let data = Self.lengthPrefixed([
            Data(#"{"frame":1}"#.utf8),
            Data(#"{"frame":2}"#.utf8),
        ])

        for split in 0 ... data.count {
            var decoder = YouTubeAskWireDecoder()
            try decoder.append(data.prefix(split))
            try decoder.append(data.suffix(data.count - split))
            let envelope = try decoder.finish()
            #expect(envelope.frameCount == 2)
            #expect(envelope.roots[0]["frame"] == .number(1))
            #expect(envelope.roots[1]["frame"] == .number(2))
        }

        var byteDecoder = YouTubeAskWireDecoder()
        for byte in data {
            try byteDecoder.append(Data([byte]))
        }
        #expect(try byteDecoder.finish().frameCount == 2)
    }

    @Test("Enforces the total response limit during collection")
    func totalResponseLimit() throws {
        var exactDecoder = YouTubeAskWireDecoder()
        try exactDecoder.append(Data(repeating: 0x20, count: YouTubeAskLimits.maximumResponseBytes))
        expectYouTubeAskError(.emptyResponse) {
            _ = try exactDecoder.finish()
        }

        var oversizedDecoder = YouTubeAskWireDecoder()
        expectYouTubeAskError(.responseTooLarge) {
            try oversizedDecoder.append(
                Data(repeating: 0x20, count: YouTubeAskLimits.maximumResponseBytes + 1)
            )
        }
    }

    @Test("Enforces the per-frame limit at the exact boundary")
    func frameLimit() throws {
        let exactFrame = Self.jsonObject(totalByteCount: YouTubeAskLimits.maximumFrameBytes)
        #expect(try YouTubeAskWireDecoder.decode(exactFrame).format == .jsonObject)

        let oversizedFrame = Self.jsonObject(totalByteCount: YouTubeAskLimits.maximumFrameBytes + 1)
        expectYouTubeAskError(.frameTooLarge) {
            _ = try YouTubeAskWireDecoder.decode(oversizedFrame)
        }

        let oversizedLength = Data("\(YouTubeAskLimits.maximumFrameBytes + 1)\n".utf8)
        expectYouTubeAskError(.frameTooLarge) {
            _ = try YouTubeAskWireDecoder.decode(oversizedLength)
        }
    }

    @Test("Accepts 256 frames and rejects a 257th frame")
    func frameCountLimit() throws {
        let frames = (0 ..< YouTubeAskLimits.maximumFrames).map { index in
            Data("{\"index\":\(index)}".utf8)
        }
        let accepted = frames.reduce(into: Data()) { result, frame in
            result.append(frame)
            result.append(0x0A)
        }
        #expect(try YouTubeAskWireDecoder.decode(accepted).frameCount == 256)

        var rejected = accepted
        rejected.append(Data(#"{"index":256}"#.utf8))
        rejected.append(0x0A)
        expectYouTubeAskError(.tooManyFrames) {
            _ = try YouTubeAskWireDecoder.decode(rejected)
        }
    }

    @Test("Rejects duplicate object members before dictionary materialization")
    func rejectsDuplicateJSONKeys() throws {
        let duplicate = Data(#"{"token":"fixture-a","token":"fixture-b"}"#.utf8)
        expectYouTubeAskError(.duplicateJSONKey) {
            _ = try YouTubeAskWireDecoder.decode(duplicate)
        }

        let escapedDuplicate = Data(#"{"token":1,"to\u006ben":2}"#.utf8)
        expectYouTubeAskError(.duplicateJSONKey) {
            _ = try YouTubeAskWireDecoder.decode(escapedDuplicate)
        }

        let distinctObjects = Data(#"[{"token":"fixture-a"},{"token":"fixture-b"}]"#.utf8)
        #expect(try YouTubeAskWireDecoder.decode(distinctObjects).format == .jsonArray)
    }

    @Test("Malformed later frames fail the whole response")
    func malformedLaterFrameFailsClosed() {
        let malformedNDJSON = Data("{\"frame\":1}\n{not-json}\n".utf8)
        expectYouTubeAskError(.malformedWireResponse) {
            _ = try YouTubeAskWireDecoder.decode(malformedNDJSON)
        }

        let incompleteLengthFrame = Data("12\n{\"short\":1}".utf8)
        expectYouTubeAskError(.malformedWireResponse) {
            _ = try YouTubeAskWireDecoder.decode(incompleteLengthFrame)
        }
    }

    @Test("Rejects scalar roots, repeated finish, and append after finish")
    func rejectsUnsupportedStates() throws {
        expectYouTubeAskError(.unsupportedJSONRoot) {
            _ = try YouTubeAskWireDecoder.decode(Data("42".utf8))
        }

        var decoder = YouTubeAskWireDecoder()
        try decoder.append(Data(#"{}"#.utf8))
        _ = try decoder.finish()
        expectYouTubeAskError(.decoderAlreadyFinished) {
            _ = try decoder.finish()
        }
        expectYouTubeAskError(.decoderAlreadyFinished) {
            try decoder.append(Data())
        }
    }

    @Test("Bounds decoded JSON depth and container width")
    func boundsJSONStructure() throws {
        let depth = YouTubeAskLimits.maximumTreeDepth + 2
        let deepJSON = Data((String(repeating: #"{"next":"#, count: depth) + #"{}"#
                + String(repeating: "}", count: depth)).utf8)
        expectYouTubeAskError(.structureLimitExceeded) {
            _ = try YouTubeAskWireDecoder.decode(deepJSON)
        }

        let wideObject = Dictionary(uniqueKeysWithValues:
            (0 ... YouTubeAskLimits.maximumChildrenPerContainer).map { index in
                ("field-\(index)", index)
            })
        let wideData = try JSONSerialization.data(withJSONObject: wideObject)
        expectYouTubeAskError(.structureLimitExceeded) {
            _ = try YouTubeAskWireDecoder.decode(wideData)
        }
    }

    @Test("Duplicate-key validation enforces width and node budgets before materialization")
    func duplicateKeyValidationBoundsStructure() {
        let wideObject = "{" + (0 ... YouTubeAskLimits.maximumChildrenPerContainer)
            .map { "\"field-\($0)\":0" }
            .joined(separator: ",") + "}"
        expectYouTubeAskError(.structureLimitExceeded) {
            try YouTubeAskJSONDuplicateKeyValidator.validate(Data(wideObject.utf8))
        }

        let leafArray = "[" + Array(repeating: "0", count: 50).joined(separator: ",") + "]"
        let nodeHeavyArray = "[" + Array(
            repeating: leafArray,
            count: YouTubeAskLimits.maximumChildrenPerContainer
        ).joined(separator: ",") + "]"
        expectYouTubeAskError(.structureLimitExceeded) {
            try YouTubeAskJSONDuplicateKeyValidator.validate(Data(nodeHeavyArray.utf8))
        }
    }

    @Test("Duplicate-key validation classifies truncated values as malformed")
    func duplicateKeyValidationRejectsTruncatedValues() {
        expectYouTubeAskError(.malformedWireResponse) {
            try YouTubeAskJSONDuplicateKeyValidator.validate(Data(#"{"value":"#.utf8))
        }
    }

    private static func lengthPrefixed(
        _ frames: [Data],
        lineEnding: String = "\n"
    ) -> Data {
        frames.reduce(into: Data()) { result, frame in
            result.append(Data("\(frame.count)\(lineEnding)".utf8))
            result.append(frame)
        }
    }

    private static func jsonObject(totalByteCount: Int) -> Data {
        let prefix = Data("{\"value\":\"".utf8)
        let suffix = Data("\"}".utf8)
        precondition(totalByteCount >= prefix.count + suffix.count)
        var data = prefix
        data.append(Data(
            repeating: 0x61,
            count: totalByteCount - prefix.count - suffix.count
        ))
        data.append(suffix)
        return data
    }
}
