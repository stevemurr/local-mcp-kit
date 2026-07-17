# LocalMCPKit Agent Handoff

Status: Phase 0 and Phase 1 complete; Phase 2 not started
Last updated: 2026-07-16
Repository: https://github.com/stevemurr/local-mcp-kit
First integration: a sibling `file-search` checkout (not part of this repository)

## Start here

This document is the source of truth for a fresh implementation task. Read it completely before changing the package.

LocalMCPKit is intended to make locally running macOS apps discoverable and callable through Model Context Protocol (MCP):

- A producer app imports the producer library, registers app-owned commands, and starts an MCP endpoint.
- The producer advertises only to other processes on the same Mac.
- A consumer imports discovery and client libraries, observes producers appearing and disappearing, asks the user to trust/pair with a producer, and then lists or invokes its MCP tools.
- File Search is the first real producer, but no File Search or AppKit types belong in this package.

The package graph, contracts, in-memory producer/consumer stack, deterministic test doubles, Phase 0 documentation, and a one-consumer/two-producer SwiftUI example are implemented. Network HTTP, Bonjour, Keychain, the diagnostic CLI behavior, separate-process examples, and File Search integration remain later phases.

## Current repository state

The repository is published from branch `main`. All implementation work is confined to this repository; the sibling File Search checkout has not been edited.

Current implementation facts:

- Package.swift now requires Swift tools/language mode 6.0 and macOS 13.
- The focused public products and internal MCP adapter target are scaffolded with strict concurrency.
- There are no external package dependencies in Phases 0–1.
- Shared contracts, a typed command registry, replaying discovery catalog, pairing/grant authorization, producer lifecycle, negotiated consumer lifecycle, and in-memory testing support are implemented.
- Credentials are opaque/redacted; producer stores receive only SHA-256 token digests.
- The in-memory consumer performs initialize then notifications/initialized before list/call and coalesces concurrent negotiation.
- The package suite includes 128 tests covering contracts, discovery, commands, pairing, lifecycle rollback/cancellation, consumers, two-consumer isolation, and the two-producer example.
- The in-memory SwiftUI example is implemented with a VM-only XCUI suite. The CLI, Bonjour backend, real HTTP/MCP adapter, Keychain stores, separate-process examples, and File Search integration remain later work.

## Mission

Build a reusable Swift package that lets an app expose MCP tools from its live process and lets another local app discover, pair with, and call those tools.

The package should establish a pattern that can be embedded in multiple apps. Application code owns command schemas and handlers. LocalMCPKit owns protocol adaptation, lifecycle, loopback transport policy, local discovery, pairing credentials, and consumer connection management.

## V1 scope

V1 must provide:

1. Shared, versioned producer/discovery/consumer contracts.
2. A type-safe producer-facing command registration API.
3. An MCP server adapter using Streamable HTTP.
4. A real HTTP listener bound strictly to 127.0.0.1 on an ephemeral port by default.
5. Machine-local discovery on macOS using DNS-SD/Bonjour LocalOnly registration and browsing.
6. A consumer API that emits added, updated, and removed producer events.
7. Explicit user pairing and per-consumer authorization credentials stored through an injectable secure credential store.
8. An MCP client wrapper for the complete negotiated lifecycle. Under MCP 2025-11-25 this is initialize, notifications/initialized, tools/list, and tools/call.
9. In-memory test doubles, end-to-end tests, a diagnostic CLI, and minimal producer/consumer examples.
10. File Search as the first external integration after the generic vertical slice works.

## Explicit non-goals for V1

- LAN discovery or listening on non-loopback interfaces.
- Internet-facing or remote MCP hosting.
- Publishing live processes to the official MCP Registry.
- A privileged helper, login item, launch daemon, or mandatory central broker.
- File Search-specific models in this repository.
- File contents or mutating file actions in the first File Search integration.
- A native stdio producer as the primary architecture.
- Linux or Windows discovery implementations. Their future support must remain possible through protocols.
- Automatic invocation merely because a process was discovered.
- Treating DNS-SD advertisements as authenticated identity.

## Terminology

