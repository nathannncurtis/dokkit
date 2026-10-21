// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DokkitKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DokkitKit", targets: ["DokkitKit"]),
        .library(name: "DokkitUI", targets: ["DokkitUI"]),
    ],
    targets: [
        .target(name: "DokkitKit"),
        .target(name: "DokkitUI", dependencies: ["DokkitKit"], resources: [.process("Resources")]),
        .executableTarget(name: "DokkitChecks", dependencies: ["DokkitKit"], path: "Tests/DokkitChecks", resources: [.copy("Fixtures")]),
    ]
)
