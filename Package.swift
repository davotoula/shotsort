// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "shotsort",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "ShotsortCore"),
        .executableTarget(name: "shotsort", dependencies: ["ShotsortCore"]),
        .testTarget(name: "ShotsortCoreTests", dependencies: ["ShotsortCore"]),
    ]
)
