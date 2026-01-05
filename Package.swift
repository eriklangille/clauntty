// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clauntty",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)  // For running tests on macOS
    ],
    products: [
        .library(
            name: "ClaunttyCore",
            targets: ["ClaunttyCore"]
        ),
    ],
    dependencies: [
        // Apple's official SSH implementation
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        // Required NIO dependencies
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.62.0"),
        // Local rtach client package
        .package(path: "RtachClient"),
        // On-device speech-to-text (Parakeet model)
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
    ],
    targets: [
        .target(
            name: "ClaunttyCore",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                "RtachClient",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Clauntty/Core"
        ),
        .testTarget(
            name: "ClaunttyTests",
            dependencies: ["ClaunttyCore"],
            path: "Tests/ClaunttyTests"
        ),
    ]
)
