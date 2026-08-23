import Foundation

// MARK: - YouTubeAskWireEnvelope

package struct YouTubeAskWireEnvelope: Sendable {
    package enum Format: Equatable, Sendable {
        case jsonObject
        case jsonArray
        case newlineDelimitedJSON
        case lengthPrefixedJSON
    }

    package let format: Format
    package let hadXSSIPrefix: Bool
    package let roots: [YouTubeAskJSONValue]

    package var frameCount: Int {
        self.roots.count
    }
}

// MARK: - YouTubeAskWireDecoder

package struct YouTubeAskWireDecoder: Sendable {
    private var buffer = Data()
    private var didFinish = false

    package init() {}

    package static func decode(_ data: Data) throws -> YouTubeAskWireEnvelope {
        var decoder = YouTubeAskWireDecoder()
        try decoder.append(data)
        return try decoder.finish()
    }

    package mutating func append(_ data: Data) throws {
        guard !self.didFinish else {
            throw YouTubeAskCoreError.decoderAlreadyFinished
        }
        guard data.count <= YouTubeAskLimits.maximumResponseBytes - self.buffer.count else {
            throw YouTubeAskCoreError.responseTooLarge
        }
        self.buffer.append(data)
    }

    package mutating func finish() throws -> YouTubeAskWireEnvelope {
        guard !self.didFinish else {
            throw YouTubeAskCoreError.decoderAlreadyFinished
        }
        self.didFinish = true

        let prepared = Self.prepare([UInt8](self.buffer))
        let bytes = prepared.bytes
        let plainJSONBytes = Self.trimASCIIWhitespace(bytes)
        guard !plainJSONBytes.isEmpty else {
            throw YouTubeAskCoreError.emptyResponse
        }

        var budget = JSONTraversalBudget()
        switch try Self.parseLengthPrefixedJSON(bytes, budget: &budget) {
        case .notMatched:
            break
        case let .matched(roots):
            return YouTubeAskWireEnvelope(
                format: .lengthPrefixedJSON,
                hadXSSIPrefix: prepared.hadXSSIPrefix,
                roots: roots
            )
        }

        if plainJSONBytes.count <= YouTubeAskLimits.maximumFrameBytes,
           let root = try Self.attemptJSONFrame(Data(plainJSONBytes), budget: &budget)
        {
            let format: YouTubeAskWireEnvelope.Format = switch root {
            case .object:
                .jsonObject
            case .array:
                .jsonArray
            default:
                throw YouTubeAskCoreError.unsupportedJSONRoot
            }
            return YouTubeAskWireEnvelope(
                format: format,
                hadXSSIPrefix: prepared.hadXSSIPrefix,
                roots: [root]
            )
        }

        if let roots = try Self.parseNewlineDelimitedJSON(bytes, budget: &budget) {
            return YouTubeAskWireEnvelope(
                format: .newlineDelimitedJSON,
                hadXSSIPrefix: prepared.hadXSSIPrefix,
                roots: roots
            )
        }

        if plainJSONBytes.count > YouTubeAskLimits.maximumFrameBytes {
            throw YouTubeAskCoreError.frameTooLarge
        }
        throw YouTubeAskCoreError.malformedWireResponse
    }

    private enum StreamMatch {
        case notMatched
        case matched([YouTubeAskJSONValue])
    }

    private struct PreparedBytes {
        let bytes: [UInt8]
        let hadXSSIPrefix: Bool
    }

    private struct JSONTraversalBudget {
        var visitedNodes = 0

        mutating func visit(
            depth: Int,
            childCount: Int = 0
        ) throws {
            guard depth <= YouTubeAskLimits.maximumTreeDepth,
                  self.visitedNodes < YouTubeAskLimits.maximumTreeNodes,
                  childCount <= YouTubeAskLimits.maximumChildrenPerContainer
            else {
                throw YouTubeAskCoreError.structureLimitExceeded
            }
            self.visitedNodes += 1
        }
    }

    private static func prepare(_ bytes: [UInt8]) -> PreparedBytes {
        var index = 0
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            index = 3
        }
        Self.skipASCIIWhitespace(in: bytes, index: &index)

        let prefixes = [
            Array(")]}'".utf8),
            Array("for(;;);".utf8),
            Array("while(1);".utf8),
        ]
        let matchedPrefix = prefixes.first { prefix in
            prefix.count <= bytes.count - index
                && bytes[index ..< index + prefix.count].elementsEqual(prefix)
        }
        if let matchedPrefix {
            index += matchedPrefix.count
            if index < bytes.count, bytes[index] == 0x2C {
                index += 1
            }
            Self.skipASCIIWhitespace(in: bytes, index: &index)
        }

        let remainder = index < bytes.count ? Array(bytes[index ..< bytes.count]) : []
        return PreparedBytes(bytes: remainder, hadXSSIPrefix: matchedPrefix != nil)
    }

    private static func attemptJSONFrame(
        _ data: Data,
        budget: inout JSONTraversalBudget
    ) throws -> YouTubeAskJSONValue? {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return nil
        }
        guard raw is [String: Any] || raw is [Any] else {
            throw YouTubeAskCoreError.unsupportedJSONRoot
        }
        try YouTubeAskJSONDuplicateKeyValidator.validate(data)
        return try Self.convert(raw, depth: 0, budget: &budget)
    }

    private static func decodeRequiredJSONFrame(
        _ bytes: [UInt8],
        budget: inout JSONTraversalBudget
    ) throws -> YouTubeAskJSONValue {
        guard bytes.count <= YouTubeAskLimits.maximumFrameBytes else {
            throw YouTubeAskCoreError.frameTooLarge
        }
        guard let value = try attemptJSONFrame(Data(bytes), budget: &budget) else {
            throw YouTubeAskCoreError.malformedWireResponse
        }
        return value
    }

    private static func parseLengthPrefixedJSON(
        _ bytes: [UInt8],
        budget: inout JSONTraversalBudget
    ) throws -> StreamMatch {
        var index = 0
        var roots: [YouTubeAskJSONValue] = []

        while true {
            Self.skipASCIIWhitespace(in: bytes, index: &index)
            if index >= bytes.count {
                return roots.isEmpty ? .notMatched : .matched(roots)
            }
            if roots.count >= YouTubeAskLimits.maximumFrames {
                throw YouTubeAskCoreError.tooManyFrames
            }

            guard (0x30 ... 0x39).contains(bytes[index]) else {
                if roots.isEmpty {
                    return .notMatched
                }
                throw YouTubeAskCoreError.malformedWireResponse
            }

            let lineStart = index
            while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                index += 1
            }
            guard index < bytes.count else {
                if roots.isEmpty {
                    return .notMatched
                }
                throw YouTubeAskCoreError.malformedWireResponse
            }

            let lengthBytes = Self.trimASCIIWhitespace(Array(bytes[lineStart ..< index]))
            guard !lengthBytes.isEmpty,
                  lengthBytes.allSatisfy({ (0x30 ... 0x39).contains($0) })
            else {
                throw YouTubeAskCoreError.malformedWireResponse
            }

            var length = 0
            for byte in lengthBytes {
                let digit = Int(byte - 0x30)
                guard length <= (YouTubeAskLimits.maximumFrameBytes - digit) / 10 else {
                    throw YouTubeAskCoreError.frameTooLarge
                }
                length = length * 10 + digit
            }
            guard length > 0 else {
                throw YouTubeAskCoreError.malformedWireResponse
            }

            if bytes[index] == 0x0D {
                index += 1
                if index < bytes.count, bytes[index] == 0x0A {
                    index += 1
                }
            } else {
                index += 1
            }

            guard length <= bytes.count - index else {
                throw YouTubeAskCoreError.malformedWireResponse
            }
            let frameBytes = Array(bytes[index ..< index + length])
            try roots.append(Self.decodeRequiredJSONFrame(frameBytes, budget: &budget))
            index += length
        }
    }

    private static func parseNewlineDelimitedJSON(
        _ bytes: [UInt8],
        budget: inout JSONTraversalBudget
    ) throws -> [YouTubeAskJSONValue]? {
        var roots: [YouTubeAskJSONValue] = []
        var lineStart = 0
        var index = 0
        var sawLineBreak = false

        while index <= bytes.count {
            if index < bytes.count, bytes[index] != 0x0A {
                guard index - lineStart <= YouTubeAskLimits.maximumFrameBytes else {
                    throw YouTubeAskCoreError.frameTooLarge
                }
                index += 1
                continue
            }

            if index < bytes.count {
                sawLineBreak = true
            }
            let line = Self.trimASCIIWhitespace(Array(bytes[lineStart ..< index]))
            if !line.isEmpty {
                guard roots.count < YouTubeAskLimits.maximumFrames else {
                    throw YouTubeAskCoreError.tooManyFrames
                }
                try roots.append(Self.decodeRequiredJSONFrame(line, budget: &budget))
            }

            guard index < bytes.count else { break }
            index += 1
            lineStart = index
        }

        guard sawLineBreak, !roots.isEmpty else { return nil }
        return roots
    }

    private static func convert(
        _ raw: Any,
        depth: Int,
        budget: inout JSONTraversalBudget
    ) throws -> YouTubeAskJSONValue {
        if let object = raw as? [String: Any] {
            try budget.visit(depth: depth, childCount: object.count)
            var converted: [String: YouTubeAskJSONValue] = [:]
            converted.reserveCapacity(object.count)
            for key in object.keys.sorted() {
                guard let value = object[key] else { continue }
                converted[key] = try Self.convert(value, depth: depth + 1, budget: &budget)
            }
            return .object(converted)
        }
        if let array = raw as? [Any] {
            try budget.visit(depth: depth, childCount: array.count)
            return try .array(array.map { value in
                try Self.convert(value, depth: depth + 1, budget: &budget)
            })
        }

        try budget.visit(depth: depth)
        if let string = raw as? String {
            return .string(string)
        }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if raw is NSNull {
            return .null
        }
        throw YouTubeAskCoreError.malformedWireResponse
    }

    private static func skipASCIIWhitespace(
        in bytes: [UInt8],
        index: inout Int
    ) {
        while index < bytes.count, self.isASCIIWhitespace(bytes[index]) {
            index += 1
        }
    }

    private static func trimASCIIWhitespace(_ bytes: [UInt8]) -> [UInt8] {
        var start = 0
        var end = bytes.count
        while start < end, Self.isASCIIWhitespace(bytes[start]) {
            start += 1
        }
        while end > start, Self.isASCIIWhitespace(bytes[end - 1]) {
            end -= 1
        }
        return Array(bytes[start ..< end])
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x20
    }
}
