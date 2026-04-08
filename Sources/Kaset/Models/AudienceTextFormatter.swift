import Foundation

enum AudienceTextFormatter {
    private struct CompactCountComponents {
        let value: Double
        let rawFractionDigits: Int
        let magnitude: Magnitude
    }

    private enum Magnitude: CaseIterable {
        case none
        case thousand
        case million
        case billion

        var multiplier: Double {
            switch self {
            case .none: 1
            case .thousand: 1000
            case .million: 1_000_000
            case .billion: 1_000_000_000
            }
        }

        var westernSuffixKey: String? {
            switch self {
            case .none: nil
            case .thousand: "Compact suffix thousand"
            case .million: "Compact suffix million"
            case .billion: "Compact suffix billion"
            }
        }
    }

    private enum NotationSystem {
        case western
        case eastAsianTenThousands
    }

    private struct LocaleProfile {
        let locale: Locale
        let bundle: Bundle
        let notationSystem: NotationSystem
    }

    private struct EastAsianUnit {
        let divisor: Double
        let key: String
    }

    private static let notationSystemOverrides: [String: NotationSystem] = [
        "ko": .eastAsianTenThousands,
    ]

    private static let eastAsianUnits: [EastAsianUnit] = [
        EastAsianUnit(divisor: 100_000_000, key: "Compact suffix hundred-million"),
        EastAsianUnit(divisor: 10000, key: "Compact suffix ten-thousand"),
    ]

    static func formatMonthlyAudience(_ rawValue: String, languageCode: String) -> String? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        let profile = self.localeProfile(for: languageCode)
        let formattedCount = if let components = self.parseCompactCount(trimmedValue) {
            self.formatCount(components, profile: profile)
        } else {
            trimmedValue
        }

        let format = self.localizedString("Monthly audience: %@", profile: profile)
        return String(format: format, formattedCount)
    }

    static func formatSubscriberCount(_ rawValue: String, languageCode: String) -> String {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return trimmedValue }

        let profile = self.localeProfile(for: languageCode)
        if let components = self.parseCompactCount(trimmedValue) {
            return self.formatCount(components, profile: profile)
        }

        return self.trimEnglishAudienceDescriptors(from: trimmedValue)
    }

    static func formatAudienceOrSubscriber(_ rawValue: String, languageCode: String) -> String? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        for suffix in [" monthly audience", " monthly listeners"] where trimmedValue.hasSuffix(suffix) {
            let compactCount = String(trimmedValue.dropLast(suffix.count))
            return self.formatMonthlyAudience(compactCount, languageCode: languageCode)
        }

        if trimmedValue.hasSuffix(" subscribers") || trimmedValue.hasSuffix(" subscriber") {
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
        let notationSystem = self.notationSystemOverrides[resolvedLanguageCode] ?? .western
        let bundle = self.localizedBundle(for: resolvedLanguageCode) ?? AppLocalization.baseBundle
        return LocaleProfile(locale: locale, bundle: bundle, notationSystem: notationSystem)
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

    private static func parseCompactCount(_ rawValue: String) -> CompactCountComponents? {
        let trimmedValue = self.trimEnglishAudienceDescriptors(from: rawValue)
        guard !trimmedValue.isEmpty else { return nil }

        let lastCharacter = trimmedValue.last
        let magnitude: Magnitude
        let numericPart: String

        switch lastCharacter {
        case "K":
            magnitude = .thousand
            numericPart = String(trimmedValue.dropLast())
        case "M":
            magnitude = .million
            numericPart = String(trimmedValue.dropLast())
        case "B":
            magnitude = .billion
            numericPart = String(trimmedValue.dropLast())
        default:
            magnitude = .none
            numericPart = trimmedValue
        }

        let cleanedNumericPart = numericPart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedNumericPart.isEmpty else { return nil }

        let normalizedNumber = cleanedNumericPart.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalizedNumber) else { return nil }

        let rawFractionDigits = normalizedNumber.split(separator: ".", maxSplits: 1).dropFirst().first?.count ?? 0
        return CompactCountComponents(value: value, rawFractionDigits: rawFractionDigits, magnitude: magnitude)
    }

    private static func trimEnglishAudienceDescriptors(from rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: " subscribers", with: "")
            .replacingOccurrences(of: " subscriber", with: "")
            .replacingOccurrences(of: " monthly audience", with: "")
            .replacingOccurrences(of: " monthly listeners", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatCount(_ components: CompactCountComponents, profile: LocaleProfile) -> String {
        switch profile.notationSystem {
        case .western:
            self.formatWesternCount(components, profile: profile)
        case .eastAsianTenThousands:
            self.formatEastAsianCount(components, profile: profile)
        }
    }

    private static func formatWesternCount(_ components: CompactCountComponents, profile: LocaleProfile) -> String {
        let numberFormatter = NumberFormatter()
        numberFormatter.locale = Locale(identifier: "en_US_POSIX")
        numberFormatter.numberStyle = .decimal
        numberFormatter.minimumFractionDigits = components.rawFractionDigits
        numberFormatter.maximumFractionDigits = components.rawFractionDigits

        let decimalSeparator = self.localizedString("Compact decimal separator", profile: profile)
        let formattedNumber = (numberFormatter.string(from: NSNumber(value: components.value)) ?? "\(components.value)")
            .replacingOccurrences(of: ".", with: decimalSeparator)
        guard let suffixKey = components.magnitude.westernSuffixKey else {
            return formattedNumber
        }

        let localizedSuffix = self.localizedString(suffixKey, profile: profile)
        return formattedNumber + localizedSuffix
    }

    private static func formatEastAsianCount(_ components: CompactCountComponents, profile: LocaleProfile) -> String {
        let absoluteValue = components.value * components.magnitude.multiplier

        for unit in self.eastAsianUnits where absoluteValue >= unit.divisor {
            let scaledValue = absoluteValue / unit.divisor
            let formattedScaledValue = self.formatScaledEastAsianValue(scaledValue, locale: profile.locale)
            return formattedScaledValue + self.localizedString(unit.key, profile: profile)
        }

        return self.formatWholeNumber(absoluteValue, locale: profile.locale)
    }

    private static func formatScaledEastAsianValue(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func formatWholeNumber(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
    }
}
