import Foundation

enum AudienceTextFormatter {
    private struct LocaleProfile {
        let locale: Locale
        let bundle: Bundle
    }

    private enum AudienceMetric {
        case monthlyAudience
        case subscriberCount
    }

    static func formatMonthlyAudience(_ rawValue: String, languageCode: String) -> String? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        let profile = self.localeProfile(for: languageCode)
        let formattedCount = self.formatCompactCount(trimmedValue, profile: profile) ?? trimmedValue
        let format = self.localizedString("Monthly audience: %@", profile: profile)
        return String(format: format, formattedCount)
    }

    static func formatSubscriberCount(_ rawValue: String, languageCode: String) -> String {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return trimmedValue }

        let profile = self.localeProfile(for: languageCode)
        return self.formatCompactCount(trimmedValue, profile: profile)
            ?? self.trimEnglishAudienceDescriptors(from: trimmedValue)
    }

    static func formatAudienceOrSubscriber(_ rawValue: String, languageCode: String) -> String? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        if self.detectMetric(in: trimmedValue) == .monthlyAudience {
            let compactCount = self.trimEnglishAudienceDescriptors(from: trimmedValue)
            return self.formatMonthlyAudience(compactCount, languageCode: languageCode)
        }

        if self.detectMetric(in: trimmedValue) == .subscriberCount {
            return self.formatSubscriberCount(trimmedValue, languageCode: languageCode)
        }

        return trimmedValue
    }

    private static func localeProfile(for languageCode: String) -> LocaleProfile {
        let normalizedLanguageCode = languageCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        let locale = Locale(identifier: normalizedLanguageCode)
        let resolvedLanguageCode = locale.language.languageCode?.identifier ?? normalizedLanguageCode.lowercased()
        let bundle = self.localizedBundle(for: resolvedLanguageCode) ?? AppLocalization.baseBundle
        return LocaleProfile(locale: locale, bundle: bundle)
    }

    private static func localizedBundle(for languageCode: String) -> Bundle? {
        guard let path = AppLocalization.baseBundle.path(forResource: languageCode, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }

    private static func localizedString(_ key: String, profile: LocaleProfile) -> String {
        profile.bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private static func formatCompactCount(_ rawValue: String, profile: LocaleProfile) -> String? {
        guard let numericValue = self.parseNumericCount(rawValue) else { return nil }

        let formattedValue = numericValue.formatted(
            .number
                .notation(.compactName)
                .precision(.fractionLength(0 ... 2))
                .locale(profile.locale)
        )

        return self.normalizedWhitespace(formattedValue)
    }

    private static func parseNumericCount(_ rawValue: String) -> Double? {
        let trimmedValue = self.trimEnglishAudienceDescriptors(from: rawValue)
        guard !trimmedValue.isEmpty else { return nil }

        let lastCharacter = trimmedValue.last
        let multiplier: Double
        let numericPart: String

        switch lastCharacter {
        case "K":
            multiplier = 1000
            numericPart = String(trimmedValue.dropLast())
        case "M":
            multiplier = 1_000_000
            numericPart = String(trimmedValue.dropLast())
        case "B":
            multiplier = 1_000_000_000
            numericPart = String(trimmedValue.dropLast())
        default:
            multiplier = 1
            numericPart = trimmedValue
        }

        let cleanedNumericPart = numericPart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedNumericPart.isEmpty else { return nil }

        let normalizedNumber = cleanedNumericPart.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalizedNumber) else { return nil }
        return value * multiplier
    }

    private static func detectMetric(in rawValue: String) -> AudienceMetric? {
        if rawValue.hasSuffix(" monthly audience") || rawValue.hasSuffix(" monthly listeners") {
            return .monthlyAudience
        }

        if rawValue.hasSuffix(" subscribers") || rawValue.hasSuffix(" subscriber") {
            return .subscriberCount
        }

        return nil
    }

    private static func trimEnglishAudienceDescriptors(from rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: " subscribers", with: "")
            .replacingOccurrences(of: " subscriber", with: "")
            .replacingOccurrences(of: " monthly audience", with: "")
            .replacingOccurrences(of: " monthly listeners", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
