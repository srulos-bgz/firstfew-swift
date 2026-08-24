// swift-tools-version:5.9
// FirstFew analytics SDK (iOS 14+): one configure() call handles app_launch,
// reinstall detection, device context, and ASA attribution reporting automatically;
// business events are one FirstFew.track() line each.
// Publishing: SPM requires the package at the repository root — push this directory
// to its own public repository when releasing.
import PackageDescription

let package = Package(
    name: "FirstFew",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "FirstFew", targets: ["FirstFew"])
    ],
    targets: [
        .target(
            name: "FirstFew",
            path: "Sources/FirstFew",
            resources: [.process("PrivacyInfo.xcprivacy")]
        )
    ]
)
