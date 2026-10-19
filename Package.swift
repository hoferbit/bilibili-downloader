// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BiliDownloader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BiliDownloader", targets: ["BiliDownloader"]),
        .executable(name: "bilidl", targets: ["bilidl"]),
        .executable(name: "bilibench", targets: ["bilibench"]),
    ],
    targets: [
        .target(name: "BiliCore"),
        .testTarget(name: "BiliCoreTests", dependencies: ["BiliCore"]),
        .executableTarget(name: "BiliDownloader", dependencies: ["BiliCore"]),
        .executableTarget(name: "bilidl", dependencies: ["BiliCore"]),
        .executableTarget(name: "bilibench", dependencies: ["BiliCore"]),
    ],
    swiftLanguageModes: [.v5]
)
