// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Kaset",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(
            name: "Kaset",
            targets: ["Kaset"]),
        .executable(
            name: "api-explorer",
            targets: ["APIExplorer"]),
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
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("StrictConcurrency"),
            ]),
        // API Explorer CLI tool
        .executableTarget(
            name: "APIExplorer",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]),
        // Unit tests
        .testTarget(
            name: "KasetTests",
            dependencies: ["Kaset"],
            resources: [
                .process("Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]),
        // UI tests (run via xcodebuild, not swift test)
        .testTarget(
            name: "KasetUITests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]),
    ],
    swiftLanguageModes: [.v6])
