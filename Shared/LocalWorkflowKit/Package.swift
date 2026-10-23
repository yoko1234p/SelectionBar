// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalWorkflowKit", platforms: [.macOS(.v14)],
    products: [.library(name: "LocalWorkflowKit", targets: ["LocalWorkflowKit"])],
    targets: [
        .target(name: "LocalWorkflowKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LocalWorkflowKitTests", dependencies: ["LocalWorkflowKit"]),
    ])
