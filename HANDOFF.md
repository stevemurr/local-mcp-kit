# LocalMCPKit Agent Handoff

Status: Generic V1 Phases 0–5 and reusable second-producer Phase 7 implemented; Phase 6 File Search integration is staged in the sibling checkout and undergoing final validation
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

The package graph, contracts, in-memory producer/consumer stack, production HTTP/MCP runtime, real Bonjour LocalOnly backend, explicit network pairing, Keychain stores, read-only CLI, separate-process fixture, deterministic test doubles, and one-consumer/two-producer SwiftUI example are implemented. The sibling File Search integration is staged and being applied/validated separately so no File Search or AppKit type enters this package.

## Current repository state

The repository is published from branch `main`. Generic implementation stays in this repository. The sibling File Search checkout is the first host-app integration and is tracked separately.

Current implementation facts:

- Package.swift now requires Swift tools/language mode 6.0 and macOS 13.
- The focused public products and internal MCP adapter target build with strict concurrency.
- There are no external package dependencies. The official MCP Swift SDK 0.12.1 was evaluated and not adopted because it requires Swift tools 6.1 and declares a moving DocC dependency.
- Shared contracts, a typed command registry, replaying discovery catalog, pairing/grant authorization, producer lifecycle, negotiated consumer lifecycle, and in-memory testing support are implemented.
- Credentials are opaque/redacted; producer stores receive only SHA-256 token digests.
- The internal wire adapter and listener implement the ratified MCP 2025-11-25 lifecycle: initialize, notifications/initialized, tools/list, tools/call, per-bearer sessions, explicit cancellation, and termination over authenticated numeric-loopback HTTP.
- The real Bonjour backend uses `kDNSServiceInterfaceIndexLocalOnly` for registration, browsing, resolution, and callback acceptance, then loads bounded descriptors only from synthesized `127.0.0.1` URLs.
- Network pairing is explicit, producer-approved, short-lived, replay/rate/concurrency protected, and persisted in separate producer/consumer Keychain stores. Tests use injected stores and never touch the developer Keychain.
- Persisted grants are never sent automatically to a replacement instance; stable-ID matching is lookup metadata only and fresh explicit producer approval/rebinding is required.
- The CLI is read-only. The separate-process executables exercise production HTTP, MCP, and Bonjour using an explicit owner-only development rendezvous grant for unattended tests.
- The SwiftUI one-consumer/two-producer example is implemented with a VM-only XCUI suite. Final build/test, VM, and CI evidence is recorded only after the current integration run completes; do not infer counts from the historical 128-test Phase 1 snapshot.
- No software license has been selected. Do not add one without an explicit owner decision.

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
- ACCEPTANCE means required evidence for completion.

### Protocol and transport

- DECIDED: V1 targets the ratified MCP 2025-11-25 specification.
- DECIDED: Use Streamable HTTP as the producer transport because the server lives inside an already-running GUI app and must support multiple consumers.
- DECIDED: Keep lifecycle, session, headers, and version behavior behind an adapter. Under 2025-11-25, a client must send notifications/initialized after initialize and before normal operation.
- DECIDED: The 2026-07-28 draft is intentionally incompatible: it removes initialize/notifications/initialized and Mcp-Session-Id, moves version, identity, and capabilities into per-request metadata, adds mandatory server/discover, and changes modern Streamable HTTP to POST-only requests with routing headers. Never combine the implemented 2025-11-25 lifecycle with those newer transport semantics.
- DECIDED: Bind to 127.0.0.1 only. Use an ephemeral port by default and advertise the resolved port.
- DECIDED: Use one relative MCP endpoint path, initially /mcp.
- DECIDED: A future stdio helper should proxy to the authenticated loopback endpoint rather than start a second copy of app logic or data access.
- INVARIANT: Neither preferences nor malformed configuration may cause a wildcard, LAN, or public bind.
- INVARIANT: The public package API must not expose types from a pre-1.0 MCP SDK or the chosen HTTP framework.

The official Swift SDK 0.12.1 was evaluated for V1. It implements MCP 2025-11-25, but requires Swift tools 6.1 and declares a moving DocC dependency; its StatelessHTTPServerTransport also does not supply the required listening socket/session boundary. LocalMCPKit keeps its Swift tools 6.0 floor and zero external dependencies by implementing the required wire behavior and Network.framework HTTP/1.1 listener inside `LocalMCPMCPAdapter`. Protocol conformance is tested at that internal boundary. Re-evaluate the official SDK after a future ratified MCP release, but do not leak it through public declarations.

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
auth=pair-channel
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
    "transport": "localmcp-secure-http",
    "endpoint": "/mcp",
    "protocolVersions": ["2025-11-25"],
    "authentication": "pairing-channel"
  },
  "capabilities": {
    "tools": true
  },
  "channelBinding": {
    "suite": "x25519-hkdf-sha256-chacha20poly1305-v1",
    "publicKey": "base64url-encoded-per-process-x25519-public-key"
  }
}
~~~

