// swift-tools-version:6.0
import PackageDescription

// Managed Users Cleanup: the Prefs / Run / Logs window for manageusers. It stands
// apart from the command-line package; the manageusers tool, its paths and its
// name are unchanged, and the GUI reaches the tool only through the root helper.
let package = Package(
    name: "ManagedUsersCleanup",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ManagedUsersCleanupApp", targets: ["ManagedUsersCleanupApp"]),
        .executable(name: "ManagedUsersCleanupHelper", targets: ["ManagedUsersCleanupHelper"])
    ],
    targets: [
        .target(
            name: "ManagedUsersCleanupXPC",
            path: "Sources/ManagedUsersCleanupXPC"
        ),
        .executableTarget(
            name: "ManagedUsersCleanupApp",
            dependencies: ["ManagedUsersCleanupXPC"],
            path: "Sources/ManagedUsersCleanupApp"
        ),
        .executableTarget(
            name: "ManagedUsersCleanupHelper",
            dependencies: ["ManagedUsersCleanupXPC"],
            path: "Sources/ManagedUsersCleanupHelper"
        ),
        .testTarget(
            name: "ManagedUsersCleanupAppTests",
            dependencies: ["ManagedUsersCleanupApp", "ManagedUsersCleanupXPC"],
            path: "Tests/ManagedUsersCleanupAppTests"
        )
    ]
)
