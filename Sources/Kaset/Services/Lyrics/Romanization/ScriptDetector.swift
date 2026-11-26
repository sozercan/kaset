import Foundation
import NaturalLanguage

enum Script {
    case latin, japanese, korean, chinese, thai, bengali, hindi, unknown
}

enum ScriptDetector {
    private struct CJKPresence {
        let hasKana: Bool
        let hasCJK: Bool
    }

    private static func cjkPresence(in text: String) -> CJKPresence {
        var hasKana = false
        var hasCJK = false

        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 0x3040, v <= 0x309F {
                hasKana = true
            } else if v >= 0x30A0, v <= 0x30FF {
                hasKana = true
            } else if v >= 0x4E00, v <= 0x9FFF {
                hasCJK = true
            }
        }

        return CJKPresence(hasKana: hasKana, hasCJK: hasCJK)
    }

    private static func isJapaneseCJKText(_ text: String) -> Bool? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        guard let language = recognizer.dominantLanguage else {
            return nil
        }

        if language.rawValue == "ja" {
            return true
        }

        if language.rawValue.hasPrefix("zh") {
            return false
        }

        return nil
    }

    static func hasJapanese(_ text: String) -> Bool {
        let presence = self.cjkPresence(in: text)
        if presence.hasKana {
            return true
        }

        guard presence.hasCJK else {
            return false
        }

        return self.isJapaneseCJKText(text) ?? false
    }

    static func hasKorean(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 0x1100, v <= 0x11FF {
                return true
            }
            if v >= 0xAC00, v <= 0xD7AF {
                return true
            }
            if v >= 0x3130, v <= 0x318F {
                return true
            }
        }
        return false
    }

    static func hasChinese(_ text: String) -> Bool {
        let presence = self.cjkPresence(in: text)
        guard presence.hasCJK else {
            return false
        }

        if presence.hasKana {
            return false
        }

        return !(self.isJapaneseCJKText(text) ?? false)
    }

    static func hasThai(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x0E00 && $0.value <= 0x0E7F }
    }

    static func hasBengali(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x0980 && $0.value <= 0x09FF }
    }

    static func hasHindi(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value >= 0x0900 && $0.value <= 0x097F }
    }

    static func isLatinOnly(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v > 0x024F {
                if v >= 0x2000, v <= 0x206F {
                    continue
                }
                if v >= 0x20A0, v <= 0x20CF {
                    continue
                }
                if v >= 0xFE00, v <= 0xFE0F {
                    continue
                }
                if v >= 0xFFF0, v <= 0xFFFF {
                    continue
                }
                return false
            }
        }
        return true
    }

    static func dominantScript(_ text: String) -> Script {
        if self.hasJapanese(text) {
            return .japanese
        }
        if self.hasKorean(text) {
            return .korean
        }
        if self.hasChinese(text) {
            return .chinese
        }
        if self.hasThai(text) {
            return .thai
        }
        if self.hasBengali(text) {
            return .bengali
        }
        if self.hasHindi(text) {
            return .hindi
        }
        if self.isLatinOnly(text) {
            return .latin
        }
        return .unknown
    }
}
