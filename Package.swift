// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "trapps",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "trapps"),
        .testTarget(name: "trappsTests", dependencies: ["trapps"])
    ]
)