- Producer: an app process exposing app-owned commands as MCP tools.
- Consumer: an app process discovering producers and calling their MCP tools.
- Command: the LocalMCPKit app-facing abstraction. It maps to an MCP tool on the wire.
- Discovery record: minimal DNS-SD metadata used to locate a versioned descriptor.
- Descriptor: non-secret JSON describing a producer instance, endpoint, protocol versions, and pairing mode.
- Stable producer ID: reverse-DNS identifier shared by releases of one producer, such as com.stevemurr.filesearch.
- Instance ID: random identifier generated per process launch.
- Grant: per-consumer authorization issued after explicit producer-side approval.

## Settled architecture decisions

The labels in this document are intentional:

- DECIDED means implementation should follow it unless new evidence is recorded in an ADR.
- INVARIANT means violating it is a security or architecture defect.
- OPEN means the implementing agent must decide and document it before depending on it.
- ACCEPTANCE means required evidence for completion.

### Protocol and transport

- DECIDED: Target the latest ratified MCP specification at implementation time. The planning baseline is 2025-11-25 as of this document.
- DECIDED: Use Streamable HTTP as the producer transport because the server lives inside an already-running GUI app and must support multiple consumers.
- DECIDED: Keep lifecycle, session, headers, and version behavior behind an adapter. Under 2025-11-25, a client must send notifications/initialized after initialize and before normal operation.
- DECIDED: Re-check the ratified version immediately before Phase 2. The locked 2026-07-28 release candidate is intentionally incompatible: it removes initialize/notifications/initialized and Mcp-Session-Id, moves version, identity, and capabilities into per-request metadata, adds mandatory server/discover, and changes modern Streamable HTTP to POST-only requests with routing headers. Never combine the 2025-11-25 lifecycle with those newer transport semantics.
- DECIDED: Bind to 127.0.0.1 only. Use an ephemeral port by default and advertise the resolved port.
- DECIDED: Use one relative MCP endpoint path, initially /mcp.
- DECIDED: A future stdio helper should proxy to the authenticated loopback endpoint rather than start a second copy of app logic or data access.
- INVARIANT: Neither preferences nor malformed configuration may cause a wildcard, LAN, or public bind.
- INVARIANT: The public package API must not expose types from a pre-1.0 MCP SDK or the chosen HTTP framework.

The official Swift SDK is the preferred protocol candidate, not an assumption of complete conformance. Swift is currently an official Tier 3 SDK. Version 0.12.1 was the latest observed release when this document was written; it implements MCP 2025-11-25, not the 2026-07-28 release candidate. It is pre-1.0, so pin it exactly behind LocalMCPKit-owned adapters and confirm both the release and supported protocol before adding it. Its StatelessHTTPServerTransport adapts JSON POST request/response data; it is not a listening socket, does not provide sessions or SSE, and drops server-initiated messages. Add protocol conformance tests and re-check SDK support after the next ratified MCP release.

### Discovery

- DECIDED: MCP itself does not currently define ambient discovery of arbitrary running localhost endpoints. tools/list occurs after a connection is established.
- DECIDED: The official MCP Registry is for distributable/public server metadata, not live same-machine process presence.
- DECIDED: Define a small, versioned LocalMCPKit discovery profile.
- DECIDED: The macOS backend registers with the low-level DNS-SD API using kDNSServiceInterfaceIndexLocalOnly. Browsers also request LocalOnly results, discard every callback whose interfaceIndex is not kDNSServiceInterfaceIndexLocalOnly, and resolve using the accepted callback's interface index. Apple documents that a LocalOnly browse can otherwise return all records registered on the same machine, not only LocalOnly registrations.
- DECIDED: Use the unregistered private service type _appmcp._tcp for this profile. It has no IANA ownership or collision guarantee. Centralize it in one place, document collision/migration behavior, and adopt an assigned or future standard name before claiming external interoperability.
- DECIDED: Do not use _mcp._tcp; IANA already assigns the mcp service name to Matrix Configuration Protocol.
- INVARIANT: A V1 discovery advertisement must never leave the machine.
- INVARIANT: Discovery data contains no bearer token, pairing secret, filesystem path, command arguments, tool list, or user data.
- INVARIANT: Discovery means available, not trusted.

The DNS-SD TXT record should remain deliberately small:

~~~
v=1
id=com.stevemurr.filesearch
path=/mcp
desc=/local-mcp/v1/descriptor.json
auth=pair
~~~

