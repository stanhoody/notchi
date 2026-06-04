// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Notchi",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "notchi", targets: ["Notchi"])
    ],
    targets: [
        .executableTarget(
            name: "Notchi",
            path: "Sources/Notchi",
            resources: [
                .process("Resources")
            ]
        )
        // Tests run via `notchi --selftest` (no Xcode/XCTest on the build box).
    ]
)
