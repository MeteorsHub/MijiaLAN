// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MijiaLAN",
    platforms: [
        // hap-swift needs macOS 15.
        .macOS(.v15)
    ],
    products: [
        .library(name: "MijiaLAN", targets: ["MijiaLAN"]),
        .library(name: "MijiaHomeKitBridge", targets: ["MijiaHomeKitBridge"]),
        .executable(name: "MijiaLANApp", targets: ["MijiaLANApp"]),
        .executable(name: "mijia-lan", targets: ["mijia-lan"])
    ],
    dependencies: [
        // MIoT spec parsing, device synthesis, command mapping, the one-time QR login and `HomeStore`
        // (optimistic updates, rollback). Pinned to the 1.1.4 release commit.
        .package(url: "https://github.com/jryang1997/MenuBarMijia.git", revision: "c6a9db1c84fa30125ed4b642b6745487dec94e89"),
        // HomeKit Accessory Protocol server: acumen-dev/hap-swift at 638001b plus one fix, see Vendor/hap-swift/README.md.
        .package(path: "Vendor/hap-swift"),
        // hap-swift's logging API; the app sends it to the unified log.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        // miIO LAN protocol (UDP 54321), discovery, the device registry and a `MiCloudAPI` that never leaves the LAN.
        .target(
            name: "MijiaLAN",
            dependencies: [.product(name: "MijiaCore", package: "MenuBarMijia")],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MijiaHomeKitBridge",
            dependencies: [
                "MijiaLAN",
                .product(name: "MijiaCore", package: "MenuBarMijia"),
                .product(name: "HAPSwift", package: "hap-swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MijiaLANApp",
            dependencies: [
                "MijiaLAN",
                "MijiaHomeKitBridge",
                .product(name: "MijiaCore", package: "MenuBarMijia"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Command-line probe for the LAN layer: discover, info, props, set.
        .executableTarget(
            name: "mijia-lan",
            dependencies: [
                "MijiaLAN",
                "MijiaHomeKitBridge",
                .product(name: "MijiaCore", package: "MenuBarMijia")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MijiaMatterRPCTests",
            dependencies: ["mijia-lan", "MijiaLAN", .product(name: "MijiaCore", package: "MenuBarMijia")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MijiaLANAppTests",
            dependencies: ["MijiaLANApp"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MijiaLANTests",
            dependencies: [
                "MijiaLAN",
                .product(name: "MijiaCore", package: "MenuBarMijia")
            ],
            resources: [.process("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MijiaHomeKitBridgeTests",
            dependencies: [
                "MijiaHomeKitBridge",
                .product(name: "MijiaCore", package: "MenuBarMijia"),
                .product(name: "HAPSwift", package: "hap-swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
