// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Liuyu",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/JakubMazur/lucide-icons-swift.git", from: "0.563.1")
    ],
    targets: [
        // Library target with all app logic (testable)
        .target(
            name: "LiuyuLib",
            dependencies: [
                .product(name: "LucideIcons", package: "lucide-icons-swift")
            ],
            path: "Sources/LiuyuLib",
            // Resources excluded from SPM (Info.plist forbidden as SPM resource);
            // copied into .app bundle by scripts/bundle.sh instead
            exclude: ["Resources"]
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
        )
    ]
)
