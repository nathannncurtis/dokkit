// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "Dokkit",
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [.library(name: "Dokkit", targets: ["Dokkit"])],
    targets: [
        .target(name: "Dokkit", path: ".", sources: ["Dokkit.swift"]),
        .testTarget(name: "DokkitTests", dependencies: ["Dokkit"], path: "Tests/DokkitTests"),
    ]
)
