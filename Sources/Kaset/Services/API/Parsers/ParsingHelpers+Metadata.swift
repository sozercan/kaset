import Foundation

extension ParsingHelpers {
    static func isLocalizedContentTypeText(_ text: String) -> Bool {
        self.localizedContentTypeKeywords.contains(
            text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    static func isEnglishEngagementCount(_ text: String) -> Bool {
        let components = text.lowercased().split(whereSeparator: \.isWhitespace)
        guard components.count == 2,
              let unit = components.last,
              self.englishEngagementCountUnits.contains(String(unit))
        else {
            return false
        }

        let count = components[0]
        return count == "no" || count.allSatisfy(self.englishEngagementCountCharacters.contains)
    }

    private static let englishEngagementCountUnits: Set<String> = [
        "episode", "episodes", "play", "plays", "subscriber", "subscribers", "view", "views",
    ]
    private static let englishEngagementCountCharacters = Set("0123456789.,+kmbt")

    private static let localizedContentTypeKeywords: Set<String> = [
        "album", "single", "ep", "ألبوم", "أغنية منفردة", "álbum", "sencillo", "singel", "singolo", "싱글",
        "singiel", "сингл", "tekli", "앨범", "альбом", "albüm",
        "artist", "فنان", "interpret", "artista", "artiste", "artis", "아티스트", "artiest", "artysta",
        "исполнитель", "sanatçı", "виконавець",
        "audiobook", "كتاب صوتي", "hörbuch", "audiolibro", "livre audio", "buku audio", "오디오북",
        "luisterboek", "аудиокнига", "ljudbok", "sesli kitap", "аудіокнига",
        "episode", "podcast episode", "حلقة", "folge", "episodio", "épisode", "에피소드", "aflevering",
        "odcinek", "episódio", "выпуск", "avsnitt", "bölüm", "епізод",
        "playlist", "قائمة تشغيل", "lista de reproducción", "daftar putar", "재생목록", "afspeellijst",
        "playlista", "lista de reprodução", "плейлист", "spellista", "çalma listesi",
        "podcast", "بودكاست", "팟캐스트", "подкаст", "podd",
        "profile", "الملف الشخصي", "profil", "perfil", "profilo", "프로필", "profiel", "профиль", "профіль",
        "song", "أغنية", "titel", "canción", "morceau", "lagu", "brano", "노래", "nummer", "utwór",
        "música", "трек", "låt", "şarkı", "пісня",
        "video", "فيديو", "vídeo", "vidéo", "동영상", "wideo", "видео", "відео",
    ]
    static func isMetadataText(_ text: String) -> Bool {
        if self.isLocalizedContentTypeText(text) {
            return true
        }

        let lowercased = text.lowercased()

        if self.isEnglishEngagementCount(text) {
            return true
        }

        if text.contains(":"), self.parseDuration(text) != nil {
            return true
        }

        if self.containsDurationUnit(in: lowercased), self.isNaturalLanguageDuration(text) {
            return true
        }

        if lowercased.contains("song") || lowercased.contains("track") {
            if self.extractSongCount(from: text) != nil {
                return true
            }
        }

        return self.isStandaloneYear(text)
    }

    private static func isStandaloneYear(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 4,
              trimmed.allSatisfy(\.isNumber),
              let year = Int(trimmed)
        else {
            return false
        }

        return (1900 ... 2100).contains(year)
    }

    private static func isNaturalLanguageDuration(_ text: String) -> Bool {
        let lowercased = text.lowercased()

        guard Self.containsDurationUnit(in: lowercased) else {
            return false
        }

        return lowercased.allSatisfy { character in
            character.isNumber
                || character.isWhitespace
                || character == ","
                || Self.durationUnitCharacters.contains(character)
        }
    }

    private static let durationUnits = ["second", "seconds", "minute", "minutes", "hour", "hours"]
    private static let durationUnitCharacters = Set("secondsecondsminuteminuteshourhours")

    private static func containsDurationUnit(in lowercasedText: String) -> Bool {
        self.durationUnits.contains { lowercasedText.contains($0) }
    }
}
