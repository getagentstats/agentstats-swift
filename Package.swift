// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "agentstats-swift",
    platforms: [.macOS("13.0"), .macCatalyst("16.0"), .iOS("16.0"), .watchOS("9.0"), .tvOS("16.0"), .visionOS("1.0")],
    products: [
        .library(name: "AgentStats", targets: ["AgentStats"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "AgentStats", dependencies: [
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .executableTarget(name: "AgentStatsExample", dependencies: ["AgentStats", .product(name: "MCP", package: "swift-sdk")]),
        .testTarget(name: "AgentStatsTests", dependencies: ["AgentStats", "AgentStatsExample", .product(name: "MCP", package: "swift-sdk")]),
    ]
)
