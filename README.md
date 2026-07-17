# LocalMCPKit

LocalMCPKit is a Swift package for exposing app-owned commands from a running macOS app and discovering, pairing with, and calling those commands from another local app.

The package currently implements the complete transport-neutral core: strict Swift 6 contracts, typed command registration, producer and consumer lifecycles, discovery state, per-consumer authorization, cancellation/deadline behavior, and deterministic in-memory integrations. The real Streamable HTTP, Bonjour LocalOnly, and Keychain backends are the next phases and are not represented as finished here.

## Requirements

- macOS 13 or newer
- Swift 6.0 or newer
- XcodeGen and Tart only when building or VM-testing the SwiftUI example through its Xcode project

## Build and test

```sh
swift package describe
swift build
swift test
```

The suite covers contracts, JSON fidelity, discovery, pairing, authorization, producer and consumer lifecycle races, typed commands, credential isolation, full in-memory flows, and the two-producer example.

## Two-producer SwiftUI example

The example places one logical consumer and two independent producers in one process using the in-memory boundaries:

- `Greeter Producer` exposes `greeting.hello`.
- `Calculator Producer` exposes `math.add`.
- Both client sessions share one consumer installation identity but receive separate grants.

Run the SwiftPM executable:

```sh
swift run local-mcp-two-producers-example
```

Or generate the example Xcode project:

```sh
xcodegen generate
open LocalMCPTwoProducerExample.xcodeproj
```

The UI demonstrates discovery, pairing, MCP initialization, tool listing, typed calls, isolated revocation, service reset behavior, and cleanup. Pairing approval is automatic and prominently marked as demo-only; a production producer must present a real producer-owned approval prompt.

See [the example guide](Examples/TwoProducers/README.md) for its architecture and VM UI-test workflow.

## Package products

- `LocalMCPContracts` — package-owned wire-neutral values, identities, commands, grants, and service protocols.
- `LocalMCPDiscovery` — replaying add/update/remove discovery state.
- `LocalMCPProducer` — typed command hosting, lifecycle, pairing, authorization, cancellation, and deadlines.
- `LocalMCPConsumer` — per-producer pairing and negotiated client lifecycle.
- `LocalMCPTesting` — in-memory transports, stores, discovery, approvers, clocks, and random sources.
- `LocalMCPDiscoveryBonjour` — placeholder for the LocalOnly DNS-SD backend.
- `local-mcp` — placeholder diagnostic CLI.
- `local-mcp-two-producers-example` — runnable SwiftUI example.

## Design and security

Start with:

- [Integration guide](Docs/integration.md)
- [Architecture](Docs/architecture.md)
- [Security model](Docs/security.md)
- [Local discovery V1 specification](Spec/local-discovery-v1.md)
- [Implementation handoff and roadmap](HANDOFF.md)

Discovery means available, not trusted. Credentials never belong in DNS-SD TXT records, descriptors, logs, or UI timelines. A discovered replacement process must not receive a persisted bearer merely because it claims the same stable producer ID.

## Project status

Phases 0 and 1 are complete. The example exercises those phases in memory. Phase 2 will add authenticated loopback Streamable HTTP and the real MCP adapter; later phases add Bonjour, Keychain-backed pairing, the diagnostic CLI, and external app integrations.
