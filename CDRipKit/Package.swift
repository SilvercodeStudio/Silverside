// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CDRipKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CDRipKit", targets: ["CDRipKit"]),
        .library(name: "CDRipDarwin", targets: ["CDRipDarwin"]),
        .executable(name: "cdrip", targets: ["cdrip"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2")
    ],
    targets: [
        .target(name: "CDRipKit"),
        .target(name: "CDRipDarwin", dependencies: ["CDRipKit"]),
        .executableTarget(
            name: "cdrip",
            dependencies: [
                "CDRipKit",
                "CDRipDarwin",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(name: "CDRipKitTests", dependencies: ["CDRipKit"], resources: [.copy("Resources")]),
        .testTarget(name: "CDRipDarwinTests", dependencies: ["CDRipDarwin"]),
    ]
)
