import Foundation

// MARK: - SearchResponseParser Support

extension SearchResponseParser {
    static func splitMetadataText(_ text: String) -> [String] {
        text.replacingOccurrences(of: "·", with: "•")
            .split(separator: "•", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func descriptionText(from renderer: [String: Any]) -> String? {
        guard let description = renderer["description"] as? [String: Any],
              let runs = description["runs"] as? [[String: Any]]
        else {
            return nil
        }
        let text = ParsingHelpers.joinedRunText(runs).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func isYear(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 4,
              trimmed.allSatisfy(\.isNumber),
              let year = Int(trimmed)
        else {
            return false
        }
        return (1900 ... 2100).contains(year)
    }

    private static let durationUnitSeconds: [String: TimeInterval] = {
        var units: [String: TimeInterval] = [:]
        for unit in [
            "s", "sec", "secs", "second", "seconds", "ثانية", "ثوان", "ثواني",
            "sek", "sekunde", "sekunden", "seg", "segundo", "segundos", "seconde",
            "secondes", "detik", "secondo", "secondi", "초", "seconden", "sekunda",
            "sekundy", "sekund", "segundos", "сек", "секунда", "секунды", "секунд",
            "sekund", "sekunder", "sn", "saniye", "секунда", "секунди", "секунд",
        ] {
            units[unit] = 1
        }
        for unit in [
            "m", "min", "mins", "minute", "minutes", "دقيقة", "دقائق", "minuten",
            "minuto", "minutos", "menit", "minuti", "분", "minuut", "minuten",
            "minuta", "minuty", "minut", "мин", "минута", "минуты", "минут", "minut",
            "minuter", "dk", "dakika", "хв", "хвилина", "хвилини", "хвилин",
        ] {
            units[unit] = 60
        }
        for unit in [
            "h", "hr", "hrs", "hour", "hours", "ساعة", "ساعات", "std", "stunde",
            "stunden", "hora", "horas", "heure", "heures", "jam", "ora", "ore",
            "시간", "uur", "uren", "godzina", "godziny", "godzin", "час", "часа",
            "часов", "timme", "timmar", "saat", "год", "година", "години", "годин",
        ] {
            units[unit] = 3600
        }
        return units
    }()

    private static let relativeDatePrefixes = [
        "منذ ", "قبل ", "vor ", "hace ", "il y a ", "há ",
    ]

    private static let relativeDateSuffixes = [
        " ago", " lalu", " fa", " 전", " geleden", " temu", " назад", " sedan",
        " önce", " тому",
    ]

    private static let monthNames: Set<String> = [
        "jan", "january", "يناير", "januar", "enero", "janvier", "januari", "gennaio",
        "feb", "february", "فبراير", "februar", "febrero", "février", "fevrier", "februari", "febbraio",
        "mar", "march", "مارس", "märz", "maerz", "marzo", "mars", "maret", "marzec", "março", "março",
        "apr", "april", "أبريل", "ابريل", "abril", "avril", "aprile", "kwiecień", "kwiecien", "апрель", "квітень",
        "may", "مايو", "mai", "mayo", "mei", "maggio", "maj", "май", "mayıs", "mayis", "травень",
        "jun", "june", "يونيو", "juni", "junio", "juin", "giugno", "czerwiec", "junho", "июнь", "haziran", "червень",
        "jul", "july", "يوليو", "juli", "julio", "juillet", "luglio", "lipiec", "julho", "июль", "temmuz", "липень",
        "aug", "august", "أغسطس", "اغسطس", "agosto", "août", "aout", "agustus", "augustus", "sierpień", "sierpien", "август", "augusti", "ağustos", "agustos", "серпень",
        "sep", "sept", "september", "سبتمبر", "septiembre", "septembre", "settembre", "wrzesień", "wrzesien", "setembro", "сентябрь", "eylül", "eylul", "вересень",
        "oct", "okt", "october", "أكتوبر", "اكتوبر", "oktober", "octubre", "octobre", "ottobre", "październik", "pazdziernik", "outubro", "октябрь", "ekim", "жовтень",
        "nov", "november", "نوفمبر", "noviembre", "novembre", "listopad", "ноябрь", "kasım", "kasim", "листопад",
        "dec", "dez", "december", "ديسمبر", "diciembre", "décembre", "decembre", "desember", "dicembre", "grudzień", "grudzien", "dezembro", "декабрь", "aralık", "aralik", "грудень",
        "maart",
        "stycznia", "lutego", "marca", "kwietnia", "maja", "czerwca", "lipca", "sierpnia", "września", "wrzesnia", "października", "pazdziernika", "listopada", "grudnia",
        "января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря",
        "січня", "лютого", "березня", "квітня", "травня", "червня", "липня", "серпня", "вересня", "жовтня", "листопада", "грудня",
    ]

    static func looksLikeDuration(_ text: String) -> Bool {
        self.durationSeconds(text) != nil
    }

    static func durationSeconds(_ text: String) -> TimeInterval? {
        if let seconds = ParsingHelpers.parseDuration(text) {
            return seconds
        }
        guard let (number, unit) = Self.leadingNumberAndUnit(in: text),
              let multiplier = Self.durationUnitSeconds[unit]
        else {
            return nil
        }
        return number * multiplier
    }

    static func looksLikePublishedDate(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.containsNumber(normalized) else { return false }

        if Self.relativeDatePrefixes.contains(where: normalized.hasPrefix)
            || Self.relativeDateSuffixes.contains(where: normalized.hasSuffix)
        {
            return true
        }
        if Self.containsFourDigitYear(normalized) {
            return true
        }
        if normalized.range(
            of: #"^\s*\d{1,4}[./-]\d{1,2}(?:[./-]\d{1,4})?\s*$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if normalized.contains("월"), normalized.contains("일") {
            return true
        }

        let words = Set(normalized.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: Self.monthNames)
    }

    static func looksLikeCount(_ text: String) -> Bool {
        self.hasLocalizedCountUnit(text)
    }

    private static func leadingNumberAndUnit(in text: String) -> (Double, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var numberText = ""
        var sawDigit = false
        var sawDecimalSeparator = false
        var index = trimmed.startIndex

        while index < trimmed.endIndex {
            let character = trimmed[index]
            if let value = character.wholeNumberValue {
                numberText.append(String(value))
                sawDigit = true
            } else if sawDigit,
                      !sawDecimalSeparator,
                      character == "." || character == "," || character == "٫"
            {
                numberText.append(".")
                sawDecimalSeparator = true
            } else if !sawDigit, character.isWhitespace {
                // Permit leading whitespace already preserved by unusual Unicode spacing.
            } else {
                break
            }
            index = trimmed.index(after: index)
        }

        guard sawDigit, let number = Double(numberText) else { return nil }
        let unit = String(trimmed[index...])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
        guard !unit.isEmpty else { return nil }
        return (number, unit)
    }

    private static func containsNumber(_ text: String) -> Bool {
        text.contains { $0.wholeNumberValue != nil }
    }

    private static func containsFourDigitYear(_ text: String) -> Bool {
        var digits = ""
        func isYear(_ value: String) -> Bool {
            value.count == 4 && Int(value).map { (1900 ... 2100).contains($0) } == true
        }

        for character in text {
            if let value = character.wholeNumberValue {
                digits.append(String(value))
            } else {
                if isYear(digits) {
                    return true
                }
                digits.removeAll(keepingCapacity: true)
            }
        }
        return isYear(digits)
    }

    private static let countMetadataUnits: Set<String> = [
        "subscriber", "subscribers", "view", "views", "play", "plays", "episode", "episodes", "song", "songs",
        "track", "tracks", "حلقة", "الحلقات", "أغنية", "أغاني", "أغانٍ", "مقطوعات", "folge", "folgen",
        "titel", "titeln", "episodio", "episodios", "canción", "canciones", "pista", "pistas", "épisode",
        "épisodes", "morceau", "morceaux", "titre", "titres", "lagu", "trek", "episodi", "brano", "brani",
        "에피소드", "노래", "곡", "트랙", "aflevering", "afleveringen", "nummer", "nummers", "odcinek",
        "odcinki", "utwór", "utwory", "utworów", "utworami", "episódio", "episódios", "música", "músicas",
        "faixa", "faixas", "выпуск", "выпуски", "трек", "треки", "треков", "avsnitt", "låt", "låtar",
        "spår", "bölüm", "bölümler", "şarkı", "şarkılar", "parça", "епізод", "епізоди", "пісня",
        "пісні", "пісень", "треків",
    ]

    static func hasLocalizedCountUnit(_ text: String) -> Bool {
        let normalized = text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.contains(where: \.isNumber),
              let unit = normalized.split(whereSeparator: { character in
                  character.isWhitespace || character.isNumber || character == "." || character == ","
              }).last.map(String.init)
        else { return false }
        return Self.countMetadataUnits.contains(unit)
            || ["выпуск", "odcin", "епізод"].contains { unit.hasPrefix($0) }
    }

    static func playbackProgress(from renderer: [String: Any]) -> Double {
        guard let rawProgress = renderer["playbackProgress"] as? Double else {
            return 0
        }
        if rawProgress > 1 {
            return min(rawProgress / 100, 1)
        }
        return max(0, min(rawProgress, 1))
    }

    static func extractContinuationToken(from renderer: [String: Any]) -> String? {
        if let continuations = renderer["continuations"] as? [[String: Any]] {
            for continuation in continuations {
                for key in ["nextContinuationData", "reloadContinuationData"] {
                    guard let continuationData = continuation[key] as? [String: Any],
                          let token = continuationData["continuation"] as? String,
                          !token.isEmpty
                    else {
                        continue
                    }
                    return token
                }
            }
        }

        if let contents = renderer["contents"] as? [[String: Any]] {
            for content in contents {
                if let token = Self.extractContinuationToken(fromContinuationItem: content) {
                    return token
                }
            }
        }
        return nil
    }

    static func extractContinuationToken(fromContinuationItem item: [String: Any]) -> String? {
        guard let renderer = item["continuationItemRenderer"] as? [String: Any],
              let endpoint = renderer["continuationEndpoint"] as? [String: Any],
              let command = endpoint["continuationCommand"] as? [String: Any],
              let token = command["token"] as? String,
              !token.isEmpty
        else {
            return nil
        }
        return token
    }
}
