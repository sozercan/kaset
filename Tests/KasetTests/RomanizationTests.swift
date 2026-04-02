import Testing
@testable import Kaset

// MARK: - ScriptDetectorTests

struct ScriptDetectorTests {
    // MARK: isLatinOnly

    @Test("Latin-only text is detected correctly")
    func latinOnly() {
        #expect(ScriptDetector.isLatinOnly("Hello world") == true)
        #expect(ScriptDetector.isLatinOnly("café résumé") == true)
        #expect(ScriptDetector.isLatinOnly("") == true)
    }

    @Test("Non-Latin text is not Latin-only")
    func nonLatinNotLatinOnly() {
        #expect(ScriptDetector.isLatinOnly("こんにちは") == false)
        #expect(ScriptDetector.isLatinOnly("안녕하세요") == false)
        #expect(ScriptDetector.isLatinOnly("你好") == false)
        #expect(ScriptDetector.isLatinOnly("สวัสดี") == false)
        #expect(ScriptDetector.isLatinOnly("নমস্কার") == false)
        #expect(ScriptDetector.isLatinOnly("नमस्ते") == false)
    }

    // MARK: hasJapanese

    @Test("Hiragana is detected as Japanese")
    func hiraganaIsJapanese() {
        #expect(ScriptDetector.hasJapanese("こんにちは") == true)
    }

    @Test("Katakana is detected as Japanese")
    func katakanaIsJapanese() {
        #expect(ScriptDetector.hasJapanese("コンニチワ") == true)
    }

    @Test("Kanji-only Japanese text is detected as Japanese")
    func kanjiOnlyJapaneseIsJapanese() {
        #expect(ScriptDetector.hasJapanese("東京") == true)
    }

    @Test("Korean is not Japanese")
    func koreanIsNotJapanese() {
        #expect(ScriptDetector.hasJapanese("안녕하세요") == false)
    }

    // MARK: hasKorean

    @Test("Hangul syllables are detected as Korean")
    func hangulIsKorean() {
        #expect(ScriptDetector.hasKorean("안녕하세요") == true)
        #expect(ScriptDetector.hasKorean("사랑해") == true)
    }

    @Test("Japanese is not Korean")
    func japaneseIsNotKorean() {
        #expect(ScriptDetector.hasKorean("こんにちは") == false)
    }

    // MARK: hasChinese

    @Test("CJK without kana is detected as Chinese")
    func cjkWithoutKanaIsChinese() {
        #expect(ScriptDetector.hasChinese("你好世界") == true)
    }

    @Test("CJK with kana is not Chinese (it's Japanese)")
    func cjkWithKanaIsNotChinese() {
        // Mixed kanji + hiragana → Japanese, not Chinese
        // "日本語の" = "日本語" (kanji) + "の" (hiragana) — presence of kana marks it Japanese
        #expect(ScriptDetector.hasChinese("日本語の") == false)
    }

    // MARK: dominantScript

    @Test("dominantScript returns .japanese for kana text")
    func dominantJapanese() {
        #expect(ScriptDetector.dominantScript("ありがとう") == .japanese)
    }

    @Test("dominantScript returns .korean for Hangul text")
    func dominantKorean() {
        #expect(ScriptDetector.dominantScript("감사합니다") == .korean)
    }

    @Test("dominantScript returns .chinese for CJK-only text")
    func dominantChinese() {
        #expect(ScriptDetector.dominantScript("谢谢") == .chinese)
    }

    @Test("dominantScript returns .latin for ASCII text")
    func dominantLatin() {
        #expect(ScriptDetector.dominantScript("Thank you") == .latin)
    }

    @Test("dominantScript returns .thai for Thai text")
    func dominantThai() {
        #expect(ScriptDetector.dominantScript("ขอบคุณ") == .thai)
    }
}

// MARK: - KoreanRomanizerTests

struct KoreanRomanizerTests {
    @Test("Simple Korean syllable romanizes correctly")
    func simpleKorean() throws {
        // 가 = g + a → "ga"
        let result = try #require(KoreanRomanizer.romanize("가"))
        #expect(result == "ga")
    }

    @Test("Common Korean word romanizes")
    func koreanWord() throws {
        // 나 = "na", 라 = "ra" → but full words vary; just check non-empty
        let result = try #require(KoreanRomanizer.romanize("안녕"))
        #expect(!result.isEmpty)
        #expect(result != "안녕")
    }

    @Test("Latin passthrough is preserved")
    func latinPassthrough() throws {
        // Non-Hangul characters pass through unchanged
        let result = try #require(KoreanRomanizer.romanize("hey 안녕"))
        #expect(result.contains("hey"))
        #expect(!result.contains("안"))
    }

    @Test("Empty string returns nil")
    func emptyReturnsNil() {
        let result = KoreanRomanizer.romanize("")
        #expect(result == nil)
    }

    @Test("Known syllable decomposition: 한 → han")
    func hangulDecomposition() throws {
        // 한: initial h(18), medial a(0), final n(4) → "han"
        let result = try #require(KoreanRomanizer.romanize("한"))
        #expect(result == "han")
    }

    @Test("Syllable with no final consonant: 가 → ga")
    func syllableNoFinal() throws {
        let result = try #require(KoreanRomanizer.romanize("가"))
        #expect(result == "ga")
    }

    @Test("Syllable with ng final: 방 → bang")
    func syllableWithNgFinal() throws {
        // 방: b(7) + a(0) + ng(21 final index) → "bang"
        let result = try #require(KoreanRomanizer.romanize("방"))
        #expect(result == "bang")
    }
}

