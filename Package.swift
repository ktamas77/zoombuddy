// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "ZoomBuddy",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "ZoomBuddy", path: "Sources/ZoomBuddy",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ZoomBuddyTests", dependencies: ["ZoomBuddy"], path: "Tests",
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
