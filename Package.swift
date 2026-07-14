// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "OctriMonitoring",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        .library(name: "OctriMonitoring", targets: ["OctriMonitoring"]),
    ],
    targets: [
        .target(name: "OctriMonitoring"),
        .testTarget(name: "OctriMonitoringTests", dependencies: ["OctriMonitoring"]),
    ]
)
