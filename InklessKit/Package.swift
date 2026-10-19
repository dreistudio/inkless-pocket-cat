// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InklessKit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "InklessKit", targets: ["InklessKit"])],
    targets: [
        .target(name: "InklessKit"),
        .testTarget(name: "InklessKitTests", dependencies: ["InklessKit"], resources: [.copy("Fixtures")]),
    ]
)
