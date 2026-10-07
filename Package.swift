// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChromeSTT",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .executableTarget(
            name: "ChromeSTT",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
            path: "ChromeSTT",
            exclude: ["Resources"]
        ),
    ]
)
