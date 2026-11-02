// swift-tools-version: 6.1
// Modified for MijiaLAN; see Vendor/hap-swift/README.md for the changes.
import PackageDescription

let package = Package(
    name: "hap-swift",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        // HAP types, TLV8, constants, service types — zero platform dependencies
        .library(name: "HAPCore", targets: ["HAPCore"]),
        // SRP-6a, Curve25519, ChaCha20-Poly1305, HKDF
        .library(name: "HAPCrypto", targets: ["HAPCrypto"]),
        // TCP server, pairing state machine, characteristic protocol
        .library(name: "HAPTransport", targets: ["HAPTransport"]),
        // Apple platform transport (Network.framework + MDNSApple)
        .library(name: "HAPApple", targets: ["HAPApple"]),
        // Linux platform transport (SwiftNIO + MDNSLinux)
        .library(name: "HAPLinux", targets: ["HAPLinux"]),
        // Convenience umbrella
        .library(name: "HAPSwift", targets: ["HAPSwift"]),
    ],
    dependencies: [
        .package(url: "https://github.com/acumen-dev/mdns-swift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [

        // MARK: - HAPCore

        .target(
            name: "HAPCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - HAPCrypto

        .target(
            name: "HAPCrypto",
            dependencies: [
                "HAPCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),

        // MARK: - HAPTransport

        .target(
            name: "HAPTransport",
            dependencies: [
                "HAPCore",
                "HAPCrypto",
                .product(name: "MDNSCore", package: "mdns-swift"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - HAPApple

        .target(
            name: "HAPApple",
            dependencies: [
                "HAPTransport",
                .product(name: "MDNSApple", package: "mdns-swift"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - HAPLinux

        .target(
            name: "HAPLinux",
            dependencies: [
                "HAPTransport",
                .product(name: "MDNSLinux", package: "mdns-swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // MARK: - HAPSwift (umbrella)

        .target(
            name: "HAPSwift",
            dependencies: [
                "HAPCore",
                "HAPCrypto",
                "HAPTransport",
                .target(name: "HAPApple",
                        condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])),
                .target(name: "HAPLinux",
                        condition: .when(platforms: [.linux])),
            ]
        ),
    ]
)
