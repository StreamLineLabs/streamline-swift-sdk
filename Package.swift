// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StreamlineSDK",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "StreamlineSDK", targets: ["StreamlineSDK"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "StreamlineSDK", path: "Sources/StreamlineSDK"),
        .testTarget(name: "StreamlineSDKTests", dependencies: ["StreamlineSDK"], path: "Tests"),
    ]
)
