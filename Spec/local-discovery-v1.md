# LocalMCPKit local discovery profile, version 1

Status: normative V1 discovery profile; the pairing exchange is a Phase 4 baseline and is not a Phase 1 network requirement. Network reuse of persisted grants is subject to the producer-authenticity decision gate in [the security model](../Docs/security.md#phase-4-decision-gate-producer-endpoint-authenticity).

This document defines how a LocalMCPKit producer advertises a live, same-Mac MCP endpoint and how a consumer turns that advertisement into an untrusted producer instance. It also reserves the V1 descriptor and pairing HTTP contracts. It does not make discovery proof of identity or permission to invoke a tool.

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are to be interpreted as requirements for this profile.

## Profile constants

| Item | V1 value |
| --- | --- |
| DNS-SD service type | `_appmcp._tcp` |
| DNS-SD interface | `kDNSServiceInterfaceIndexLocalOnly` |
| TXT profile version | `1` |
| MCP endpoint | `/mcp` |
| Descriptor endpoint | `/local-mcp/v1/descriptor.json` |
| Pairing endpoint | `/local-mcp/v1/pairing-requests` |
| Authentication mode | `pair` in TXT; `pairing` in JSON |
| MCP transport | `streamable-http` |
| Initial MCP protocol version | `2025-11-25` |
| Address constructed by consumers | IPv4 loopback, `127.0.0.1` |

These constants are centralized by the implementation. In particular, `_mcp._tcp` MUST NOT be used because `mcp` is already assigned by IANA to another protocol.

## Security model

DNS-SD presence answers only “a process claims to be available.” Every field in an advertisement and descriptor is attacker-controlled until a producer-side user approves pairing and a later MCP request authenticates with the resulting grant.

A conforming implementation:

- MUST register, browse, resolve, and process callbacks only on `kDNSServiceInterfaceIndexLocalOnly`;
- MUST bind and connect only to `127.0.0.1` in V1;
- MUST ignore the SRV target hostname and construct URLs from `127.0.0.1`, the resolved SRV port, and a validated profile path;
- MUST NOT put credentials, nonces, verification codes, file paths, command names, tool schemas, arguments, results, or user data in DNS-SD or the descriptor;
- MUST NOT invoke MCP methods as a consequence of discovery;
- MUST validate the HTTP `Host`/`:authority` and `Origin` policy in [the security guide](../Docs/security.md) on descriptor, pairing, and MCP routes; and
- MUST treat redirects, non-loopback URLs, and identity mismatches as failures rather than following or repairing them.

## DNS-SD advertisement

### Registration and browsing

The producer registers one `_appmcp._tcp` service for each live process listener. Registration and browsing MUST pass `kDNSServiceInterfaceIndexLocalOnly` explicitly; an unspecified, “any,” or dynamically selected interface is non-conforming.

The service instance label is presentation-only. Consumers MUST NOT use it as a stable identity, deduplication key, or authorization key. The SRV record supplies only the actual listener port. The port MUST be nonzero.

The producer withdraws the registration before, or concurrently with, stopping the listener. Consumers must still handle stale records and failed descriptor fetches because process termination can be abrupt.

### TXT record

A V1 producer advertises exactly these required keys:

```text
v=1
id=com.example.notes
path=/mcp
desc=/local-mcp/v1/descriptor.json
auth=pair
```

Rules:

- Keys are lowercase ASCII and MUST occur at most once.
- `v` MUST be the exact ASCII string `1`.
- `id` MUST satisfy the stable identifier rules below.
- `path` MUST be `/mcp` in V1.
- `desc` MUST be `/local-mcp/v1/descriptor.json` in V1. It names this profile's descriptor, not an experimental MCP Server Card or Registry manifest.
- `auth` MUST be `pair` in V1.
- A producer SHOULD emit only the five required keys. The complete encoded TXT record MUST NOT exceed 512 bytes.
- Readers MUST ignore unknown keys so additive profile metadata remains possible.
- A missing, duplicate, malformed, or unsupported required value makes the record incompatible. It MUST NOT become an available producer instance.

TXT data is not authenticated. Matching TXT values to descriptor values detects inconsistency; it does not establish trust or prove that a newly launched endpoint is the producer paired previously.

### Stable producer identifier

The stable producer identifier is an app-supplied, release-stable reverse-DNS identifier. It is also the authorization namespace for grants. V1 identifiers:

- contain 3 through 253 ASCII characters;
- contain at least two dot-separated labels;
- use lowercase `a`–`z`, digits, and hyphens only within labels;
- start and end each label with a letter or digit; and
- are compared byte-for-byte, with no implicit case folding or normalization.

Changing this identifier intentionally creates a different producer identity and does not inherit grants.

## Resolving a producer

For a compatible TXT record and SRV port `P`, a consumer constructs:

```text
descriptor URL = http://127.0.0.1:P/local-mcp/v1/descriptor.json
MCP URL        = http://127.0.0.1:P/mcp
pairing URL    = http://127.0.0.1:P/local-mcp/v1/pairing-requests
```

The consumer MUST NOT substitute `localhost`, an IPv6 address, the SRV target, a TXT-provided hostname, or a host obtained through name resolution. The consumer MUST NOT follow an HTTP redirect while fetching the descriptor.

The descriptor request is an unauthenticated `GET` with an `Accept: application/json` header and no `Origin` header. A successful response uses HTTP 200, `Content-Type: application/json`, and `Cache-Control: no-store`. Consumers MUST reject a body larger than 64 KiB.

## Producer descriptor

The V1 descriptor is UTF-8 JSON:

```json
{
  "schemaVersion": "1",
  "instanceId": "90f3fc7c-b047-4af2-bac1-33b5b0563d16",
  "server": {
    "id": "com.example.notes",
    "name": "Notes",
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
```

### Field requirements

| JSON pointer | Requirement |
| --- | --- |
| `/schemaVersion` | Required string; exact value `1`. |
| `/instanceId` | Required lowercase UUID string, randomly generated once per process launch. |
| `/server/id` | Required stable producer identifier; must equal TXT `id`. |
| `/server/name` | Required nonempty display name, 1–128 Unicode scalar values, with no control characters. Presentation-only. |
| `/server/version` | Required nonempty app version string, at most 64 Unicode scalar values. It is descriptive, not a compatibility input. |
| `/mcp/transport` | Required string; exact value `streamable-http`. |
| `/mcp/endpoint` | Required string; exact value `/mcp` and equal to TXT `path`. |
| `/mcp/protocolVersions` | Required nonempty array of unique protocol-version strings. V1 initially emits `2025-11-25`. |
| `/mcp/authentication` | Required string; exact value `pairing`, corresponding to TXT `auth=pair`. |
| `/capabilities/tools` | Required Boolean; must be `true` for a V1 producer. |

The top-level JSON value and each named object MUST be objects, not `null` or another JSON kind. Readers MUST ignore unknown object members at every level. A new optional member does not require a schema version change. Removing a required member, changing its meaning or JSON type, or changing the meaning of an existing enum value requires a new `schemaVersion` and compatibility tests.

An unknown value for a required enum-like field makes the descriptor incompatible; it is not treated as an absent value. Duplicate JSON object keys are invalid.

### Compatibility algorithm

A consumer performs these checks before emitting an available instance:

1. Confirm that the DNS-SD callback and resolved service use the LocalOnly interface index.
2. Validate the required TXT keys and the SRV port.
3. Fetch the descriptor from the constructed loopback URL without redirects.
4. Decode required fields while ignoring unknown members.
5. Require descriptor schema version `1`, stable ID equality with TXT, and endpoint/authentication agreement with TXT.
6. Require `streamable-http`, tools support, and at least one exact MCP protocol-version intersection with the consumer.
7. Validate the random per-launch instance ID.

An implementation MUST distinguish “incompatible” from “offline/unavailable” in its observable consumer state or diagnostic stream. It MUST NOT silently downgrade an incompatible record into a partially populated producer.

MCP version choice is an exact-string intersection. The consumer selects its most preferred supported value from that intersection and still performs MCP `initialize`; the descriptor does not replace protocol negotiation.

## Discovery event semantics

After successful validation, consumers deduplicate by descriptor `instanceId`, never by display name or stable producer ID.

- First observation of an instance produces `added`.
- A material change to the same instance (for example port, descriptor content, or DNS-SD registration identity) produces `updated`.
- Loss of the service, an incompatible replacement, or a descriptor that remains unreachable after bounded convergence produces `removed` for a previously added instance.
- A process restart has a new `instanceId` and therefore appears as removal of the old instance plus addition of the new one, even when the stable producer ID is unchanged.
- Repeated equivalent DNS-SD callbacks produce no event.

Event ordering for a single browser is serialized. Cancellation stops browsing and releases DNS-SD resources. A stored grant is never sent to a restarted or materially changed instance solely because its stable ID matches; the Phase 4 producer-authenticity gate must be resolved before persisted bearer reuse is enabled.

The public event source is a broadcast, not a work queue. Each active subscriber receives its own copy of transitions. A late subscriber first receives the browser's current instances, including explicit incompatibility state, as deterministic `added` events ordered by instance ID, then live transitions. Cancelling one subscriber removes only that subscription and does not stop browsing or another subscriber. Implementations use a bounded per-subscriber buffer; overflow terminates that subscription so it can resubscribe and replay a converged snapshot instead of silently continuing after a gap.

## Pairing exchange (Phase 4 wire baseline)

No network pairing endpoint is required in the Phase 1 in-memory slice. When network pairing is implemented, V1 uses the separate `/local-mcp/v1/pairing-requests` route described here; it does not multiplex pairing messages into `/mcp`.

### Consumer identity

A consumer identity has:

- `id`: a stable reverse-DNS application identifier using the producer-ID syntax;
- `name`: a presentation-only display name;
- `version`: a presentation-only app version; and
- `installationId`: a random lowercase UUID generated once for that installation and kept in the consumer's credential store.

Grants are bound to the tuple `(producer stable ID, consumer stable ID, consumer installation ID)`. Claimed identity is shown to the user but is not code-signing attestation.

### Request and human verification

The consumer generates 32 random bytes with a cryptographically secure random generator, encodes them as unpadded base64url, and sends one `POST /local-mcp/v1/pairing-requests` request:

```json
{
  "schemaVersion": "1",
  "consumer": {
    "id": "com.example.assistant",
    "name": "Example Assistant",
    "version": "1.0.0",
    "installationId": "3e260e1c-bb58-4247-9733-47352fbc6c98"
  },
  "requestNonce": "base64url-encoded-32-random-bytes"
}
```

`schemaVersion` MUST be the string `1`. Consumer `id`, `name`, and `version` follow the producer descriptor's corresponding validation rules; `installationId` is a canonical lowercase random UUID; and `requestNonce` must decode to exactly 32 bytes. Duplicate object keys are invalid. Readers ignore unknown members but never infer a missing required member from them.

The request uses `Content-Type: application/json`, `Accept: application/json`, no `Origin`, and a maximum body size of 8 KiB. The producer keeps this single HTTP request pending while it asks for approval, for at most 120 seconds. The credential can therefore be returned only as the response to the request that initiated the prompt; V1 has no polling or credential-retrieval endpoint.

Both apps display the same short verification code. It is computed as follows:

1. Decode the 32 nonce bytes.
2. Compute SHA-256 over the ASCII bytes `LocalMCPKit pairing v1` followed by one zero byte and the nonce bytes.
3. Take the first 20 digest bits and encode them as four characters using the Crockford Base32 alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`.

Test vector (the all-zero nonce is for testing only and MUST NOT be generated in production):

```text
nonce bytes:       32 bytes of 0x00
base64url nonce:   AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
SHA-256 digest:    edcc09810a7f02ef05bed7986d555203443532ddf1ebd7b57e47fe0ef1600cde
verification code: XQ60
```

The code is for human correlation, not authentication, and MUST NOT be persisted or logged. The producer prompt displays the consumer name, stable ID, installation ID (at least a recognizable suffix), and code. Approval is one-shot and tied to the in-memory pending request. Closing/cancelling the request cancels the pending approval.

The producer enforces both a maximum of three concurrent pending requests and a rolling limit of five new requests per minute per producer process. Excess requests receive HTTP 429 and `Retry-After`. Limits are not keyed only by the untrusted claimed consumer ID. A nonce may be used for only one attempt: the producer retains a digest of pending and terminal nonces for at least 10 minutes (or until process exit, if sooner) and rejects a replay. A consumer whose exchange is interrupted starts a new request with a new nonce and requires a new approval.

### Successful response

Approval atomically creates a unique grant and a 32-byte random bearer credential. The producer returns HTTP 200 with `Cache-Control: no-store`:

```json
{
  "schemaVersion": "1",
  "grant": {
    "id": "7cfe825d-2aec-4d1a-b476-bcbd439b23b1",
    "producerId": "com.example.notes",
    "consumerId": "com.example.assistant",
    "consumerInstallationId": "3e260e1c-bb58-4247-9733-47352fbc6c98",
    "issuedAt": "2026-07-16T19:00:00Z",
    "expiresAt": null
  },
  "accessToken": "base64url-encoded-32-random-bytes"
}
```

Timestamps use RFC 3339 UTC form. `expiresAt` is nullable: the V1 default is no automatic grant expiry, while a producer policy MAY issue an expiry. Revocation remains mandatory even for non-expiring grants. The plaintext token is returned once, never retrievable, and is sent on MCP requests as `Authorization: Bearer <accessToken>`.

The consumer stores the token and grant metadata in its secure credential store. The producer stores grant metadata and a one-way SHA-256 token digest, not the plaintext token. Token matching is constant-time. Revocation invalidates the grant before the operation reports success.

V1 has no unauthenticated token-retrieval or standalone network rotation route. A consumer rotates by completing a new explicitly approved pairing request for the same identity tuple; successful approval atomically activates the new digest and invalidates the old one. If that exchange fails, the old grant remains valid unless the operator had already revoked it. A producer operator may instead revoke immediately and require a later fresh pairing.

### Non-success responses

| Condition | HTTP status | Stable error code |
| --- | --- | --- |
| Malformed/unsupported request | 400 | `invalid_pairing_request` |
| Host or Origin rejected | 403 | `forbidden_request_context` |
| User denied | 403 | `pairing_denied` |
| Nonce replayed | 409 | `pairing_replayed` |
| Pending request expired | 408 | `pairing_expired` |
| Rate/concurrency limit | 429 | `pairing_rate_limited` |
| Approval subsystem unavailable | 503 | `pairing_unavailable` |

Error bodies have the shape below and MUST NOT echo the nonce, token, authorization header, or unsanitized framework error:

```json
{
  "schemaVersion": "1",
  "error": {
    "code": "pairing_denied",
    "message": "The producer did not approve this pairing request."
  }
}
```

## Required conformance tests

The implementation must cover at least:

- exact TXT encoding and rejection of missing, duplicate, malformed, or oversized fields;
- ignoring unknown TXT keys and descriptor members;
- descriptor Codable round trips and forward-compatible fixture decoding;
- rejection of redirects, non-loopback construction, identity/path/auth mismatches, unsupported schemas, and unsupported MCP versions;
- deduplicated added/updated/removed transitions and restart semantics;
- LocalOnly interface use in registration, browsing, resolution, and callbacks;
- pairing nonce/code test vectors, nonce replay, expiry, cancellation, denial, rate limits, issuance, rotation, and revocation before Phase 4 ships; and
- proof that no discovery or descriptor representation contains a secret.

## References

- [MCP 2025-11-25 Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [MCP 2025-11-25 lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
- [MCP 2025-11-25 schema](https://modelcontextprotocol.io/specification/2025-11-25/schema)
- [Apple `kDNSServiceInterfaceIndexLocalOnly`](https://developer.apple.com/documentation/dnssd/kdnsserviceinterfaceindexlocalonly)
- [IANA service name registry search for Matrix Configuration Protocol](https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml?search=matrix)
