import Foundation

/// Validates JSON member uniqueness before Foundation materializes objects as
/// dictionaries, which would otherwise discard duplicate-key evidence.
enum YouTubeAskJSONDuplicateKeyValidator {
    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: [UInt8](data))
        try parser.validate()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var visitedNodes = 0

        mutating func validate() throws {
            self.skipWhitespace()
            try self.parseValue(depth: 0)
            self.skipWhitespace()
            guard self.index == self.bytes.count else {
                throw YouTubeAskCoreError.malformedWireResponse
            }
        }

        private mutating func parseValue(depth: Int) throws {
            guard self.index < self.bytes.count else {
                throw YouTubeAskCoreError.malformedWireResponse
            }
            guard depth <= YouTubeAskLimits.maximumTreeDepth,
                  self.visitedNodes < YouTubeAskLimits.maximumTreeNodes
            else {
                throw YouTubeAskCoreError.structureLimitExceeded
            }
            self.visitedNodes += 1

            switch self.bytes[self.index] {
            case 0x7B:
                try self.parseObject(depth: depth)
            case 0x5B:
                try self.parseArray(depth: depth)
            case 0x22:
                _ = try self.parseString()
            case 0x74:
                try self.consumeLiteral("true")
            case 0x66:
                try self.consumeLiteral("false")
            case 0x6E:
                try self.consumeLiteral("null")
            case 0x2D, 0x30 ... 0x39:
                try self.parseNumber()
            default:
                throw YouTubeAskCoreError.malformedWireResponse
            }
        }

        private mutating func parseObject(depth: Int) throws {
            self.index += 1
            self.skipWhitespace()
            if self.consumeIfPresent(0x7D) {
                return
            }

            var keys: Set<String> = []
            var childCount = 0
            while true {
                guard childCount < YouTubeAskLimits.maximumChildrenPerContainer else {
                    throw YouTubeAskCoreError.structureLimitExceeded
                }
                childCount += 1
                guard self.index < self.bytes.count, self.bytes[self.index] == 0x22 else {
                    throw YouTubeAskCoreError.malformedWireResponse
                }
                let key = try self.parseString()
                guard keys.insert(key).inserted else {
                    throw YouTubeAskCoreError.duplicateJSONKey
                }

                self.skipWhitespace()
                guard self.consumeIfPresent(0x3A) else {
                    throw YouTubeAskCoreError.malformedWireResponse
                }
                self.skipWhitespace()
                try self.parseValue(depth: depth + 1)
                self.skipWhitespace()

                if self.consumeIfPresent(0x7D) {
                    return
                }
                guard self.consumeIfPresent(0x2C) else {
                    throw YouTubeAskCoreError.malformedWireResponse
                }
                self.skipWhitespace()
            }
        }

        private mutating func parseArray(depth: Int) throws {
            self.index += 1
            self.skipWhitespace()
            if self.consumeIfPresent(0x5D) {
                return
            }

            var childCount = 0
            while true {
                guard childCount < YouTubeAskLimits.maximumChildrenPerContainer else {
                    throw YouTubeAskCoreError.structureLimitExceeded
                }
                childCount += 1
                try self.parseValue(depth: depth + 1)
                self.skipWhitespace()
                if self.consumeIfPresent(0x5D) {
                    return
                }
                guard self.consumeIfPresent(0x2C) else {
                    throw YouTubeAskCoreError.malformedWireResponse
                }
                self.skipWhitespace()
            }
        }

        private mutating func parseString() throws -> String {
            let start = self.index
            self.index += 1

            while self.index < self.bytes.count {
                let byte = self.bytes[self.index]
                if byte == 0x22 {
                    self.index += 1
                    let data = Data(self.bytes[start ..< self.index])
                    guard let decoded = try JSONSerialization.jsonObject(
                        with: data,
                        options: [.fragmentsAllowed]
                    ) as? String else {
                        throw YouTubeAskCoreError.malformedWireResponse
                    }
                    return decoded
                }
                if byte == 0x5C {
                    self.index += 1
                    guard self.index < self.bytes.count else {
                        throw YouTubeAskCoreError.malformedWireResponse
                    }
                    if self.bytes[self.index] == 0x75 {
                        guard self.index + 4 < self.bytes.count else {
                            throw YouTubeAskCoreError.malformedWireResponse
                        }
                        for offset in 1 ... 4 where !Self.isHexDigit(self.bytes[self.index + offset]) {
                            throw YouTubeAskCoreError.malformedWireResponse
                        }
                        self.index += 5
                    } else {
                        self.index += 1
                    }
                    continue
                }
                guard byte >= 0x20 else {
                    throw YouTubeAskCoreError.malformedWireResponse
                }
                self.index += 1
            }
            throw YouTubeAskCoreError.malformedWireResponse
        }

        private mutating func parseNumber() throws {
            if self.consumeIfPresent(0x2D), self.index >= self.bytes.count {
                throw YouTubeAskCoreError.malformedWireResponse
            }

            if self.consumeIfPresent(0x30) {
                if self.index < self.bytes.count,
                   (0x30 ... 0x39).contains(self.bytes[self.index])
                {
                    throw YouTubeAskCoreError.malformedWireResponse
                }
            } else {
                try self.consumeDigits(requiringNonzeroFirst: true)
            }

            if self.consumeIfPresent(0x2E) {
                try self.consumeDigits(requiringNonzeroFirst: false)
            }
            if self.index < self.bytes.count,
               self.bytes[self.index] == 0x65 || self.bytes[self.index] == 0x45
            {
                self.index += 1
                if self.index < self.bytes.count,
                   self.bytes[self.index] == 0x2B || self.bytes[self.index] == 0x2D
                {
                    self.index += 1
                }
                try self.consumeDigits(requiringNonzeroFirst: false)
            }
        }

        private mutating func consumeDigits(requiringNonzeroFirst: Bool) throws {
            guard self.index < self.bytes.count else {
                throw YouTubeAskCoreError.malformedWireResponse
            }
            let first = self.bytes[self.index]
            let validFirst = requiringNonzeroFirst
                ? (0x31 ... 0x39).contains(first)
                : (0x30 ... 0x39).contains(first)
            guard validFirst else {
                throw YouTubeAskCoreError.malformedWireResponse
            }
            self.index += 1
            while self.index < self.bytes.count,
                  (0x30 ... 0x39).contains(self.bytes[self.index])
            {
                self.index += 1
            }
        }

        private mutating func consumeLiteral(_ literal: StaticString) throws {
            let literalBytes = Array(String(describing: literal).utf8)
            guard literalBytes.count <= self.bytes.count - self.index,
                  self.bytes[self.index ..< self.index + literalBytes.count]
                  .elementsEqual(literalBytes)
            else {
                throw YouTubeAskCoreError.malformedWireResponse
            }
            self.index += literalBytes.count
        }

        private mutating func skipWhitespace() {
            while self.index < self.bytes.count {
                switch self.bytes[self.index] {
                case 0x09, 0x0A, 0x0D, 0x20:
                    self.index += 1
                default:
                    return
                }
            }
        }

        private mutating func consumeIfPresent(_ byte: UInt8) -> Bool {
            guard self.index < self.bytes.count, self.bytes[self.index] == byte else {
                return false
            }
            self.index += 1
            return true
        }

        private static func isHexDigit(_ byte: UInt8) -> Bool {
            (0x30 ... 0x39).contains(byte)
                || (0x41 ... 0x46).contains(byte)
                || (0x61 ... 0x66).contains(byte)
        }
    }
}
