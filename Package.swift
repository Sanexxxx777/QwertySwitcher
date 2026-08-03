// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SashaSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SashaSwitcher",
            path: "Sources/SashaSwitcher",
            resources: [
                .copy("../../Resources/Dictionaries"),
                .copy("../../Resources/Fonts"),
                .copy("../../Resources/PrivacyInfo.xcprivacy"),
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
