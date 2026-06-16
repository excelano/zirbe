// swift-tools-version:6.0
import PackageDescription

// ZirbeCore is the offline heart of the app: Zirbe-owned domain models, the
// client-side JWZ threading pass that turns a flat list of messages into
// conversations, and (later) the GRDB store. It depends on ZirbeMail only to
// map MailEnvelope values into domain Messages; the conversation model,
// storage, and UX are all ours.
let package = Package(
    name: "ZirbeCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14), // Observation (the @Observable view model) needs macOS 14.
    ],
    products: [
        .library(name: "ZirbeCore", targets: ["ZirbeCore"]),
    ],
    dependencies: [
        .package(path: "../ZirbeMail"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Klartext owns quote seam detection and trailer synthesis; QuotedText is
        // now the Zirbe-domain adapter over it.
        .package(url: "https://github.com/excelano/klartext", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "ZirbeCore",
            dependencies: [
                .product(name: "ZirbeMail", package: "ZirbeMail"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Klartext", package: "klartext"),
            ]
        ),
        // macOS-only example: fetch a real INBOX, store it, and print the
        // conversations the store produces. Not part of any app.
        .executableTarget(
            name: "sync-demo",
            dependencies: ["ZirbeCore"]
        ),
        .testTarget(
            name: "ZirbeCoreTests",
            dependencies: ["ZirbeCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