The SRV record supplies the dynamic port. Consumers construct a loopback URL from the resolved port and relative path. They must not trust an advertised arbitrary hostname for V1.

The desc field names a LocalMCPKit-only descriptor. Do not call it a server card or server.json: those names refer to separate experimental Server Card work and the official Registry manifest.

The versioned descriptor shape should begin as:

~~~json
{
  "schemaVersion": "1",
  "instanceId": "random-per-launch-id",
  "server": {
    "id": "com.stevemurr.filesearch",
    "name": "File Search",
    "version": "1.0.0"
  },
  "mcp": {
    "transport": "streamable-http",
    "endpoint": "/mcp",
    "protocolVersions": ["2025-11-25"],
    "authentication": "pairing"
  },
  "capabilities": {
    "tools": true
  }
}
~~~

Descriptor readers must ignore unknown fields. Breaking descriptor changes require a new schemaVersion and compatibility tests.

### Trust and authorization

- DECIDED: Discovery may auto-populate a UI list, but a consumer must not invoke tools before user-approved pairing.
- DECIDED: Pairing approval occurs in the producer app so the user knows which app is granting access.
- DECIDED: A successful pairing creates a random, per-consumer bearer credential.
- DECIDED: This pairing bootstrap is a LocalMCPKit extension, not the MCP 2025-11-25 OAuth authorization protocol. V1 automatic pairing interoperates only with LocalMCPKit consumers.
- DECIDED: A generic MCP client may connect when a user explicitly provisions a distinct bearer credential for it through producer-owned UI or tooling. Do not fall back to one shared token for every generic client.
- DECIDED: Producer and consumer credentials are stored in Keychain-backed stores in real apps. Tests use in-memory stores.
- DECIDED: The producer exposes revocation and credential rotation operations to its host app.
- INVARIANT: Authentication is checked on every MCP request before dispatch.
- INVARIANT: Missing, invalid, revoked, or expired authorization never reaches a command handler.
- INVARIANT: Secrets never appear in DNS-SD, descriptors, UserDefaults, logs, error descriptions, analytics, or copied diagnostic bundles.
- INVARIANT: Pairing endpoints are loopback-only, rate-limited, short-lived, and safe under concurrent requests.

The exact pairing HTTP exchange and user-verification presentation are OPEN. Document them in Spec/local-discovery-v1.md before implementing network pairing. A safe baseline is:

1. Consumer creates a pairing request containing a display name and a random request nonce.
2. Producer presents a local approval prompt with the consumer name and a short verification code.
3. Approval is tied to the pending request and expires quickly.
4. Producer returns a newly minted credential only on that request's loopback connection.
5. Both sides store the grant under the stable producer ID and consumer identity.
6. Revocation immediately invalidates subsequent MCP calls.

Do not use a constant shared token for all consumers.

Full standards-based authorization for generic clients is a separate option. If implemented, follow the MCP HTTP authorization profile and RFC 9728 protected-resource metadata rather than presenting the custom pairing flow as OAuth.

### HTTP security

- INVARIANT: Validate Host and Origin before authentication and dispatch.
- INVARIANT: Reject hostile or unexpected Origin values with a fail-closed policy. Follow the MCP Streamable HTTP security requirements.
- INVARIANT: Never bind 0.0.0.0, ::, a LAN address, or a hostname-resolved interface.
- INVARIANT: Apply request body limits, command input limits, timeouts, and cancellation.
- INVARIANT: start and stop are idempotent. Partial startup failure leaves no listener, DNS-SD registration, task, or credential exchange active.
- INVARIANT: Stopping the producer removes its advertisement before or while the listener stops; stale discovery must converge quickly.
- INVARIANT: Do not log authorization headers or full command payloads by default.

### Reuse boundary

- DECIDED: This repository contains generic infrastructure only.
- DECIDED: Producer apps provide identities, command schemas, handlers, approval UI callbacks, and lifecycle integration.
- DECIDED: Consumer apps provide UI, trust decisions, and their policy for which tools an LLM may see or call.
- DECIDED: Discovery backends implement protocols so non-Apple platforms can be added later.
- DECIDED: File Search remains a consuming application of this package, not the home of the infrastructure.

## Intended package structure

The first implementation should replace the generated umbrella target with focused modules. Small changes to names are acceptable if dependency direction remains clear.

