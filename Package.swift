// swift-tools-version: 6.2

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
        .executableTarget(
            name: "Kaset",
            dependencies: [
                "YouTubeAskCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            exclude: [
                "Resources/AppIcon.icon",
                "Resources/kaset.icns",
                "Resources/Localizable.xcstrings",
                "Resources/AppShortcuts.xcstrings",
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
                .process("Resources/ja.lproj"),
                .process("Resources/ko.lproj"),
                .process("Resources/nl.lproj"),
                .process("Resources/pl.lproj"),
                .process("Resources/pt.lproj"),
                .process("Resources/ru.lproj"),
                .process("Resources/sv.lproj"),
                .process("Resources/tr.lproj"),
                .process("Resources/uk.lproj"),
                .process("Resources/zh-Hans.lproj"),
                .process("Resources/zh-Hant.lproj"),
                .process("Resources/Kaset.sdef"),
                .copy("Extensions"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "APIExplorer",
            dependencies: ["YouTubeAskCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "APIExplorerTests",
            dependencies: ["APIExplorer"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "YouTubeAskCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "YouTubeAskCoreTests",
            dependencies: ["YouTubeAskCore"],
            resources: [
                .process("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "KasetTests",
            dependencies: ["Kaset"],
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
