# Architecture

## Status and scope

This document records the architecture for LocalMCPKit V1 and the decisions needed to implement Phases 0 and 1. Later network phases must preserve these boundaries. If implementation evidence requires a different dependency direction or security invariant, record that change before relying on it.

LocalMCPKit lets an already-running macOS producer app expose app-owned commands as MCP tools. A consumer discovers live producers, asks the producer's user to approve a per-consumer grant, and then invokes MCP through an authenticated loopback endpoint.

The package owns protocol adaptation, lifecycle, local-only transport policy, discovery, authorization abstractions, and consumer connection management. Host apps own identity, command schemas and handlers, approval and operator UI, product policy, and app lifecycle composition.

## Phase 0 decisions

| Decision | V1 choice | Consequence |
| --- | --- | --- |
| Minimum toolchain/language mode | Swift tools 6.0 and Swift language mode 6 | Strict concurrency is available without requiring a generated Swift 6.4 baseline. |
| Deployment target | macOS 13 | Modern Swift concurrency and platform APIs are available while retaining a practical reusable-package floor. |
| Products | Focused products only | There is no `LocalMCPKit` umbrella product in V1. Clients import only the layers they use. |
| SDK adapter | Internal target | No MCP SDK type enters a public declaration. |
| Phase 0–1 dependencies | None outside the Swift/macOS SDKs | The contracts and in-memory vertical slice do not wait on a socket, Bonjour wrapper, Keychain implementation, or MCP SDK. |
| External pins | Intentionally none in Phases 0–1 | The official MCP Swift SDK and HTTP listener pins are selected and recorded at the Phase 2 implementation gate, after compatibility evaluation. |
| HTTP listener choice | Deferred to Phase 2 evaluation | Evaluate SwiftNIO directly against a thin server framework; whichever is chosen remains behind an internal listener protocol. |
| Pairing/descriptor routes | Separate versioned LocalMCPKit routes | `/mcp` carries MCP only. The descriptor and pairing contracts live under `/local-mcp/v1`. |
| Persisted grant reuse | Phase 4 endpoint-authenticity gate | A stable ID locates metadata but cannot authenticate a replacement endpoint before bearer disclosure. |
| File Search policy details | Deferred to Phase 6 | Empty-query semantics, query length, and path-versus-URI output do not belong in generic Phase 0/1 contracts. |

The official MCP Swift SDK release observed during planning was 0.12.1. That observation is not a dependency declaration or approved pin. Phase 2 must confirm the latest ratified MCP version, the then-current SDK release, supported protocol, Swift 6 compatibility, transitive packages, and macOS floor; then use one exact version. The listener dependency receives the same exact-pin treatment. Both are implementation details.

The planning baseline is MCP 2025-11-25, whose client lifecycle includes initialize followed by notifications/initialized. The incompatible 2026-07-28 release candidate removes that lifecycle and changes modern HTTP routing and metadata. Phase 2 must select one ratified version and test it end to end; it must never combine lifecycle rules from one version with transport semantics from another.

## Package graph

The intended target and product graph is:

```text
LocalMCPContracts
    ↑
LocalMCPDiscovery
    ↑
LocalMCPDiscoveryBonjour

LocalMCPContracts ← LocalMCPMCPAdapter (internal)

LocalMCPContracts
  + LocalMCPDiscovery
  + LocalMCPMCPAdapter
        ← LocalMCPProducer
        ← LocalMCPConsumer

public layers ← LocalMCPTesting

LocalMCPConsumer
  + LocalMCPDiscoveryBonjour
        ← local-mcp executable
```

Arrows point from a dependency toward its dependent. Cycles are forbidden. `LocalMCPDiscoveryBonjour` is the only module that imports the low-level DNS-SD API. `LocalMCPMCPAdapter` and the eventual listener adapter are internal targets, not products.

### Module responsibilities

#### LocalMCPContracts

Contains stable, framework-independent values and errors shared across producer and consumer layers:

- producer and consumer identities;
- per-launch producer instances and descriptors;
- discovery profile versions and compatibility results;
- command definitions, annotations, contexts, and results;
- pairing requests and authorization-grant metadata;
- JSON-compatible value/schema primitives; and
- LocalMCPKit-owned error categories.

Wire values are `Codable`, `Sendable`, and value-semantic. Public declarations do not expose AppKit, SwiftUI, DNS-SD, Keychain, SwiftNIO, an MCP SDK, or host-app model types.

The JSON-compatible value model preserves signed 64-bit integers separately from fractional numbers and rejects non-finite floating-point values. It must not round every number through `Double`.

#### LocalMCPDiscovery

Contains platform-neutral discovery contracts and state reduction:

- advertiser and browser protocols;
- async added/updated/removed events;
- descriptor loading and compatibility boundaries;
- cancellation-aware lifecycle; and
- deduplication by producer instance ID.

The in-memory advertiser/browser used in Phase 1 implements these protocols without sockets.

