// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Buddy",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "BuddyKit", targets: ["BuddyKit"]),
        .executable(name: "buddy-hook", targets: ["BuddyHook"]),
        .executable(name: "buddyctl", targets: ["BuddyCtl"]),
    ],
    targets: [
        .target(name: "BuddyKit"),
        .executableTarget(name: "BuddyHook", dependencies: ["BuddyKit"]),
        .executableTarget(name: "BuddyCtl", dependencies: ["BuddyKit"]),
        .testTarget(name: "BuddyKitTests", dependencies: ["BuddyKit"]),
    ]
)
