// swift-tools-version: 6.0

import PackageDescription

// Swift 6 language mode enables complete strict-concurrency checking by default.
let strictConcurrencySettings: [SwiftSetting] = []

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
            name: "local-mcp-example-producer",
            targets: ["local-mcp-example-producer"]
        ),
        .executable(
            name: "local-mcp-example-consumer",
            targets: ["local-mcp-example-consumer"]
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
            dependencies: ["LocalMCPContracts", "LocalMCPDiscovery"],
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
                "LocalMCPContracts",
                "LocalMCPDiscovery",
                "LocalMCPDiscoveryBonjour",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .executableTarget(
            name: "local-mcp-example-producer",
            dependencies: [
                "LocalMCPContracts",
                "LocalMCPDiscoveryBonjour",
                "LocalMCPProducer",
                "LocalMCPTesting",
            ],
            path: "Examples/SeparateProcess/Producer",
            swiftSettings: strictConcurrencySettings
        ),
        .executableTarget(
            name: "local-mcp-example-consumer",
            dependencies: [
                "LocalMCPContracts",
                "LocalMCPConsumer",
                "LocalMCPTesting",
            ],
            path: "Examples/SeparateProcess/Consumer",
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
            name: "LocalMCPDiscoveryBonjourTests",
            dependencies: [
                "LocalMCPContracts",
                "LocalMCPDiscovery",
                "LocalMCPDiscoveryBonjour",
            ],
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
                "LocalMCPMCPAdapter",
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
        .testTarget(
            name: "LocalMCPCommandTests",
            dependencies: [
                "local-mcp",
                "LocalMCPContracts",
                "LocalMCPDiscovery",
            ],
            swiftSettings: strictConcurrencySettings
        ),
        .testTarget(
            name: "LocalMCPSeparateProcessTests",
            dependencies: [
                "local-mcp",
                "local-mcp-example-producer",
                "local-mcp-example-consumer",
            ],
            swiftSettings: strictConcurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

// The SwiftUI demo app crashes the Swift 6.0 compiler while emitting SwiftUI
// protocol witnesses (signal 6 in IRGen). Every library product keeps the
// package's Swift 6.0 floor; only this GUI example requires a newer compiler.
#if compiler(>=6.1)
package.products.append(
    .executable(
        name: "local-mcp-two-producers-example",
        targets: ["local-mcp-two-producers-example"]
    )
)
package.targets.append(
    .executableTarget(
        name: "local-mcp-two-producers-example",
        dependencies: ["LocalMCPTwoProducerExampleSupport"],
        path: "Examples/TwoProducers/Sources/App",
        swiftSettings: strictConcurrencySettings
    )
)
#endif
