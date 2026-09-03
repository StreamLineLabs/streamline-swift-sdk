// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StreamlineSDK",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "StreamlineSDK", targets: ["StreamlineSDK"]),
    ],
    dependencies: [
        // StreamlineVerifier conditionally imports CryptoKit when available
        // and Crypto otherwise. Keeping the Crypto product available to every
        // target also lets Swift 5.9 parse this manifest without relying on
        // newer PackageDescription platform-condition cases.
        //
        // This package has no committed Package.resolved, so use the exact
        // swift-crypto release exercised by the Linux build/test matrix.
        //
        // Every workflow that builds this package (ci.yml, integration.yml,
        // codeql.yml, release.yml) pins its Linux Swift toolchain to 6.1 —
        // not because of this range specifically, but because it is the
        // minimum version whose swift-corelibs-foundation ships a complete
        // `URLSession.data(for:)` and `URLSessionWebSocketTask` completion-
        // handler surface; StreamlineClient/AdminClient fail to compile on
        // Linux below it regardless of swift-crypto. Confirmed directly by
        // building this package under swift:5.9/5.10/6.0/6.1-jammy: only 6.1
        // succeeds. 6.1 also comfortably parses every manifest this range
        // can resolve to (swift-tools-version 5.9 through 6.1 across
        // 3.9.0...4.5.x), so the two constraints don't fight each other.
        // Widening the upper bound past 5.0.0 requires re-reviewing both
        // constraints together, not just bumping this line.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        .target(
            name: "StreamlineSDK",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/StreamlineSDK"
        ),
        .testTarget(
            name: "StreamlineSDKTests",
            dependencies: [
                "StreamlineSDK",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tests"
        ),
    ]
)