~~~
LocalMCPKit/
├── Package.swift
├── Sources/
│   ├── LocalMCPContracts/
│   ├── LocalMCPDiscovery/
│   ├── LocalMCPDiscoveryBonjour/
│   ├── LocalMCPMCPAdapter/
│   ├── LocalMCPProducer/
│   ├── LocalMCPConsumer/
│   ├── LocalMCPTesting/
│   └── local-mcp/
├── Tests/
│   ├── LocalMCPContractsTests/
│   ├── LocalMCPDiscoveryTests/
│   ├── LocalMCPProducerTests/
│   ├── LocalMCPConsumerTests/
│   └── LocalMCPIntegrationTests/
├── Examples/
│   ├── ExampleProducer/
│   └── ExampleConsumer/
├── Spec/
│   └── local-discovery-v1.md
├── Docs/
│   ├── architecture.md
│   ├── security.md
│   └── integration.md
└── HANDOFF.md
~~~

Intended public products:

- LocalMCPContracts
- LocalMCPDiscovery
- LocalMCPDiscoveryBonjour
- LocalMCPProducer
- LocalMCPConsumer
- LocalMCPTesting
- local-mcp executable

Dependency direction:

~~~
LocalMCPContracts
    ↑
LocalMCPDiscovery
    ↑
LocalMCPDiscoveryBonjour

LocalMCPContracts ← LocalMCPMCPAdapter
LocalMCPContracts + LocalMCPDiscovery + LocalMCPMCPAdapter ← LocalMCPProducer
LocalMCPContracts + LocalMCPDiscovery + LocalMCPMCPAdapter ← LocalMCPConsumer
all public layers ← LocalMCPTesting
LocalMCPConsumer + LocalMCPDiscoveryBonjour ← local-mcp
~~~

Avoid cycles. Keep the SDK adapter internal unless a concrete reason requires a product.

## Core contract types

Start with small Sendable and Codable value types where wire representation is involved:

- ProducerIdentity
  - stableID
  - displayName
  - version
- ProducerInstance
  - identity
  - instanceID
  - endpoint
  - descriptorURL
- ProducerDescriptor
  - schemaVersion
  - instanceID
  - server identity
  - MCP transport and protocol versions
  - capability summary
- DiscoveryEvent
  - added
  - updated
  - removed
- CommandDefinition
  - stable name
  - title and description
  - explicit JSON input schema
  - optional explicit output schema
  - annotations
- CommandAnnotations
  - readOnly
  - idempotent
  - destructive
  - openWorld
- CommandContext
  - consumer identity/grant ID
  - cancellation
  - deadline
  - trace/request ID
- CommandResult
  - structured JSON-compatible content
  - human/LLM-readable text fallback
  - error state mapped to MCP
- PairingRequest
- AuthorizationGrant
- DiscoveryProfileVersion and compatibility policy

Use stable primitives at module boundaries. Do not leak AppKit, SwiftUI, SQLite, MCP SDK, NIO, or app model types.

## API direction

The exact signatures are not frozen, but the usage should remain close to this:

~~~swift
let producer = LocalMCPProducer(
    identity: ProducerIdentity(
        stableID: "com.example.notes",
        displayName: "Notes",
        version: "1.0.0"
    ),
    configuration: .localOnly(),
    transport: producerTransport,
    advertiser: localOnlyAdvertiser,
    grantStore: producerGrantStore,
    approval: approvalController
)

try await producer.register(
    CommandDefinition(
        name: "notes.search",
        description: "Search authorized note metadata",
        inputSchema: SearchNotesInput.schema,
        outputSchema: SearchNotesOutput.schema,
        annotations: .init(readOnly: true, idempotent: true)
    )
) { (input: SearchNotesInput, context: CommandContext) in
    let output = try await notes.search(input, context: context)
    return CommandResult.structured(output, text: output.summary)
}

try await producer.start()
~~~

Consumer direction:

~~~swift
let discovery = BonjourLocalMCPDiscovery()

for await event in await discovery.events() {
    switch event {
    case .added(let instance):
        // Display as discovered, not trusted.
        break
    case .updated(let instance):
        break
    case .removed(let instanceID):
        break
    }
}

