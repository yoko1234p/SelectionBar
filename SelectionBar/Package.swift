// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "SelectionBar", defaultLocalization: "en", platforms: [.macOS(.v14)],
  products: [
    .executable(name: "SelectionBar", targets: ["SelectionBar"]),
    .executable(name: "SelectionBarRuntime", targets: ["SelectionBarRuntime"]),
  ],
  dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "5.1.3"), .package(path: "../Shared/LocalWorkflowKit"), .package(path: "../Shared/AppLocalizationKit")],
  targets: [
    .target(
      name: "SelectionBarCore", dependencies: ["Yams", .product(name: "AppLocalizationKit", package: "AppLocalizationKit")], resources: [.process("Resources")],
      linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "SelectionBar", dependencies: ["SelectionBarCore", .product(name: "LocalWorkflowKit", package: "LocalWorkflowKit")]),
    .executableTarget(name: "SelectionBarRuntime", dependencies: ["SelectionBarCore"]),
    .testTarget(name: "SelectionBarCoreTests", dependencies: ["SelectionBarCore"]),
    .testTarget(name: "SelectionBarIconTests", dependencies: ["SelectionBar", "SelectionBarCore"]),
  ]
)
