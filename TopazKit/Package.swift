// swift-tools-version:5.9
import PackageDescription

/// Code the Topaz helpers share (Loupe and Topaz Launcher).
let package = Package(
    name: "TopazKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TopazKit", targets: ["TopazKit"])],
    targets: [.target(name: "TopazKit")]
)