let client = LocalMCPConsumer(
    instance: selectedInstance,
    identity: consumerIdentity,
    connector: connector,
    grantStore: consumerGrantStore
)
let grant = try await client.pair { verificationCode in
    verificationPresenter.show(verificationCode)
}
let tools = try await client.listTools(grant: grant)
let result: SearchNotesOutput = try await client.call(
    "notes.search",
    input: SearchNotesInput(query: "roadmap"),
    as: SearchNotesOutput.self,
    grant: grant
)
~~~

Required API qualities:

- Swift concurrency-native.
- Sendable under strict concurrency checking.
- Typed convenience APIs without preventing schema-first/dynamic consumers.
- Deterministic command ordering.
- Explicit lifecycle and observable state.
- Dependency injection for discovery, transport, clock, randomness, credential store, and approval.
- Useful errors without leaking secrets.

## Lifecycle model

Producer startup order:

1. Validate immutable local-only configuration.
2. Prepare command registry and authentication middleware.
3. Start the HTTP listener on loopback.
4. Determine the actual ephemeral port.
5. Expose the descriptor and pairing endpoints.
6. Register the DNS-SD LocalOnly service.
7. Publish running status.

Producer shutdown order:

1. Withdraw DNS-SD registration.
2. Stop accepting new pairing and MCP requests.
3. Cancel or drain requests according to a bounded policy.
4. Close the listener.
5. Publish stopped status.

Consumer behavior:

- Browsing is long-lived and cancellation-aware.
- Deduplicate by instance ID, not display name.
- Treat process restart as a removed old instance and added new instance.
- Preserve trust by stable producer ID only when the stored grant is still accepted by the new instance.
- Reconnect with bounded backoff; do not spin on a vanished producer.
- Surface incompatible descriptors distinctly from offline producers.

## Error model

Define stable LocalMCPKit errors and adapt framework errors internally. At minimum distinguish:

- invalidConfiguration
- bindFailed
- advertisementFailed
- incompatibleDiscoveryProfile
- incompatibleMCPProtocol
- producerUnavailable
- pairingRequired
- pairingDenied
- pairingExpired
- unauthorized
- grantRevoked
- invalidCommandInput
- commandNotFound
- commandFailed with sanitized context
- requestTimedOut
- cancelled

Transport details and secrets must not appear in user-facing descriptions unless explicitly redacted and marked diagnostic.

## Testing strategy

Build the system test-first around injected boundaries.

Unit tests:

- Contract Codable round trips and forward-compatible descriptor decoding.
- Command registration, duplicate names, deterministic listing, typed decode/encode, and error mapping.
- Discovery event deduplication and add/update/remove transitions.
- Pairing expiry, denial, issuance, revocation, and rotation.
- Host/Origin validation.
- Request limits, cancellation, timeout, redaction, and idempotent start/stop.
- Cleanup after failure at every startup stage.

In-memory vertical slice:

- In-memory discovery advertiser/browser.
- In-memory credential store and approval.
- Producer registers echo command.
- Consumer discovers producer, pairs, lists tools, calls echo, revokes grant, and observes rejection.

Network integration tests:

- Bind an ephemeral 127.0.0.1 port.
- Under the 2025-11-25 baseline, perform initialize, notifications/initialized, tools/list, and tools/call in that order.
- Confirm missing/wrong/revoked credentials are rejected before dispatch.
- Confirm hostile Origin and Host are rejected.
- Confirm wildcard binding is impossible through public configuration.
- Confirm stopping releases the port and withdraws discovery.

Bonjour tests:

- Prefer protocol-level fakes for deterministic unit tests.
- Add a macOS integration test that registers and browses with LocalOnly and verifies the reported interface index.
- Never make LAN visibility a test prerequisite.

ACCEPTANCE: swift test passes from a clean checkout, with no required GUI interaction and no listener left behind.

## Implementation sequence

### Phase 0: Repository and decisions — COMPLETE

1. Choose the minimum Swift tools version and macOS deployment target.
2. Add the target/product skeleton and strict concurrency settings.
3. Add Spec/local-discovery-v1.md, Docs/architecture.md, and Docs/security.md.
4. Record exact dependency pins and why they are isolated.
5. Add CI for swift build and swift test on macOS.

Exit criterion: the package graph builds with placeholder modules and the local discovery profile is written down.

