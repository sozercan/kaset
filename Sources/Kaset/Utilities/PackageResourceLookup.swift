import AppKit
import SwiftUI

enum PackageResourceLookup {
    private static let resourceBundleName = "Kaset_Kaset.bundle"
    private static let accentColorName = NSColor.Name("AccentColor")

    static let brandAccent: Color = {
        if let color = NSColor(named: accentColorName, bundle: Bundle.main) {
            return Color(nsColor: color)
        }

        for bundle in candidateBundles {
            if let color = NSColor(named: accentColorName, bundle: bundle) {
                return Color(nsColor: color)
            }
        }

        return Color(red: 1.0, green: 0.0, blue: 0.337)
    }()

    private static let candidateBundles: [Bundle] = {
        var bundles: [Bundle] = []
        var seenPaths = Set<String>()

        let candidateURLs = [
            Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(resourceBundleName),
        ]

        for url in candidateURLs.compactMap(\.self) {
            guard seenPaths.insert(url.path).inserted else { continue }
            guard let bundle = Bundle(url: url) else { continue }
            bundles.append(bundle)
        }

        return bundles
    }()
}
