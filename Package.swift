// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QwertySwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "QwertySwitcher",
            path: "Sources/QwertySwitcher",
            resources: [
                .copy("../../Resources/Dictionaries"),
                .copy("../../Resources/Fonts"),
                .copy("../../Resources/PrivacyInfo.xcprivacy"),
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
