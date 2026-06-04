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
        ),
        .testTarget(
            name: "NotchiTests",
            dependencies: ["Notchi"],
            path: "Tests/NotchiTests"
        )
    ]
)