### Phase 1: Contracts and in-memory vertical slice — COMPLETE

1. Implement shared value types and compatibility rules.
2. Implement command registry and type erasure.
3. Implement discovery and credential-store protocols.
4. Implement in-memory producer/consumer/discovery/authorization test doubles.
5. Complete the echo discovery-pair-list-call-revoke test.

Exit criterion: the architecture works without sockets, Bonjour, Keychain, or an external MCP SDK.

### Phase 2: MCP and loopback HTTP

1. Re-check the latest ratified MCP version, its lifecycle/transport rules, and official Swift SDK support. Record the decision.
2. Add the exact-pinned official Swift MCP SDK behind LocalMCPMCPAdapter if its supported version matches the selected baseline.
3. Select and isolate the HTTP listener implementation.
4. Implement the selected Streamable HTTP behavior at /mcp without mixing protocol-version semantics.
5. Enforce loopback bind, Host/Origin policy, authentication, body limits, timeout, cancellation, and redacted logging.
6. Add real lifecycle/list/call integration tests. For the 2025-11-25 baseline, include notifications/initialized.

Exit criterion: an authenticated local consumer can complete the MCP lifecycle over an ephemeral loopback port.

Use injected, pre-issued in-memory grants for Phase 2 tests until Phase 4 implements the user pairing bootstrap. Do not expose an unpaired listener in examples, and do not publish or tag a network-capable build while authentication is bypassable.

### Phase 3: macOS LocalOnly discovery

1. Wrap DNSServiceRegister, DNSServiceBrowse, DNSServiceResolve, and TXT handling behind Sendable actors/protocols.
2. Use kDNSServiceInterfaceIndexLocalOnly explicitly.
3. Implement descriptor fetch and compatibility validation.
4. Verify add/update/remove behavior and cleanup.

Exit criterion: a second local process discovers a producer automatically, while another machine on the LAN cannot.

### Phase 4: Pairing and secure persistence

1. Finalize the versioned pairing exchange in the discovery spec.
2. Implement producer approval callbacks and per-consumer grants.
3. Add Keychain-backed stores and revocation/rotation.
4. Add rate limiting and pairing expiration.

Exit criterion: discovery is automatic, invocation requires explicit trust, and credentials survive app restart without plaintext storage.

### Phase 5: Developer experience

1. Add the local-mcp diagnostic CLI.
2. Add example producer and consumer executables/apps.
3. Write integration, entitlement, troubleshooting, and migration docs.
4. Exercise the package from outside its own test targets.

Exit criterion: another app can integrate from documentation alone.

### Phase 6: File Search integration

Integrate this package into the sibling File Search app only after the generic vertical slice is stable.

The first command is DECIDED as files.search.

Proposed input:

~~~json
{
  "query": "quarterly report",
  "scope": "all_indexed",
  "limit": 25
}
~~~

Stable scope values:

- all_indexed
- home
- icloud

Use a bounded limit with a proposed default of 25 and hard maximum of 100. Decide and test maximum query length and empty-query semantics before shipping.

Return structured results plus a JSON/text fallback using stable primitives only:

- name
- file URI or path, subject to the app's privacy policy
- content type
- isDirectory
- byte size when known
- ISO-8601 created and modified timestamps when known

Integration invariants:

- Query FileIndexDatabase directly through a small Sendable FileIndexQuerying protocol.
- Do not route MCP requests through the MainActor, debounced FileIndexService used by UI state.
- Do not open a second index process or bypass the app's existing security-scoped folder access.
- Expose metadata only in V1: no file contents, open, reveal, delete, move, rebuild, or arbitrary path operations.
- Add the macOS app-sandbox network-server entitlement for the producer and the appropriate client entitlement for consumers.
- Compose lifecycle in AppDependencies: start after index/search startup and stop MCP before releasing indexed-folder access.

Useful File Search seams:

- Sources/Search/FileIndexDatabase.swift: direct actor query implementation; search begins near line 137 in the current sibling checkout.
- Sources/Search/FileIndexService.swift: UI orchestration that should not be used as the RPC boundary.
- Sources/App/AppDelegate.swift: AppDependencies composition and lifecycle.
- Sources/Model/FileSearchResult.swift: app model that should be mapped to wire DTOs, not exported from this package.
- project.yml: source of Xcode project configuration and entitlements.