The `localmcp-secure-http` transport runs the MCP 2025-11-25 lifecycle inside a LocalMCP encrypted loopback envelope; it is not generic plaintext Streamable HTTP. The bearer, session, and protocol headers and the JSON-RPC body travel only inside the sealed payload.

Descriptor readers must ignore unknown fields. Breaking descriptor changes require a new schemaVersion and compatibility tests.

### Trust and authorization

- DECIDED: Discovery may auto-populate a UI list, but a consumer must not invoke tools before user-approved pairing.
- DECIDED: Pairing approval occurs in the producer app so the user knows which app is granting access.
- DECIDED: A successful pairing creates a random, per-consumer bearer credential.
- DECIDED: This pairing bootstrap is a LocalMCPKit extension, not the MCP 2025-11-25 OAuth authorization protocol. V1 automatic pairing interoperates only with LocalMCPKit consumers.
- DECIDED: A generic MCP client may connect when a user explicitly provisions a distinct bearer credential for it through producer-owned UI or tooling. Do not fall back to one shared token for every generic client.
- DECIDED: Producer and consumer credentials are stored in Keychain-backed stores in real apps. Tests use in-memory stores.
- DECIDED: The producer exposes revocation and credential rotation operations to its host app.
- DECIDED: Stored consumer credentials are never sent automatically to a materially changed or replacement producer instance. A fresh explicit producer approval/rebinding is required before bearer disclosure.
- INVARIANT: Authentication is checked on every MCP request before dispatch.
- INVARIANT: Missing, invalid, revoked, or expired authorization never reaches a command handler.
- INVARIANT: Secrets never appear in DNS-SD, descriptors, UserDefaults, logs, error descriptions, analytics, or copied diagnostic bundles.
- INVARIANT: Pairing endpoints are loopback-only, rate-limited, short-lived, and safe under concurrent requests.

The pairing HTTP exchange and human-verification presentation are implemented as specified in `Spec/local-discovery-v1.md`:

1. Consumer creates a versioned pairing request containing its claimed identity and a random 32-byte request nonce.
2. Producer presents a local approval prompt with the consumer name and a short verification code.
3. Approval is tied to the pending request, expires after at most 120 seconds, and is protected by nonce replay, concurrency, and rolling rate limits.
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

## Package structure

The generated umbrella target was replaced with focused modules. Dependency direction remains cycle-free.

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
│   ├── SeparateProcess/
│   └── TwoProducers/
├── Spec/
│   └── local-discovery-v1.md
├── Docs/
│   ├── architecture.md
│   ├── security.md
│   └── integration.md
└── HANDOFF.md
~~~

Public library and executable products:

- LocalMCPContracts
- LocalMCPDiscovery
- LocalMCPDiscoveryBonjour
- LocalMCPProducer
- LocalMCPConsumer
- LocalMCPTesting
- local-mcp executable
- local-mcp-example-producer executable
- local-mcp-example-consumer executable
- local-mcp-two-producers-example executable

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
LocalMCPContracts + LocalMCPDiscovery + LocalMCPDiscoveryBonjour ← local-mcp
~~~

Avoid cycles. Keep the wire/listener adapter internal unless a concrete reason requires a product.

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
- Use a stable producer ID only to locate stored metadata; after an instance change, require fresh explicit producer approval/rebinding before sending a bearer.
- The host may retry transient connections with bounded cancellable backoff while the instance remains discovered; `LocalMCPConsumer` does not start background retries and removal must stop host retry.
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

### Phase 2: MCP and loopback HTTP — COMPLETE

1. Ratified MCP 2025-11-25 and official Swift SDK support were re-checked.
2. SDK 0.12.1 was rejected because it requires Swift tools 6.1 and declares a moving DocC dependency; the isolated adapter has no external dependency.
3. The internal Network.framework HTTP/1.1 listener binds numeric `127.0.0.1`; port zero selects an ephemeral port.
4. `/mcp` implements the 2025-11-25 lifecycle, sessions, `notifications/cancelled`, and termination without mixing later draft semantics.
5. Exact Host, absent-Origin, bearer-before-dispatch, header/body/response/concurrency/session limits, timeout, disconnect cancellation, and cleanup policies are enforced.
6. Real lifecycle/list/call and hostile-request integration coverage exercises the listener.

Exit criterion: an authenticated local consumer can complete the MCP lifecycle over an ephemeral loopback port.

The unattended separate-process fixture uses an explicit owner-only pre-issued development grant mode. Shipping composition uses the implemented pairing route and Keychain stores; no production example exposes an unauthenticated listener.

### Phase 3: macOS LocalOnly discovery — COMPLETE

1. Wrap DNSServiceRegister, DNSServiceBrowse, DNSServiceResolve, and TXT handling behind Sendable actors/protocols.
2. Use kDNSServiceInterfaceIndexLocalOnly explicitly.
3. Implement descriptor fetch and compatibility validation.
4. Verify add/update/remove behavior and cleanup.

