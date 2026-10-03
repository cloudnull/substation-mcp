// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableExperimentalFeature("StrictConcurrency=complete"),
]

let package = Package(
    name: "substation-mcp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenStackClient", targets: ["OpenStackClient"]),
        .library(name: "OpenStackMCPServer", targets: ["OpenStackMCPServer"]),
        .library(name: "HummingbirdMCP", targets: ["HummingbirdMCP"]),
        .library(name: "FakeOpenStack", targets: ["FakeOpenStack"]),
        .executable(name: "substation-mcp", targets: ["substation-mcp"]),
        .executable(name: "substation-mcp-fake", targets: ["substation-mcp-fake"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.26.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.36.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.23.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.5.0"),
        .package(url: "https://github.com/swift-server/swift-prometheus.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        // MARK: - OpenStack client library (no MCP knowledge)
        .target(
            name: "OpenStackClient",
            dependencies: [
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Prometheus", package: "swift-prometheus"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - Hummingbird -> MCP SDK adapter (no OpenStack knowledge)
        .target(
            name: "HummingbirdMCP",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - MCP server logic (catalog, policy, tools)
        .target(
            name: "OpenStackMCPServer",
            dependencies: [
                .target(name: "OpenStackClient"),
                .target(name: "HummingbirdMCP"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - Fake OpenStack (test support + manual server)
        .target(
            name: "FakeOpenStack",
            dependencies: [
                .target(name: "OpenStackClient"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - Executable: the MCP server
        .executableTarget(
            name: "substation-mcp",
            dependencies: [
                .target(name: "OpenStackMCPServer"),
                .target(name: "HummingbirdMCP"),
                .target(name: "OpenStackClient"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Prometheus", package: "swift-prometheus"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - Executable: the fake cloud (additive, manual testing)
        .executableTarget(
            name: "substation-mcp-fake",
            dependencies: [
                .target(name: "FakeOpenStack"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: - Tests
        .testTarget(
            name: "OpenStackClientTests",
            dependencies: [
                .target(name: "OpenStackClient"),
                .target(name: "FakeOpenStack"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "OpenStackMCPServerTests",
            dependencies: [
                .target(name: "OpenStackMCPServer"),
                .target(name: "FakeOpenStack"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "HummingbirdMCPTests",
            dependencies: [
                .target(name: "HummingbirdMCP"),
                .target(name: "OpenStackMCPServer"),
                .target(name: "OpenStackClient"),
                .target(name: "FakeOpenStack"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "OpenStackMCPTests",
            dependencies: [
                .target(name: "OpenStackClient"),
                .target(name: "OpenStackMCPServer"),
                .target(name: "FakeOpenStack"),
                .target(name: "substation-mcp"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Configuration", package: "swift-configuration"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Prometheus", package: "swift-prometheus"),
            ],
            swiftSettings: swiftSettings
        ),
        // Opt-in integration tests against a REAL cloud (spec §14.6). The
        // target always compiles but self-skips unless OSMCP_IT_CLOUD is set,
        // so `swift test` in CI never touches a live cloud. The mutate pass is
        // further gated by OSMCP_IT_MUTATE=1 so CI can never mutate.
        .testTarget(
            name: "OpenStackMCPIntegrationTests",
            dependencies: [
                .target(name: "OpenStackClient"),
                .target(name: "OpenStackMCPServer"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ],
            path: "IntegrationTests"
        ),
    ]
)
