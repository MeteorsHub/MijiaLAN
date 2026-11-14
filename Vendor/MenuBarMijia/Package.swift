// swift-tools-version: 6.0
import PackageDescription

// Local library-only manifest. Sources, resources and tests originate from
// MenuBarMijia c6a9db1c84fa30125ed4b642b6745487dec94e89; see README.md.
let package = Package(
    name: "MenuBarMijia",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MijiaCore", targets: ["MijiaCore"])
    ],
    targets: [
        .target(
            name: "MijiaCore",
            resources: [.copy("Resources/Localizations")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MijiaCoreTests",
            dependencies: ["MijiaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
