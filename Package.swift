// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Markit",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "Markit", targets: ["MarkItApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.2")
    ],
    targets: [
        .executableTarget(
            name: "MarkItApp",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ]
        )
    ]
)
