// swift-tools-version: 6.0

import PackageDescription

let strictConcurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency"),
]

let package = Package(
    name: "LocalMCPKit",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "LocalMCPContracts",
            targets: ["LocalMCPContracts"]
        ),
        .library(
            name: "LocalMCPDiscovery",
            targets: ["LocalMCPDiscovery"]
        ),
        .library(
            name: "LocalMCPDiscoveryBonjour",
            targets: ["LocalMCPDiscoveryBonjour"]
        ),
        .library(
            name: "LocalMCPProducer",
            targets: ["LocalMCPProducer"]
        ),
        .library(
            name: "LocalMCPConsumer",
            targets: ["LocalMCPConsumer"]
        ),
        .library(
            name: "LocalMCPTesting",
            targets: ["LocalMCPTesting"]
        ),
        .executable(
            name: "local-mcp",
            targets: ["local-mcp"]
        ),
        .executable(
            name: "local-mcp-two-producers-example",
            targets: ["local-mcp-two-producers-example"]
        ),
    ],
    targets: [
        .target(
            name: "LocalMCPContracts",
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "LocalMCPDiscovery",
            dependencies: ["LocalMCPContracts"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "LocalMCPDiscoveryBonjour",
            dependencies: ["LocalMCPDiscovery"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "LocalMCPMCPAdapter",
            dependencies: ["LocalMCPContracts"],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "LocalMCPProducer",
            dependencies: [
                "LocalMCPContracts",
                "LocalMCPDiscovery",
                "LocalMCPMCPAdapter",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "LocalMCPConsumer",
            dependencies: [
                "LocalMCPContracts",
                "LocalMCPDiscovery",
                "LocalMCPMCPAdapter",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "LocalMCPTesting",
            dependencies: [
                "LocalMCPContracts",
                "LocalMCPDiscovery",
                "LocalMCPDiscoveryBonjour",
                "LocalMCPProducer",
                "LocalMCPConsumer",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .executableTarget(
            name: "local-mcp",
            dependencies: [
                "LocalMCPConsumer",
                "LocalMCPDiscoveryBonjour",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .target(
            name: "LocalMCPTwoProducerExampleSupport",
            dependencies: [
                "LocalMCPContracts",
                "LocalMCPDiscovery",
                "LocalMCPProducer",
                "LocalMCPConsumer",
                "LocalMCPTesting",
            ],
            path: "Examples/TwoProducers/Sources/Support",
            swiftSettings: strictConcurrencySettings
        ),
        .executableTarget(
            name: "local-mcp-two-producers-example",
            dependencies: ["LocalMCPTwoProducerExampleSupport"],
            path: "Examples/TwoProducers/Sources/App",
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "LocalMCPContractsTests",
            dependencies: ["LocalMCPContracts"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "LocalMCPDiscoveryTests",
            dependencies: ["LocalMCPContracts", "LocalMCPDiscovery"],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "LocalMCPProducerTests",
            dependencies: [
                "LocalMCPContracts",
                "LocalMCPDiscovery",
                "LocalMCPProducer",
                "LocalMCPTesting",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "LocalMCPConsumerTests",
            dependencies: [
                "LocalMCPContracts",
                "LocalMCPConsumer",
                "LocalMCPProducer",
                "LocalMCPTesting",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "LocalMCPIntegrationTests",
            dependencies: [
                "LocalMCPContracts",
                "LocalMCPDiscovery",
                "LocalMCPProducer",
                "LocalMCPConsumer",
                "LocalMCPTesting",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "LocalMCPTwoProducerExampleTests",
            dependencies: [
                "LocalMCPTwoProducerExampleSupport",
                "LocalMCPContracts",
                "LocalMCPProducer",
                "LocalMCPTesting",
            ],
            path: "Examples/TwoProducers/Tests",
            swiftSettings: strictConcurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