#### LocalMCPDiscoveryBonjour

Implements the V1 profile in [the discovery specification](../Spec/local-discovery-v1.md) with DNS-SD LocalOnly registration, browsing, resolution, and TXT handling. It arrives in Phase 3. It must not broaden the interface-selection policy exposed by its public configuration.

#### LocalMCPMCPAdapter (internal)

Maps LocalMCPKit contracts to and from the exact-pinned MCP SDK. It owns protocol initialization, tools/list, tools/call, JSON-RPC error adaptation, and Streamable HTTP request/response adaptation. The rest of the package does not import the SDK.

The adapter prefers stateless server behavior. Session/version mechanics remain behind its protocol because MCP transport behavior may evolve independently of the package API.

#### LocalMCPProducer

Owns:

- validated immutable local-only configuration;
- deterministic, concurrency-safe command registration;
- typed handler erasure and dispatch;
- the producer state machine;
- authorization checks and grant lifecycle operations;
- descriptor/pairing/MCP route composition; and
- coordination of listener and advertiser lifecycles.

It accepts host-supplied identity, command handlers, approval callbacks, credential storage, clock, randomness, and optional diagnostics. It never imports a producer app's model layer.

#### LocalMCPConsumer

Owns:

- discovery observation and compatible-instance state;
- pairing orchestration through an injected authorization transport;
- stored-grant lookup and retry after a producer restart;
- MCP initialize, the version-required initialized transition, tool listing, and tool invocation;
- bounded reconnect/backoff; and
- typed convenience decoding over a schema-first dynamic core.

The consumer does not decide which discovered producer to trust or which tools an LLM may see/call. Those are host-app policy decisions.

#### LocalMCPTesting

Provides public in-memory implementations and deterministic controls:

- advertiser/browser;
- producer transport and consumer connection;
- credential store;
- approval controller;
- clock and randomness;
- request recorder; and
- fixtures/builders for descriptors, grants, and commands.

Tests should be able to run the complete echo discovery-pair-list-call-revoke flow without GUI interaction, DNS-SD, Keychain, sockets, or an MCP SDK.

#### local-mcp

The later diagnostic executable imports the consumer and Bonjour products. It reports discovery and compatibility state with redacted diagnostics. It is not an authorization bypass and cannot obtain a grant without producer-side approval.

## Core boundaries

### Commands

The app-facing unit is a `CommandDefinition`, not an SDK `Tool`. A definition has a stable name, title/description, explicit JSON input schema, optional output schema, and safety annotations. A registered handler accepts typed input plus a `CommandContext` and returns a `CommandResult`.

The registry validates names and schema-document JSON shape at registration, rejects duplicates, and lists definitions in deterministic lexical name order. Phase 1 typed dispatch validates Codable structure; general JSON Schema constraint evaluation is a Phase 2 pre-dispatch requirement, and host handlers retain app-specific validation and authorization. V1 command registration is allowed only while the producer is stopped; startup freezes the prepared registry, and registration during starting/running/stopping fails without mutation. Type erasure is internal. Decode, handler, encode, timeout, and cancellation failures map to stable package errors without exposing underlying framework details.

Annotations are descriptive hints, not authorization. A `readOnly` command still requires a valid grant and host/consumer policy may further restrict it.

### Discovery

The discovery abstraction carries structured instances and state transitions, not raw DNS-SD handles. Platform backends are replaceable; V1 ships only the macOS LocalOnly backend. The contract must leave room for future platforms without weakening macOS local-only guarantees.

Discovery is deliberately split from connection. Resolving and decoding a descriptor never starts MCP initialization, lists tools, opens pairing UI automatically, or marks an instance trusted.

The Phase 1 catalog is a replaying broadcast keyed by instance ID. Late subscribers receive a deterministic snapshot before live transitions, and incompatible instances remain observable rather than looking offline. Per-subscriber buffering is bounded; overflow terminates only that stream so a consumer can resubscribe and replay a converged snapshot instead of processing a silent gap.

### Authorization

Authorization is represented by protocols in the early vertical slice:

- a producer-side grant store that issues, validates, rotates, and revokes;
- a consumer-side credential store that retrieves and removes producer grants;
- a producer approval callback; and
- a pairing transport used by the consumer.

Phase 1 uses deterministic in-memory implementations. Phase 4 supplies the versioned loopback exchange and Keychain stores without changing command or discovery APIs. Every dispatched request carries a `CommandContext` derived from the validated grant, never a caller-provided context.

### Transport

The logical request path is:

```text
consumer API
  → LocalMCP client adapter
  → authenticated Streamable HTTP request
  → request-context and size checks
  → grant validation
  → MCP adapter
  → command registry
  → app handler
```

In Phase 1, an in-memory transport crosses the same conceptual boundaries and must enforce authorization before dispatch. Network-only behavior is not faked into contracts; Host/Origin parsing, actual HTTP, and MCP SDK mapping arrive in Phase 2.

