// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Markit",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "Markit", targets: ["MarkItApp"])
    ],
    dependencies: [
    ],
    targets: [
        .executableTarget(
            name: "MarkItApp",
            dependencies: [
            ],
            path: ".",
            exclude: [
                "project.yml",
                "Markit.xcodeproj",
                "Resources/Info.plist",
                "Resources/playstore.png",
                "Resources/appstore.png",
            ],
            sources: [
                "Sources/MarkItApp"
            ],
            resources: [
                .copy("Resources/Styles"),
                .process("Resources/AppIcon.xcassets")
            ]
        )
    ]
)
