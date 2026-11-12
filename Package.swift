// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioRelayBridge",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "AudioRelayBridge", targets: ["AudioRelayBridge"])],
    targets: [
        .executableTarget(name: "AudioRelayBridge"),
        .testTarget(name: "AudioRelayBridgeTests", dependencies: ["AudioRelayBridge"])
    ]
)