### Phase 7: Second producer

Before declaring a 1.0 API, integrate a second small producer that is not file search. Use the friction found there to simplify the public API and prove the package is genuinely reusable.

## Open decisions

Resolve these with small ADRs or explicit sections in the relevant documentation:

1. Minimum Swift tools version and supported macOS version.
2. Exact official MCP Swift SDK pin at implementation time.
3. HTTP listener library: evaluate SwiftNIO directly versus a thin server framework; keep it internal either way.
4. Exact Host allowlist and treatment of absent Origin for native clients.
5. Pairing endpoint paths, messages, verification-code behavior, expiry, and rate limits.
6. Consumer identity representation and Keychain access-group strategy.
7. Whether descriptor and pairing endpoints share /mcp or use separate /local-mcp/v1 paths.
8. Whether the package ships umbrella convenience products in addition to focused modules.
9. File Search empty-query behavior, maximum query length, and whether paths or only file URIs are returned.
10. Minimum operator UI required in producer apps for enable/disable, approval, revoke, status, and diagnostics.

Do not reopen these settled choices without concrete evidence:

- Separate reusable repository.
- In-process producer server.
- Streamable HTTP primary transport.
- Strict loopback listener.
- LocalOnly DNS-SD discovery.
- Discovery does not imply trust.
- Per-consumer authorization.
- Generic package has no File Search dependencies.

## Definition of done for V1

All of the following are required:

- The focused package products build with strict concurrency checking.
- Public APIs have documentation and contain no SDK/framework leakage.
- A producer can register typed commands and start/stop idempotently.
- A consumer automatically receives producer add/update/remove events.
- The user can approve pairing, after which only that consumer can call tools.
- The selected MCP lifecycle works over authenticated Streamable HTTP. Under 2025-11-25 this includes initialize, notifications/initialized, tools/list, and tools/call.
- LocalOnly discovery is verified on macOS.
- Malicious Origin, Host, missing token, wrong token, revoked token, oversized request, timeout, and cancellation paths are tested.
- Secrets are Keychain-backed and absent from logs, TXT records, descriptors, and UserDefaults.
- The diagnostic CLI and two minimal examples work.
- File Search exposes bounded, read-only files.search metadata queries through the package.
- A second producer validates reuse before API 1.0.
- swift build and swift test pass from a clean checkout.
- Integration and security documentation is sufficient for a new app without tribal knowledge.

## Commands for the next task

From the LocalMCPKit repository:

~~~sh
cd path/to/local-mcp-kit
git status --short --branch
swift --version
swift package describe
swift build
swift test
~~~

Before editing, inspect the generated baseline and confirm the sibling File Search repository is not being modified during generic package phases.

Recommended next implementation request:

> Read HANDOFF.md completely. Implement Phase 2 of LocalMCPKit without changing the Phase 1 public boundaries. Re-check the latest ratified MCP specification and official Swift SDK support first, record exact dependency pins, implement authenticated loopback Streamable HTTP, and add the real negotiated lifecycle/list/call security integration suite. Use injected pre-issued grants; do not expose an unpaired listener or begin Phase 4 network pairing.

## Primary references

- MCP 2025-11-25 transport specification: https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
- MCP 2025-11-25 lifecycle: https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle
- MCP 2025-11-25 authorization: https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization
- MCP schema: https://modelcontextprotocol.io/specification/2025-11-25/schema
- Official Swift SDK: https://github.com/modelcontextprotocol/swift-sdk
- Official SDK tiers: https://modelcontextprotocol.io/docs/sdk
- 2026-07-28 release-candidate overview: https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/
- Official MCP Registry scope: https://modelcontextprotocol.io/registry/about
- Apple LocalOnly DNS-SD documentation: https://developer.apple.com/documentation/dnssd/kdnsserviceinterfaceindexlocalonly
- DNS-SD service-name rules: https://www.rfc-editor.org/rfc/rfc6763.html
- IANA service registry showing mcp assigned to Matrix Configuration Protocol: https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml?search=matrix

## Handoff note

The prior planning conversation is not required once this document is present. If implementation evidence contradicts a decision, update this document or add an ADR in the same change. Keep current status and completed phase markers accurate so another agent can resume without reconstructing history.
