import Foundation
import Observation

@MainActor
@Observable
final class RomanizationService {
    var isEnabled: Bool {
        SettingsManager.shared.romanizationEnabled
    }

    private var cache: [String: String?] = [:]

    func romanize(_ text: String) -> String? {
        if ScriptDetector.isLatinOnly(text) {
            return nil
        }
        if let cached = self.cache[text] {
            return cached
        }

        let result: String? = switch ScriptDetector.dominantScript(text) {
        case .japanese: JapaneseRomanizer.romanize(text)
        case .korean: KoreanRomanizer.romanize(text)
        case .chinese: ChineseRomanizer.romanize(text)
        case .thai: ThaiRomanizer.romanize(text)
        case .bengali: BengaliRomanizer.romanize(text)
        case .hindi: HindiRomanizer.romanize(text)
        default: nil
        }

        let canonicalized = result.map { TextCanonicalizer.canonicalize($0) }
        let finalResult = (canonicalized != nil && canonicalized != text) ? canonicalized : nil
        self.cache[text] = finalResult
        return finalResult
    }

    func romanizeAll(_ lyrics: SyncedLyrics) -> [UUID: String] {
        var results: [UUID: String] = [:]
        for line in lyrics.lines {
            if let romanized = self.romanize(line.text) {
                results[line.id] = romanized
            }
        }
        return results
    }

    func clearCache() {
        self.cache.removeAll()
    }
}
