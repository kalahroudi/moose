// swift-tools-version:6.0
import PackageDescription

// No third-party dependencies: keeps the binary small and the memory footprint low.
let package = Package(
    name: "moose",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Moose", targets: ["Moose"]),
        .executable(name: "moose-mcp", targets: ["moose-mcp"]),
        .library(name: "MooseKit", targets: ["MooseKit"]),
    ],
    targets: [
        // UI-free core: everything that touches the system, parses output or decides something. Unit tested.
        .target(name: "MooseKit"),
        // The menu bar + Dock app.
        .executableTarget(name: "Moose", dependencies: ["MooseKit"]),
        // Model Context Protocol server (stdio) so agents can drive the app's capabilities.
        .executableTarget(name: "moose-mcp", dependencies: ["MooseKit"]),
        .testTarget(name: "MooseKitTests", dependencies: ["MooseKit"]),
    ],
    swiftLanguageModes: [.v5]
)
