// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Kaset",
    defaultLocalization: "en",
    platforms: [
        .macOS("15.4"),
    ],
    products: [
        .executable(
            name: "Kaset",
            targets: ["Kaset"]
        ),
        .executable(
            name: "api-explorer",
            targets: ["APIExplorer"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.1"),
    ],
    targets: [
        // Main app executable
        .executableTarget(
            name: "Kaset",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            exclude: [
                "Resources/AppIcon.icon",
                "Resources/kaset.icns",
                // The checked-in .lproj files are the SwiftPM/Xcode 26 runtime
                // resources. build-app.sh compiles the source catalog for the
                // packaged app to avoid duplicate .strings outputs in SwiftPM.
                "Resources/Localizable.xcstrings",
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/ar.lproj"),
                .process("Resources/de.lproj"),
                .process("Resources/en.lproj"),
                .process("Resources/es.lproj"),
                .process("Resources/fr.lproj"),
                .process("Resources/id.lproj"),
                .process("Resources/it.lproj"),
                .process("Resources/ko.lproj"),
                .process("Resources/nl.lproj"),
                .process("Resources/pl.lproj"),
                .process("Resources/pt.lproj"),
                .process("Resources/ru.lproj"),
                .process("Resources/sv.lproj"),
                .process("Resources/tr.lproj"),
                .process("Resources/uk.lproj"),
                .process("Resources/Kaset.sdef"),
                .copy("Extensions"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        // API Explorer CLI tool
        .executableTarget(
            name: "APIExplorer",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Unit tests
        .testTarget(
            name: "KasetTests",
            dependencies: ["Kaset"],
            // Tests for Apple-Intelligence-powered features are excluded
            // because the underlying APIs are macOS 26+ only and Swift
            // Testing's `@Test` / `@Suite` macros do not compose with
            // `@available(macOS 26, *)`.
            exclude: [
                "AIErrorHandlerTests.swift",
                "AIToolTests.swift",
                "CommandBarViewModelTests.swift",
                "CommandExecutorTests.swift",
                "CommandIntentParserTests.swift",
                "FoundationModelsOptimizedPromptIntegrationTests.swift",
                "FoundationModelsPromptLibraryTests.swift",
                "FoundationModelsServiceTests.swift",
                "FoundationModelsTests.swift",
                "MusicIntentIntegrationTests.swift",
                "MusicIntentTests.swift",
            ],
            resources: [
                .process("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
