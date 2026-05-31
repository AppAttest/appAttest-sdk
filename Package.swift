// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppAttest",
    platforms: [
        // Bumped from iOS 14 / macOS 11 / tvOS 15 / watchOS 9 to
        // iOS 17 / macOS 14 / tvOS 17 / watchOS 10 because the public API
        // is `@Observable @MainActor` (Observation macro requires
        // iOS 17+/macOS 14+/tvOS 17+/watchOS 10+).
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "AppAttest",
            targets: ["AppAttest"]
        ),
        // Objective-C-friendly wrapper for bridge writers (RN, Flutter,
        // Capacitor) and any native consumer that prefers completion-handler
        // APIs and NSError. Native Swift consumers should target `AppAttest`
        // directly — this product is intentionally a flatter, lossy view.
        .library(
            name: "AppAttestObjC",
            targets: ["AppAttestObjC"]
        )
    ],
    dependencies: [
        // Build-time only. Adds `swift package generate-documentation`.
        // Consumers of the SDK never see this — SwiftPM resolves plugins
        // lazily and skips them entirely on `swift build`/`swift test`.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0")
    ],
    targets: [
        .target(
            name: "AppAttest",
            path: "Sources/AppAttest",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "AppAttestObjC",
            dependencies: ["AppAttest"],
            path: "Sources/AppAttestObjC"
        ),
        .testTarget(
            name: "AppAttestTests",
            dependencies: ["AppAttest"],
            path: "Tests/AppAttestTests"
        ),
        .testTarget(
            name: "AppAttestObjCTests",
            dependencies: ["AppAttestObjC"],
            path: "Tests/AppAttestObjCTests"
        )
    ]
)
