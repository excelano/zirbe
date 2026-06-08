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
        .macOS(.v13),
    ],
    products: [
        .library(name: "ZirbeCore", targets: ["ZirbeCore"]),
    ],
    dependencies: [
        .package(path: "../ZirbeMail"),
    ],
    targets: [
        .target(
            name: "ZirbeCore",
            dependencies: [
                .product(name: "ZirbeMail", package: "ZirbeMail"),
            ]
        ),
        .testTarget(
            name: "ZirbeCoreTests",
            dependencies: ["ZirbeCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
