// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpanscreenKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SpanscreenKit", targets: ["SpanscreenKit"])
    ],
    targets: [
        .target(name: "SpanscreenKit"),
        .testTarget(name: "SpanscreenKitTests", dependencies: ["SpanscreenKit"])
    ]
)
