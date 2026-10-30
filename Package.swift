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
        // HomeKit Accessory Protocol server. Pinned to main: the 1.0.4 tag predates event notifications,
        // explicit accessory IDs and the dashed SRP setup code that real iPhones need.
        .package(url: "https://github.com/acumen-dev/hap-swift.git", revision: "638001bd3590082a8909fd4046ec226ab1349f20")
    ],
    targets: [
        // miIO LAN protocol (UDP 54321), discovery, the device registry and a `MiCloudAPI` that never leaves the LAN.
        .target(
            name: "MijiaLAN",
            dependencies: [.product(name: "MijiaCore", package: "MenuBarMijia")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MijiaHomeKitBridge",
            dependencies: [
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
                .product(name: "MijiaCore", package: "MenuBarMijia")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Command-line probe for the LAN layer: discover, info, props, set.
        .executableTarget(
            name: "mijia-lan",
            dependencies: [
                "MijiaLAN",
                .product(name: "MijiaCore", package: "MenuBarMijia")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MijiaLANTests",
            dependencies: [
                "MijiaLAN",
                .product(name: "MijiaCore", package: "MenuBarMijia")
            ],
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
