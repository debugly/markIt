// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Markit",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "Markit", targets: ["MarkItApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/johnxnguyen/Down.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "MarkItApp",
            dependencies: [
                .product(name: "Down", package: "Down")
            ]
        )
    ]
)
