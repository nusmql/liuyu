// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Liuyu",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/JakubMazur/lucide-icons-swift.git", from: "0.563.1")
    ],
    targets: [
        .executableTarget(
            name: "Liuyu",
            dependencies: [
                .product(name: "LucideIcons", package: "lucide-icons-swift")
            ],
            path: "Sources/Liuyu",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "LiuyuTests",
            dependencies: ["Liuyu"],
            path: "Tests/LiuyuTests"
        )
    ]
)