## Concurrency and ownership

Public operations are async where they can suspend and public values conform to `Sendable`. Mutable subsystems have a single isolation owner, normally an actor:

- command registry;
- producer lifecycle;
- discovery state reducer;
- grant store;
- consumer connection state; and
- test doubles with mutable observations.

Host handlers may run concurrently for different requests. The package does not move them to `MainActor`. Cancellation and deadlines are propagated through `CommandContext`. Callback/protocol declarations use `@Sendable` where they can cross isolation domains.

The implementation enables strict concurrency checking for every target. `@unchecked Sendable` requires a documented synchronization proof and a focused stress test; it is not a convenience for framework wrappers.

## Lifecycle

### Producer state machine

Observable states are equivalent to:

```text
stopped → starting → running → stopping → stopped
              ↘ failure cleanup ↗
```

`start()` and `stop()` are idempotent. Concurrent callers observe one transition rather than starting duplicate resources. A failed start unwinds completed stages in reverse order and finishes stopped with a sanitized error.

Network startup order:

1. Validate immutable local-only configuration.
2. Freeze/prepare command registry and authorization middleware.
3. Start an IPv4 loopback listener and obtain its actual port.
4. Expose descriptor, pairing, and MCP routes.
5. Register `_appmcp._tcp` on the LocalOnly DNS-SD interface.
6. Publish running state.

Shutdown order:

1. Withdraw discovery.
2. Stop accepting pairing and MCP requests.
3. Cancel or drain active requests under a bounded policy.
4. Close the listener.
5. Publish stopped state.

No public configuration accepts an arbitrary bind host or interface. An ephemeral port is the default. If a fixed port is later supported for tests/diagnostics, it does not change the bind address. The instance ID is created once for a producer object's process lifetime: stopping and restarting the same object retains it, while constructing a new producer creates a new instance ID.

### Consumer lifecycle

Browsing is long-lived and cancellation-aware. The consumer serializes discovery reduction, deduplicates by instance ID, and emits only material transitions. A process restart creates a new instance. Stored grant lookup is keyed by stable producer ID and consumer installation identity, but that lookup does not authenticate a newly advertised endpoint. Phase 1 must not equate an in-memory grant lookup with network endpoint authenticity; persisted network-grant reuse is gated by the Phase 4 security decision recorded in [the security model](security.md#phase-4-decision-gate-producer-endpoint-authenticity).

Connection attempts use bounded exponential backoff with cancellation and an upper delay. Removal stops retries. An incompatible descriptor has its own observable condition and is not collapsed into offline.

## Error contract

Framework errors are adapted to stable package errors. The public model distinguishes at least:

- invalid configuration;
- bind or advertisement failure;
- incompatible discovery profile or MCP protocol;
- producer unavailable;
- pairing required, denied, or expired;
- unauthorized or revoked grant;
- invalid command input, missing command, or sanitized command failure;
- request timeout; and
- cancellation.

Errors may carry safe identifiers such as a command name or trace ID. They do not carry tokens, authorization headers, pairing nonces/codes, full command payloads, raw Keychain values, or unsanitized transport errors.

## Phase 1 vertical slice

Phase 1 proves the architecture without network dependencies:

1. Register a typed echo command on an in-memory producer.
2. Start the producer and publish it through in-memory discovery.
3. Observe one `added` event and no duplicate event for equivalent state.
4. Attempting to list/call without a grant fails before handler dispatch.
5. Submit a pairing request to an injected approval controller.
6. Approve it and store a per-consumer grant.
7. Initialize, list tools in deterministic order, and call echo through the in-memory client boundary.
8. Revoke the grant.
9. Confirm the next call is rejected before the echo handler runs.
10. Stop the producer and observe removal/cleanup.
11. Repeat with two consumers and prove revoking one grant does not affect the other.

Unit tests also cover Codable compatibility, duplicate command registration, typed decode/encode failures, discovery transitions (including late and multiple subscribers), pairing denial/expiry/rotation, cancellation, deadline propagation, idempotent lifecycle, and cleanup at every injected startup failure point.

## Dependency and evolution policy

Public API uses stable primitives and package-owned protocols. Pre-1.0 or transport-specific packages are isolated and exactly pinned. Updating a pin requires adapter tests and the real negotiated lifecycle/list/call integration suite; it does not force host apps to import that package.

Discovery profile and descriptor compatibility are governed by [the V1 profile](../Spec/local-discovery-v1.md). Additive optional JSON fields are allowed; readers ignore them. Breaking wire changes require a new schema/profile version and fixtures covering both compatible and incompatible readers.

A future stdio executable is a proxy to the live authenticated loopback producer. It must not instantiate a second copy of app data access or command logic.

## References

- [Local discovery V1](../Spec/local-discovery-v1.md)
- [Security model](security.md)
- [Integration guide](integration.md)
- [MCP 2025-11-25 Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [Official MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
