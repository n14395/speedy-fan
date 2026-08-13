// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpeedyFan",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "SMCCore"),
        .executableTarget(name: "fanctl", dependencies: ["SMCCore"]),
        .executableTarget(name: "SpeedyFan", dependencies: ["SMCCore"]),
        .testTarget(name: "SMCCoreTests", dependencies: ["SMCCore"]),
        .testTarget(name: "SpeedyFanTests", dependencies: ["SpeedyFan"]),
        .testTarget(name: "FanctlTests", dependencies: ["fanctl", "SMCCore"]),
    ]
)
