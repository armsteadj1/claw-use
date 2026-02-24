// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClawUse",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMinor(from: "1.2.0")),
    ],
    targets: [
        // C shim for kevent() syscall (Swift 6 can't disambiguate from kevent struct)
        .target(
            name: "CKeventShim",
            path: "Sources/CKeventShim",
            publicHeadersPath: "include"
        ),
        // Shared business logic library
        .target(
            name: "CUACore",
            dependencies: ["CKeventShim"],
            path: "Sources/CUACore",
            swiftSettings: []
        ),
        // CLI thin client
        .executableTarget(
            name: "cua",
            dependencies: [
                "CUACore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CUA",
            swiftSettings: []
        ),
        // Testable library with the remote HTTP server (and its log helper)
        .target(
            name: "CUADaemonLib",
            dependencies: ["CUACore"],
            path: "Sources/CUADaemonLib",
            swiftSettings: []
        ),
        // Daemon
        .executableTarget(
            name: "cuad",
            dependencies: [
                "CUACore",
                "CUADaemonLib",
            ],
            path: "Sources/CUADaemon",
            swiftSettings: []
        ),
        .testTarget(
            name: "CUATests",
            dependencies: ["CUACore", "CUADaemonLib"],
            path: "Tests/CUATests",
            swiftSettings: []
        ),
    ]
)
