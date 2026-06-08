// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ZirbeMail",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ZirbeMail", targets: ["ZirbeMail"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-imap", from: "0.2.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.64.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", from: "2.24.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.4.4"),
    ],
    targets: [
        .target(
            name: "ZirbeMail",
            dependencies: [
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // macOS-only command-line harness for the M1 spike. Not part of the
        // shipped app; it exists to exercise ZirbeMail against a real account.
        .executableTarget(
            name: "imap-spike",
            dependencies: ["ZirbeMail"]
        ),
    ],
    // Swift 5 language mode for the spike; the app can adopt full Swift 6
    // strict-concurrency later once the engine shape is settled.
    swiftLanguageModes: [.v5]
)
