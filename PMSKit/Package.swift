// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PMSKit",
    platforms: [.iOS("26.1"), .tvOS("26.0"), .visionOS(.v26), .macOS(.v15)],
    products: [.library(name: "PMSKit", targets: ["PMSKit"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.1"),
    ],
    targets: [
        .target(
            name: "PMSKit",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(name: "PMSKitTests", dependencies: ["PMSKit"]),
    ]
)
