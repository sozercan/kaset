import Foundation
import Testing

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
            if catalogEntries.isEmpty, language != sourceLanguage {
                problems.append("\(language): ships an .lproj but has no localizations in the catalog")
                continue
            }
            for (key, expected) in catalogEntries.sorted(by: { $0.key < $1.key }) {
                guard let actual = shippedStrings[key] else {
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

    static var resourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Kaset/Resources")
    }

    static func sourceLanguage(at url: URL) throws -> String {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return (raw as? [String: Any])?["sourceLanguage"] as? String ?? "en"
    }

    static func catalogKeys(at url: URL) throws -> Set<String> {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let strings = (raw as? [String: Any])?["strings"] as? [String: Any] else {
            return []
        }
        return Set(strings.keys)
    }

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

    static func loadStrings(at url: URL) throws -> [String: String] {
        let parsed = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: url),
            options: [],
            format: nil
        )
        return parsed as? [String: String] ?? [:]
    }
}
