// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VocaCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "VocaCore", targets: ["VocaCore"])],
    targets: [
        .target(name: "VocaCore"),
        .testTarget(name: "VocaCoreTests", dependencies: ["VocaCore"])
    ]
)
