import Foundation
import Testing

/// Packaged builds compile `Localizable.xcstrings` directly, while SwiftPM and
/// Xcode runtime builds ship the checked-in `.lproj` mirrors. An edit that only
/// reaches one side is therefore visible in one build path but stale or missing
/// in the other, so the two have to be checked against each other.
@Suite("Localization catalog parity")
struct LocalizationCatalogParityTests {
    @Test("Every .lproj value matches the string catalog")
    func lprojMatchesCatalog() throws {
        let resources = Self.resourcesDirectory
        let catalogURL = resources.appendingPathComponent("Localizable.xcstrings")
        let catalog = try Self.loadCatalog(at: catalogURL)
        let catalogKeys = try Self.catalogKeys(at: catalogURL)
        let sourceLanguage = try Self.sourceLanguage(at: catalogURL)

        let localizationDirectories = try FileManager.default
            .contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        #expect(!localizationDirectories.isEmpty)

        var problems: [String] = []

        // A language the catalog translates but the target never ships is the
        // same drift, one level up.
        let shipped = Set(localizationDirectories.map { $0.deletingPathExtension().lastPathComponent })
        for language in catalog.keys.sorted() where !shipped.contains(language) {
            problems.append("\(language): translated in the catalog but has no .lproj directory")
        }

        for directory in localizationDirectories {
            let language = directory.deletingPathExtension().lastPathComponent
            let stringsURL = directory.appendingPathComponent("Localizable.strings")
            guard FileManager.default.fileExists(atPath: stringsURL.path) else {
                problems.append("\(language): \(directory.lastPathComponent) has no Localizable.strings")
                continue
            }

            let shippedStrings = try Self.loadStrings(at: stringsURL)
            let catalogEntries = catalog[language] ?? [:]
            // A shipped language the catalog no longer translates would ship
            // stale strings forever, and comparing an empty dictionary would
            // silently pass.
            if catalogEntries.isEmpty, language != sourceLanguage {
                problems.append("\(language): ships an .lproj but has no localizations in the catalog")
                continue
            }
            for (key, expected) in catalogEntries.sorted(by: { $0.key < $1.key }) {
                guard let actual = shippedStrings[key] else {
                    // The source language needs no entry: the key is the value.
                    if language != sourceLanguage {
                        problems.append("\(language): \"\(key)\" is in the catalog but missing from .lproj")
                    }
                    continue
                }
                if actual != expected {
                    problems.append(
                        "\(language): \"\(key)\"\n  .lproj:  \"\(actual)\"\n  catalog: \"\(expected)\""
                    )
                }
            }

            // The other direction: a translated key dropped from this locale
            // but left in its .strings file would silently ship a stale value.
            // The source locale may intentionally override a subset of catalog
            // keys because untranslated source keys are their own values.
            let expectedShippedKeys = language == sourceLanguage
                ? catalogKeys
                : Set(catalogEntries.keys)
            for key in shippedStrings.keys.sorted() where !expectedShippedKeys.contains(key) {
                if language == sourceLanguage {
                    problems.append("\(language): \"\(key)\" is in .lproj but no longer in the catalog")
                } else {
                    problems.append("\(language): \"\(key)\" is in .lproj but missing from that catalog locale")
                }
            }
        }

        #expect(
            problems.isEmpty,
            """
            \(problems.count) localization(s) drifted from Localizable.xcstrings. \
            Regenerate the affected .strings entries from the catalog:
            \(problems.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Helpers

    /// `Sources/Kaset/Resources`, resolved from this file rather than a bundle:
    /// the catalog is deliberately excluded from the target's resources.
    static var resourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KasetTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/Kaset/Resources")
    }

    /// The catalog's source language, whose `.strings` needs no entry per key
    /// because the key itself is the value.
    static func sourceLanguage(at url: URL) throws -> String {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return (raw as? [String: Any])?["sourceLanguage"] as? String ?? "en"
    }

    /// Every key the catalog defines, regardless of which languages translate
    /// it. Used to spot `.strings` entries the catalog has dropped.
    static func catalogKeys(at url: URL) throws -> Set<String> {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let strings = (raw as? [String: Any])?["strings"] as? [String: Any] else {
            return []
        }
        return Set(strings.keys)
    }

    /// `[language: [key: value]]` from the string catalog.
    static func loadCatalog(at url: URL) throws -> [String: [String: String]] {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let root = raw as? [String: Any],
              let strings = root["strings"] as? [String: Any]
        else {
            return [:]
        }

        var catalog: [String: [String: String]] = [:]
        for (key, entry) in strings {
            guard let entry = entry as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any]
            else { continue }
            for (language, localization) in localizations {
                guard let localization = localization as? [String: Any],
                      let unit = localization["stringUnit"] as? [String: Any],
                      let value = unit["value"] as? String
                else { continue }
                catalog[language, default: [:]][key] = value
            }
        }
        return catalog
    }

    /// Parses a text-format `.strings` file (old-style property list).
    static func loadStrings(at url: URL) throws -> [String: String] {
        let parsed = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            options: [],
            format: nil
        )
        return parsed as? [String: String] ?? [:]
    }
}
