// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PlexKit",
    platforms: [.visionOS(.v26), .macOS(.v15)],
    products: [.library(name: "PlexKit", targets: ["PlexKit"])],
    targets: [
        .target(name: "PlexKit"),
        .testTarget(name: "PlexKitTests", dependencies: ["PlexKit"]),
    ]
)
