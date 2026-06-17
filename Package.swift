// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "Tabby",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Tabby", targets: ["Tabby"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Tabby",
            dependencies: [],
            path: "Sources/Tabby"
        )
    ]
)
