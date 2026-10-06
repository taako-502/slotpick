// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SlotPick",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SlotPickCore", targets: ["SlotPickCore"]),
        .library(name: "SlotPickSupport", targets: ["SlotPickSupport"])
    ],
    targets: [
        .target(name: "SlotPickCore"),
        .target(name: "SlotPickSupport", dependencies: ["SlotPickCore"]),
        .testTarget(name: "SlotPickCoreTests", dependencies: ["SlotPickCore"]),
        .testTarget(name: "SlotPickSupportTests", dependencies: ["SlotPickSupport", "SlotPickCore"])
    ]
)
