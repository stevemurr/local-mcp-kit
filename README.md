# LocalMCPKit

LocalMCPKit is a Swift package for exposing app-owned commands from a running macOS app and discovering, pairing with, and calling those commands from another local app.

V1 includes the complete transport-neutral core and production macOS backends: typed command registration and JSON Schema validation, an MCP 2025-11-25 adapter carried inside the LocalMCP encrypted loopback envelope (`localmcp-secure-http`), a numeric IPv4-loopback listener, Bonjour LocalOnly discovery, explicit channel-bound producer-approved pairing, per-consumer Keychain grants, and the negotiated consumer lifecycle. The full MCP lifecycle runs unchanged inside the sealed envelope; the outer wire is never generic plaintext Streamable HTTP.

## Requirements

- macOS 13 or newer
- Swift tools and language mode 6.0 or newer
- XcodeGen and Tart only when building or VM-testing the SwiftUI example through its Xcode project

LocalMCPKit has no external package dependencies. The official MCP Swift SDK 0.12.1 was evaluated, but it requires Swift tools 6.1 and carries a moving DocC dependency. V1 therefore keeps a small MCP 2025-11-25 wire adapter and HTTP/1.1 listener in the internal `LocalMCPMCPAdapter` target. No wire or networking type appears in the public API.

## Build and test

```sh
swift package describe
swift build
swift test
```

The package suite covers contracts and JSON fidelity, schema assertions, producer and consumer lifecycle races, HTTP framing and security policy, MCP sessions and cancellation, Bonjour TXT/descriptor/LocalOnly behavior, pairing and Keychain boundaries, the read-only CLI, separate-process operation, and the two-producer example. UI tests run only in the repository's Tart VM workflow:

```sh
Scripts/run-ui-tests.sh
```

## Production composition

A producer combines these public implementations with app-owned commands and approval UI:

```swift
let discovery = BonjourLocalMCPDiscovery()
let producer = LocalMCPProducer(
    identity: producerIdentity,
    transport: LocalMCPHTTPProducerTransport(),
    advertiser: discovery,
    grantStore: try KeychainProducerGrantStore(),
    approval: approvalController
)

try await producer.register(commandDefinition, handler: commandHandler)
try await producer.start()
```

A consumer browses with `BonjourLocalMCPDiscovery`, connects with `LocalMCPHTTPConnector`, stores grants in `KeychainConsumerGrantStore`, and uses `LocalMCPConsumer` for explicit pairing, initialize, `notifications/initialized`, `tools/list`, and `tools/call`. App-owned teardown calls `await consumer.close()` to cancel work and terminate the cached session; command calls are never automatically replayed after an ambiguous session failure.

Discovery is availability, not trust. A saved bearer is never sent automatically to a replacement producer instance just because it advertises the same stable ID. The user must explicitly pair/rebind with the new instance before authenticated calls.

See the [integration guide](Docs/integration.md) for command schemas, lifecycle ownership, approval UI, entitlements, and troubleshooting.

## Examples and CLI

- [`Examples/TwoProducers`](Examples/TwoProducers/README.md) is a SwiftUI app with one logical consumer, Greeter and Calculator producers, and independent grants. It deliberately uses in-memory boundaries so the orchestration is easy to inspect.
- [`Examples/SeparateProcess`](Examples/SeparateProcess/README.md) runs a real HTTP/Bonjour producer and consumer as separate processes and completes the authenticated MCP lifecycle.
- `local-mcp discover [--timeout SECONDS] [--json]` observes untrusted LocalOnly advertisements.
- `local-mcp inspect-descriptor <PATH|-> [--json]` validates a bounded descriptor document.

The CLI is intentionally read-only: it never pairs, reads a grant, lists tools, or invokes commands.

## Package products

- `LocalMCPContracts` — package-owned wire-neutral values, identities, commands, grants, and service protocols.
- `LocalMCPDiscovery` — replaying add/update/remove discovery state.
- `LocalMCPDiscoveryBonjour` — real DNS-SD registration, browsing, resolution, TXT handling, and bounded descriptor loading, all restricted to `kDNSServiceInterfaceIndexLocalOnly`.
- `LocalMCPProducer` — typed command hosting, schema validation, production HTTP transport, pairing, authorization, cancellation, deadlines, Keychain grants, and lifecycle.
- `LocalMCPConsumer` — production HTTP connector, explicit pairing, Keychain grants, and negotiated client lifecycle.
- `LocalMCPTesting` — deterministic in-memory transports, stores, discovery, approvers, clocks, and random sources.
- `local-mcp` — read-only discovery and descriptor diagnostic CLI.

`LocalMCPMCPAdapter` is internal. It implements exactly the ratified MCP 2025-11-25 lifecycle used by V1 and is not a public product.

## Security boundaries

- The listener binds only numeric `127.0.0.1`; there is no public bind-host option.
- Bonjour registration, browse, resolve, and callback acceptance are LocalOnly.
- The exact numeric `Host` is required and every present `Origin` is rejected.
- MCP requests require one valid bearer before dispatch and are bounded by header, body, connection, session, command, and handler limits.
- Pairing is explicit, producer-owned, short-lived, rate/concurrency limited, and issues a distinct grant per consumer installation.
- Producer Keychain records contain only token digests; consumer Keychain records hold their own bearer. Items are non-synchronizing and device-only.
- Tokens, nonces, verification codes, command payloads, and filesystem data do not belong in discovery, descriptors, logs, or diagnostic bundles.

Read [the security model](Docs/security.md) before embedding a producer. This repository intentionally does not select a software license; consumers must obtain permission appropriate to their use until one is added.

## Documentation

- [Integration guide](Docs/integration.md)
- [Architecture](Docs/architecture.md)
- [Security model](Docs/security.md)
- [Local discovery V1 specification](Spec/local-discovery-v1.md)
- [Implementation handoff and evidence checklist](HANDOFF.md)
