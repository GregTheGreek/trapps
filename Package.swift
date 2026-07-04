// swift-tools-version: 5.9
import PackageDescription

// Complete concurrency checking so Sendable/actor-isolation issues surface now
// rather than at the eventual Swift 6 language-mode switch.
let swiftSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency")
]

let package = Package(
    name: "trapps",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "trapps", swiftSettings: swiftSettings),
        .testTarget(name: "trappsTests", dependencies: ["trapps"], swiftSettings: swiftSettings)
    ]
)
