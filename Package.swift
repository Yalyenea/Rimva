// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Rimva",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Rimva", targets: ["Rimva"])],
    targets: [
        .target(name: "RimvaCore", resources: [.process("Resources")]),
        .executableTarget(name: "Rimva", dependencies: ["RimvaCore"]),
        .testTarget(name: "RimvaCoreTests", dependencies: ["RimvaCore"])
    ]
)
