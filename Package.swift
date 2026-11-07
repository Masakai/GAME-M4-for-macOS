// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GAME-M4",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GameCore", targets: ["GameCore"]),
        .library(name: "GameCompiler", targets: ["GameCompiler"]),
        .executable(name: "gamem4", targets: ["gamem4"]),
        .executable(name: "GameM4App", targets: ["GameM4App"]),
    ],
    targets: [
        .target(name: "GameCore"),
        .target(
            name: "GameCompiler",
            dependencies: ["GameCore"],
            exclude: ["Runtime"]
        ),
        .executableTarget(name: "gamem4", dependencies: ["GameCore", "GameCompiler"]),
        .executableTarget(name: "GameM4App", dependencies: ["GameCore", "GameCompiler"]),
        .testTarget(name: "GameCoreTests", dependencies: ["GameCore"]),
        .testTarget(
            name: "GameCompilerTests",
            dependencies: ["GameCore", "GameCompiler"],
            exclude: ["Programs"]
        ),
    ]
)
