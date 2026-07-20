// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PMSKit",
    platforms: [.iOS("26.1"), .tvOS("26.0"), .visionOS(.v26), .macOS(.v15)],
    products: [.library(name: "PMSKit", targets: ["PMSKit"])],
    targets: [
        .target(name: "PMSKit"),
        .testTarget(name: "PMSKitTests", dependencies: ["PMSKit"]),
    ]
)
