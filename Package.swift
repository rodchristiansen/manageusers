// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SharedDeviceManageUsers",
    platforms: [
        .macOS(.v12) // Requires macOS 12 or later for modern system APIs
    ],
    products: [
        .executable(
            name: "manageusers",
            targets: ["manageusers"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "manageusers",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources"
        ),
    ]
)