// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Liuyu",
    platforms: [.macOS(.v13)],
    dependencies: [
    ],
    targets: [
        .target(
            name: "LiuyuVoice",
            dependencies: [],
            path: "Sources/LiuyuVoice"
        ),
        // Library target with all app logic (testable)
        .target(
            name: "LiuyuLib",
            dependencies: [
                "LiuyuVoice"
            ],
            path: "Sources/LiuyuLib",
            // Resources: explicitly process images, exclude build/metadata files
            exclude: [
                "Resources/Info.plist", 
                "Resources/AppIcon.icns", 
                "Resources/Liuyu.entitlements"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        // Executable target with just the entry point
        .executableTarget(
            name: "Liuyu",
            dependencies: ["LiuyuLib"],
            path: "Sources/Liuyu"
        ),
        .testTarget(
            name: "LiuyuTests",
            dependencies: ["LiuyuLib"],
            path: "Tests/LiuyuTests"
        ),
        .testTarget(
            name: "LiuyuVoiceTests",
            dependencies: ["LiuyuVoice"],
            path: "Tests/LiuyuVoiceTests"
        )
    ]
)
