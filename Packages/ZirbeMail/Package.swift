// swift-tools-version:6.0
import PackageDescription

// ZirbeMail is Zirbe's thin adapter over Cocoanetics/SwiftMail. SwiftMail does
// the IMAP/SMTP work; ZirbeMail exposes only the Zirbe-owned value types the
// rest of the app uses, so the underlying engine stays swappable.
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
        // Pinned to the 1.7.1 commit (not `from: "1.7.1"`) because SwiftMail
        // itself depends on revision-pinned swift-nio-imap/ssl, and SPM refuses
        // to let a tagged dependency carry unstable deps. Consuming SwiftMail by
        // revision makes the whole chain unstable, which SPM allows. Move back
        // to `from:` once SwiftMail and its NIO deps are all on releases.
        .package(
            url: "https://github.com/Cocoanetics/SwiftMail",
            revision: "3bfb4a3a2a9677c6090221f622c537870ee78960"  // tag 1.7.1
        ),
        // Root must also re-declare SwiftMail's unstable NIO revisions.
        .package(
            url: "https://github.com/apple/swift-nio-imap",
            revision: "bcf875610ca56dfd7bae869fa19ca3149c075908"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-ssl",
            revision: "407d82d5b6cc00e1c3fb83a81b1539b70c788c5e"
        ),
        // Klartext reduces an HTML body to text (MailEngine's fetch path). Content
        // only, on-device, SwiftSoup-backed.
        .package(url: "https://github.com/excelano/klartext", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "ZirbeMail",
            dependencies: [
                .product(name: "SwiftMail", package: "SwiftMail"),
                .product(name: "Klartext", package: "klartext"),
            ]
        ),
        // macOS-only example. Exercises the adapter against a real account
        // using IMAP_* environment variables; not part of any app.
        .executableTarget(
            name: "imap-demo",
            dependencies: ["ZirbeMail"]
        ),
        .testTarget(
            name: "ZirbeMailTests",
            dependencies: ["ZirbeMail"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