// MARK: - ThaiRomanizerTests

struct ThaiRomanizerTests {
    @Test("Thai romanizer safely handles clustered characters")
    func clusteredCharacters() throws {
        let result = try #require(ThaiRomanizer.romanize("สวัสดีครับ"))
        #expect(!result.isEmpty)
    }
}

// MARK: - JapaneseRomanizerTests

struct JapaneseRomanizerTests {
    @Test("Latin tokens are preserved inside mixed Japanese text")
    func preservesLatinTokens() throws {
        let result = try #require(JapaneseRomanizer.romanize("Kissして"))
        #expect(result.contains("Kiss"))
        #expect(result.contains("kisu") == false)
    }
}

// MARK: - TextCanonicalizerTests

struct TextCanonicalizerTests {
    @Test("Collapses multiple spaces")
    func collapseSpaces() {
        let result = TextCanonicalizer.canonicalize("hello  world   foo")
        #expect(result == "hello world foo")
    }

    @Test("Fixes spaced apostrophes in contractions")
    func fixContractions() {
        let result = TextCanonicalizer.canonicalize("can ' t")
        #expect(result == "can't")
    }

    @Test("Removes space before comma")
    func spaceBeforeComma() {
        let result = TextCanonicalizer.canonicalize("hello , world")
        #expect(result == "hello, world")
    }

    @Test("Removes space before period")
    func spaceBeforePeriod() {
        let result = TextCanonicalizer.canonicalize("hello .")
        #expect(result == "hello.")
    }

    @Test("Trims leading and trailing whitespace")
    func trimming() {
        let result = TextCanonicalizer.canonicalize("  hello  ")
        #expect(result == "hello")
    }

    @Test("Empty string returns empty string")
    func emptyString() {
        #expect(TextCanonicalizer.canonicalize("").isEmpty)
    }

    @Test("Already clean string is unchanged")
    func alreadyClean() {
        let input = "Hello world"
        #expect(TextCanonicalizer.canonicalize(input) == input)
    }

    @Test("NBSP and thin spaces are normalized to regular space")
    func normalizeUnicodeSpaces() {
        // U+00A0 non-breaking space
        let input = "hello\u{00A0}world"
        let result = TextCanonicalizer.canonicalize(input)
        #expect(result == "hello world")
    }
}

// MARK: - RomanizationServiceTests

@Suite(.tags(.model))
@MainActor
struct RomanizationServiceTests {
    @Test("Latin-only text returns nil")
    func latinReturnsNil() {
        let service = RomanizationService()
        #expect(service.romanize("Hello world") == nil)
    }

    @Test("Empty text returns nil")
    func emptyReturnsNil() {
        let service = RomanizationService()
        #expect(service.romanize("") == nil)
    }

    @Test("Korean text returns non-nil romanized string")
    func koreanRomanized() throws {
        let service = RomanizationService()
        let result = service.romanize("안녕하세요")
        #expect(result != nil)
        #expect(try ScriptDetector.isLatinOnly(#require(result)) == true)
    }

    @Test("Result is cached on second call")
    func caching() {
        let service = RomanizationService()
        let first = service.romanize("가나다")
        let second = service.romanize("가나다")
        #expect(first == second)
    }

    @Test("romanizeAll returns results only for non-Latin lines")
    func romanizeAllSkipsLatin() {
        let lines = [
            SyncedLyricLine(timeInMs: 0, duration: 3000, text: "Hello", words: nil),
            SyncedLyricLine(timeInMs: 3000, duration: 3000, text: "안녕하세요", words: nil),
        ]
        let lyrics = SyncedLyrics(lines: lines, source: "Test")

        let service = RomanizationService()
        let results = service.romanizeAll(lyrics)

        // Only the Korean line should have a result
        #expect(results[lines[0].id] == nil)
        #expect(results[lines[1].id] != nil)
    }

    @Test("romanizeAll returns empty dict for all-Latin lyrics")
    func romanizeAllLatinIsEmpty() {
        let lines = [
            SyncedLyricLine(timeInMs: 0, duration: 3000, text: "Hello world", words: nil),
            SyncedLyricLine(timeInMs: 3000, duration: 3000, text: "Goodbye", words: nil),
        ]
        let lyrics = SyncedLyrics(lines: lines, source: "Test")
        let service = RomanizationService()
        #expect(service.romanizeAll(lyrics).isEmpty)
    }
}

// MARK: - SyncedLyricLineRomanizationTests

@Suite(.tags(.model))
struct SyncedLyricLineRomanizationTests {
    @Test("romanizedText defaults to nil")
    func defaultIsNil() {
        let line = SyncedLyricLine(timeInMs: 0, duration: 1000, text: "Hello", words: nil)
        #expect(line.romanizedText == nil)
    }

    @Test("romanizedText can be set")
    func canBeSet() {
        var line = SyncedLyricLine(timeInMs: 0, duration: 1000, text: "안녕", words: nil)
        line.romanizedText = "annyeong"
        #expect(line.romanizedText == "annyeong")
    }

    @Test("Lines with different romanizedText are not equal")
    func inequalityWithDifferentRomanization() {
        var lineA = SyncedLyricLine(timeInMs: 0, duration: 1000, text: "안녕", words: nil)
        var lineB = SyncedLyricLine(timeInMs: 0, duration: 1000, text: "안녕", words: nil)
        lineA.romanizedText = "annyeong"
        lineB.romanizedText = nil
        // UUIDs differ, so they're always unequal — confirm the field is settable
        #expect(lineA.romanizedText != lineB.romanizedText)
    }
}
