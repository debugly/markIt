// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Markit",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "Markit", targets: ["MarkItApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/JohnSundell/Ink.git", from: "0.6.0")
    ],
    targets: [
        .executableTarget(
            name: "MarkItApp",
            dependencies: [
                .product(name: "Ink", package: "Ink")
            ]
        )
    ]
)
