// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CDRipKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CDRipKit", targets: ["CDRipKit"])
    ],
    targets: [
        .target(name: "CDRipKit"),
        .testTarget(name: "CDRipKitTests", dependencies: ["CDRipKit"]),
    ]
)
