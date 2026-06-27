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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Tabby",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Tabby"
        )
    ]
)
