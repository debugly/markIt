// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Markit",
    platforms: [.macOS(.v11)],
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
                "build.sh",
                "bundle_tiptap.sh",
                "clean_bundle.py"
            ],
            sources: [
                "Sources/MarkItApp"
            ],
            resources: [
                .copy("Resources/Styles"),
                .copy("Resources/JS"),
                .process("Resources/AppIcon.xcassets")
            ]
        )
    ]
)
