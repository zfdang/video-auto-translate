// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VideoAutoTranslate",
    defaultLocalization: "zh-CN",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "VideoAutoTranslateCore",
            targets: ["VideoAutoTranslateCore"]
        ),
        .executable(
            name: "VideoAutoTranslateApp",
            targets: ["VideoAutoTranslateApp"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VideoAutoTranslateCore",
            dependencies: [],
            path: "Sources/VideoAutoTranslateCore"
        ),
        .executableTarget(
            name: "VideoAutoTranslateApp",
            dependencies: ["VideoAutoTranslateCore"],
            path: "Sources/VideoAutoTranslateApp"
        ),
        .testTarget(
            name: "VideoAutoTranslateCoreTests",
            dependencies: ["VideoAutoTranslateCore", "VideoAutoTranslateApp"],
            path: "Tests/VideoAutoTranslateCoreTests"
        )
    ]
)
