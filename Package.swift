// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "manageusers",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .executable(name: "manageusers", targets: ["manageusers"]),
    ],
    dependencies: [
        // Add external dependencies here if needed
    ],
    targets: [
        .executableTarget(
            name: "manageusers",
            dependencies: []),
    ]
)