Exit criterion: a second local process discovers a producer automatically, while another machine on the LAN cannot.

### Phase 4: Pairing and secure persistence — COMPLETE

1. Finalize the versioned pairing exchange in the discovery spec.
2. Implement producer approval callbacks and per-consumer grants.
3. Add Keychain-backed stores and revocation/rotation.
4. Add rate limiting and pairing expiration.

Exit criterion: discovery is automatic, invocation requires explicit trust, credentials persist through Keychain without producer-side plaintext storage, and instance changes still require explicit rebinding before bearer disclosure.

### Phase 5: Developer experience — COMPLETE

1. Add the local-mcp diagnostic CLI.
2. Add example producer and consumer executables/apps.
3. Write integration, entitlement, troubleshooting, and migration docs.
4. Exercise the package from outside its own test targets.

Exit criterion: another app can integrate from documentation alone.

### Phase 6: File Search integration — COMPLETE

The sibling File Search checkout consumes this package as a remote dependency pinned to a published revision of this repository; its unit/integration suites and VM-only UI suite validate `files.search` over the real encrypted HTTP consumer/producer path.

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

`query` is at most 512 characters. Empty or whitespace-only input deliberately delegates to the existing database policy and returns the most recently modified indexed items. `limit` defaults to 25 and has a hard maximum of 100.

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

### Phase 7: Second producer — COMPLETE

The one-consumer/two-producer SwiftUI example hosts independent Greeter (`greeting.hello`) and Calculator (`math.add`) producers, separate sessions, and isolated grants. The separate-process echo producer provides an additional production HTTP/Bonjour reuse check.

## Resolved V1 decisions

1. Swift tools/language mode 6.0 and macOS 13.
2. No external MCP SDK pin; SDK 0.12.1 was evaluated and rejected for its Swift tools 6.1 floor and moving DocC dependency.
3. The internal listener uses Network.framework and package-owned HTTP values.
4. The only accepted authority is exact `127.0.0.1:<bound-port>`; absent Origin is allowed and every present Origin is rejected.
5. Descriptor and pairing use separate versioned `/local-mcp/v1` routes; pairing is a channel-bound commitment → challenge → reveal exchange with a 32-byte nonce, an eight-character (40-bit) verification code, 120-second expiry, three concurrent requests, five starts per rolling minute, and ten-minute initiation replay memory.
6. Consumer identity is a stable app ID plus random per-installation UUID. Keychain access groups are nil by default and opt-in only when the embedding app is entitled.
7. The package ships focused products rather than an umbrella product.
8. A persisted grant is never sent automatically to a replacement instance. Fresh producer approval/rebinding is the V1 endpoint-authenticity policy.
9. File Search allows empty/whitespace queries (most recently modified indexed items), rejects over-512-character queries, defaults to 25/caps at 100, accepts `all_indexed`, `home`, and `icloud`, and returns metadata-only result DTOs chosen by that app's privacy policy.
10. Shipping producer UI includes enable/disable, lifecycle status, explicit approval, grant list/revoke, and redacted diagnostics.

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

Implemented evidence available in source and focused tests:

- Focused strict-concurrency products and package-owned public APIs with no MCP SDK/Network.framework leakage.
- Typed command registration, supported JSON Schema validation, deterministic listing, idempotent producer lifecycle, and authorization-before-dispatch.
- Replaying add/update/remove discovery and a real DNS-SD LocalOnly backend.
- Explicit producer approval, per-consumer grants, rotation/revocation, nonce replay/expiry/rate limits, and separate device-only Keychain stores.
- Authenticated MCP 2025-11-25 initialize, notifications/initialized, tools/list, tools/call, session termination, cancellation, and disconnect behavior over numeric-loopback HTTP.
- Exact Host/Origin policy, wrong/missing/revoked bearer rejection, request/response/concurrency/session bounds, timeout, and cleanup paths.
- Read-only diagnostic CLI, separate-process producer/consumer executables, and a one-consumer/two-producer SwiftUI example.
- Security, architecture, integration, entitlement, and troubleshooting documentation.

Final release evidence still to record after the active validation run, without substituting historical counts:

- exact clean `swift build` and `swift test` results;
- macOS LocalOnly system-integration result;
- Tart VM XCUI result;
- sibling File Search build/tests for bounded metadata-only `files.search`;
- GitHub Actions result for the implementation commit; and
- confirmation that the final host example build launches successfully.

## Resume and verification commands

From the LocalMCPKit repository:

~~~sh
cd path/to/local-mcp-kit
git status --short --branch
swift --version
swift package describe
swift build
swift test
~~~

Also run the separate-process integration and VM-only UI workflow before release:

~~~sh
swift test --filter SeparateProcess
Scripts/run-ui-tests.sh
~~~

The current continuation task is final validation, not a new protocol phase: finish the sibling File Search application build/tests, run the clean package and VM suites, launch the host example for inspection, and record the immutable commit/CI evidence above. UI automation must run in the VM, never against the host desktop.

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
