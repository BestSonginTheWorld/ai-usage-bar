// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsageMenuBar",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "AIUsageMenuBarApp", targets: ["AIUsageMenuBarApp"]),
    ],
    targets: [
        .executableTarget(
            name: "AIUsageMenuBarApp",
            path: "Sources/AIUsageMenuBarApp"
        ),
    ]
)
