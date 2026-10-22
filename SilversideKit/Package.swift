// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SilversideKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SilversideKit", targets: ["SilversideKit"]),
        .library(name: "SilversideDarwin", targets: ["SilversideDarwin"]),
        .executable(name: "silverside", targets: ["silverside"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2")
    ],
    targets: [
        .target(name: "SilversideKit"),
        .target(name: "SilversideDarwin", dependencies: ["SilversideKit"]),
        .executableTarget(
            name: "silverside",
            dependencies: [
                "SilversideKit",
                "SilversideDarwin",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(name: "SilversideKitTests", dependencies: ["SilversideKit"], resources: [.copy("Resources")]),
        .testTarget(name: "SilversideDarwinTests", dependencies: ["SilversideDarwin"]),
    ]
)
