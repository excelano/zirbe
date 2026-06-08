// swift-tools-version:6.0
import PackageDescription

// SwiftIMAP is a standalone, high-level async IMAP client built on Apple's
// low-level swift-nio-imap. It has no dependency on Zirbe and is designed to be
// extracted into its own repository if anyone wants just the IMAP client.
let package = Package(
    name: "SwiftIMAP",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SwiftIMAP", targets: ["SwiftIMAP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-imap", from: "0.2.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.64.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.24.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.4.4"),
    ],
    targets: [
        .target(
            name: "SwiftIMAP",
            dependencies: [
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // macOS-only example client. Exercises SwiftIMAP against a real
        // account using IMAP_* environment variables; not part of any app.
        .executableTarget(
            name: "imap-demo",
            dependencies: ["SwiftIMAP"]
        ),
        .testTarget(
            name: "SwiftIMAPTests",
            dependencies: ["SwiftIMAP"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
