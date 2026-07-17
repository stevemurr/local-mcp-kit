# LocalMCPKit local discovery profile, version 1

Status: normative and implemented V1 discovery and pairing profile. Persisted grants are never sent automatically to a replacement instance; see [the producer-authenticity decision](../Docs/security.md#v1-decision-producer-endpoint-authenticity).

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
| Authentication mode | `pair-channel` in TXT; `pairing-channel` in JSON |
| MCP transport | `localmcp-secure-http` |
| Channel-binding suite | `x25519-hkdf-sha256-chacha20poly1305-v1` |
| Secure envelope media type | `application/vnd.localmcp.secure+json` |
| Secure envelope profile | `localmcp-secure-v1` |
| Initial MCP protocol version | `2025-11-25` |
| Address constructed by consumers | IPv4 loopback, `127.0.0.1` |

These constants are centralized by the implementation. In particular, `_mcp._tcp` MUST NOT be used because `mcp` is already assigned by IANA to another protocol.

`localmcp-secure-http` is a LocalMCP transport extension, not generic plaintext MCP Streamable HTTP. The producer runs the complete MCP 2025-11-25 lifecycle — `initialize`, `notifications/initialized`, `tools/list`, `tools/call`, session management, and cancellation — inside an encrypted loopback envelope described in [the secure MCP envelope section](#secure-mcp-envelope). The bearer credential, `Mcp-Session-Id`, `MCP-Protocol-Version`, and the JSON-RPC message never appear on the outer HTTP wire.

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
auth=pair-channel
```

Rules:

- Keys are lowercase ASCII and MUST occur at most once.
- `v` MUST be the exact ASCII string `1`.
- `id` MUST satisfy the stable identifier rules below.
- `path` MUST be `/mcp` in V1.
- `desc` MUST be `/local-mcp/v1/descriptor.json` in V1. It names this profile's descriptor, not an experimental MCP Server Card or Registry manifest.
- `auth` MUST be `pair-channel` in V1.
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
    "publicKey": "base64url-encoded-32-byte-x25519-public-key"
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
| `/mcp/transport` | Required string; exact value `localmcp-secure-http`. |
| `/mcp/endpoint` | Required string; exact value `/mcp` and equal to TXT `path`. |
| `/mcp/protocolVersions` | Required nonempty array of unique protocol-version strings. V1 initially emits `2025-11-25`. |
| `/mcp/authentication` | Required string; exact value `pairing-channel`, corresponding to TXT `auth=pair-channel`. |
| `/capabilities/tools` | Required Boolean; must be `true` for a V1 producer. |
| `/channelBinding/suite` | Required string; exact value `x25519-hkdf-sha256-chacha20poly1305-v1`. An unknown suite makes the descriptor incompatible. |
| `/channelBinding/publicKey` | Required canonical unpadded base64url encoding of the producer's 32-byte X25519 process public key, generated fresh for each process launch. |

The top-level JSON value and each named object MUST be objects, not `null` or another JSON kind. Readers MUST ignore unknown object members at every level. A new optional member does not require a schema version change. Removing a required member, changing its meaning or JSON type, or changing the meaning of an existing enum value requires a new `schemaVersion` and compatibility tests.

An unknown value for a required enum-like field makes the descriptor incompatible; it is not treated as an absent value. Duplicate JSON object keys are invalid.

### Compatibility algorithm

A consumer performs these checks before emitting an available instance:

1. Confirm that the DNS-SD callback and resolved service use the LocalOnly interface index.
2. Validate the required TXT keys and the SRV port.
3. Fetch the descriptor from the constructed loopback URL without redirects.
4. Decode required fields while ignoring unknown members.
5. Require descriptor schema version `1`, stable ID equality with TXT, and endpoint/authentication agreement with TXT.
6. Require `localmcp-secure-http`, tools support, a supported channel-binding suite with a well-formed 32-byte public key, and at least one exact MCP protocol-version intersection with the consumer.
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

Event ordering for a single browser is serialized. Cancellation stops browsing and releases DNS-SD resources. A stored grant is never sent to a restarted or materially changed instance solely because its stable ID matches; V1 requires fresh explicit producer-side approval/rebinding before the replacement receives a bearer.

The public event source is a broadcast, not a work queue. Each active subscriber receives its own copy of transitions. A late subscriber first receives the browser's current instances, including explicit incompatibility state, as deterministic `added` events ordered by instance ID, then live transitions. Cancelling one subscriber removes only that subscription and does not stop browsing or another subscriber. Implementations use a bounded per-subscriber buffer; overflow terminates that subscription so it can resubscribe and replay a converged snapshot instead of silently continuing after a gap.

## Pairing exchange

V1 implements pairing on the separate `/local-mcp/v1/pairing-requests` route described here; it does not multiplex pairing messages into `/mcp`. The in-memory transport implements the same logical state transitions without HTTP.

### Consumer identity

A consumer identity has:

- `id`: a stable reverse-DNS application identifier using the producer-ID syntax;
- `name`: a presentation-only display name;
- `version`: a presentation-only app version; and
- `installationId`: a random lowercase UUID generated once for that installation and kept in the consumer's credential store.

Grants are bound to the tuple `(producer stable ID, consumer stable ID, consumer installation ID)`. Claimed identity is shown to the user but is not code-signing attestation.

### Commitment → challenge → reveal exchange

V1 pairing over HTTP is a channel-bound two-request exchange. The consumer commits to a secret before the producer contributes its nonce, then reveals the secret to finalize a shared transcript. The transcript binds the consumer's ephemeral key, the producer's process key, the instance identity, the endpoint, and both nonces, so an active relay cannot splice its own key material into either leg.

**Leg 1 — initiation (commitment).** The consumer generates a 32-byte request nonce, a fresh X25519 ephemeral key pair, and a 32-byte client secret, all with a cryptographically secure random generator. It computes the commitment `SHA-256("LocalMCPKit pairing commitment v1" || 0x00 || clientSecret)` and sends one `POST /local-mcp/v1/pairing-requests` request:

```json
{
  "schemaVersion": "1",
  "consumer": {
    "id": "com.example.assistant",
    "name": "Example Assistant",
    "version": "1.0.0",
    "installationId": "3e260e1c-bb58-4247-9733-47352fbc6c98"
  },
  "requestNonce": "base64url-encoded-32-random-bytes",
  "expectedProducerPublicKey": "base64url-encoded-descriptor-channel-binding-key",
  "expectedInstanceId": "90f3fc7c-b047-4af2-bac1-33b5b0563d16",
  "expectedEndpoint": "http://127.0.0.1:49152/mcp",
  "consumerEphemeralPublicKey": "base64url-encoded-32-byte-x25519-public-key",
  "clientSecretCommitment": "base64url-encoded-32-byte-sha256-commitment"
}
```

`schemaVersion` MUST be the string `1`. Consumer `id`, `name`, and `version` follow the producer descriptor's corresponding validation rules; `installationId` is a canonical lowercase random UUID; and `requestNonce` must decode to exactly 32 bytes. The expected fields MUST equal the producer's live descriptor values; a mismatch (for example, a relayed descriptor carrying an attacker's binding) is rejected as a malformed request before any approval prompt. Duplicate object keys are invalid. Readers ignore unknown members but never infer a missing required member from them.

The producer validates the initiation, verifies that the consumer's ephemeral public key produces a non-degenerate X25519 shared secret with its process key, and responds `201 Created`:

```json
{
  "schemaVersion": "1",
  "pairingId": "base64url-encoded-32-byte-pairing-identifier",
  "serverNonce": "base64url-encoded-32-random-bytes"
}
```

**Leg 2 — completion (reveal).** The consumer repeats every initiation field byte-for-byte and adds the challenge values and the revealed secret in one `POST /local-mcp/v1/pairing-requests/<pairingId>` request with `Accept: application/vnd.localmcp.secure+json`:

```json
{
  "…": "all initiation fields, unchanged",
  "pairingId": "value from leg 1",
  "serverNonce": "value from leg 1",
  "revealedClientSecret": "base64url-encoded-32-byte-committed-secret"
}
```

The producer verifies that the completion exactly equals the retained initiation finalized with its own challenge values, that the revealed secret matches the commitment, and that no field — including the consumer ephemeral key — was substituted between legs. Completion is one-shot: the pairing identifier is consumed before approval work begins, and a retry can never mint or retrieve another bearer.

Both requests use `Content-Type: application/json`, no `Origin`, and a maximum body size of 8 KiB. The producer keeps the completion request pending while it asks for approval, for at most 120 seconds from initiation. The credential is returned only as the sealed response to that completion; V1 has no polling or credential-retrieval endpoint.

### Human verification code

Both apps display the same short verification code derived from the finalized pairing transcript:

1. Compute the transcript digest: SHA-256 over the length-prefixed transcript fields labelled `LocalMCPKit pairing transcript v1` (protocol label, suite, schema version, producer ID, instance ID, endpoint, producer public key, consumer identity fields, request nonce, consumer ephemeral public key, commitment, pairing ID, server nonce, revealed secret).
2. Compute SHA-256 over the ASCII bytes `LocalMCPKit SAS v1` followed by one zero byte and the transcript digest.
3. Take the first 40 digest bits and encode them as eight characters using the Crockford Base32 alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`.

Transports that cannot channel-bind (the in-process test double) derive the eight-character code from the request nonce alone: SHA-256 over `LocalMCPKit pairing v1`, one zero byte, and the nonce bytes, then the first 40 bits in the same alphabet.

Test vector for the nonce-derived form (the all-zero nonce is for testing only and MUST NOT be generated in production):

```text
nonce bytes:       32 bytes of 0x00
base64url nonce:   AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
SHA-256 digest:    edcc09810a7f02ef05bed7986d555203443532ddf1ebd7b57e47fe0ef1600cde
verification code: XQ60K08A
```

The normative transcript, commitment, SAS, KDF, and AAD vectors for the channel-bound form are maintained in the conformance tests.

The code is for human correlation, not authentication, and MUST NOT be persisted or logged. The producer prompt displays the consumer name, stable ID, installation ID (at least a recognizable suffix), and code. Approval is one-shot and tied to the in-memory pending request. Closing/cancelling the request cancels the pending approval.

The producer enforces both a maximum of three concurrent pending requests and a rolling limit of five new initiations per minute per producer process. Excess requests receive HTTP 429 and `Retry-After`. Limits are not keyed only by the untrusted claimed consumer ID. An initiation may be used for only one attempt: the producer retains a digest of pending and terminal initiations for at least 10 minutes (or until process exit, if sooner) and rejects a replay. A consumer whose exchange is interrupted starts a new initiation with fresh nonce, key, and secret material and requires a new approval.

### Successful response

Approval atomically creates a unique grant and a 32-byte random bearer credential, staged producer-side as a pending candidate bound to the running instance and channel binding. The producer returns HTTP 200 with `Cache-Control: no-store` and `Content-Type: application/vnd.localmcp.secure+json`. The body is a sealed envelope:

```json
{
  "profile": "localmcp-pairing-response-v1",
  "transcriptDigest": "base64url-encoded-32-byte-transcript-digest",
  "sealed": "base64url-encoded-chacha20poly1305-sealed-payload"
}
```

The payload key is `HKDF-SHA256(X25519(producerProcessKey, consumerEphemeralKey), salt: transcriptDigest, info: "LocalMCPKit pairing response key v1")`, and the AAD is `"LocalMCPKit pairing response aad v1" || 0x00 || transcriptDigest`. Only the consumer that generated the committed ephemeral key can open it. The decrypted payload is:

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
  "accessToken": "base64url-encoded-32-random-bytes",
  "endpointBinding": {
    "instanceId": "90f3fc7c-b047-4af2-bac1-33b5b0563d16",
    "channelBinding": {
      "suite": "x25519-hkdf-sha256-chacha20poly1305-v1",
      "publicKey": "base64url-encoded-producer-process-key"
    }
  }
}
```

Timestamps use RFC 3339 UTC form. `expiresAt` is nullable: the V1 default is no automatic grant expiry, while a producer policy MAY issue an expiry. Revocation remains mandatory even for non-expiring grants. The plaintext token is returned once, never retrievable, and is carried on MCP requests only inside the sealed envelope's logical `authorization` header.

The consumer stores the token, grant metadata, and endpoint binding in its secure credential store. The producer stores grant metadata and a one-way SHA-256 token digest, not the plaintext token; the candidate remains pending until its first authenticated request proves that the consumer decrypted the pairing response, which activates it and atomically retires the previous credential for the same identity tuple. A candidate that is never activated — a lost response, a failed consumer store write, or an interrupted rotation — never displaces the previous active grant and is removed rather than tombstoned when rolled back. Token matching is constant-time. Revocation invalidates the grant before the operation reports success.

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

## Secure MCP envelope

`localmcp-secure-http` carries every logical MCP request and response inside an authenticated-encryption envelope on `POST /mcp`. The MCP 2025-11-25 lifecycle is unchanged inside the envelope; only its wire carriage differs from generic Streamable HTTP.

The outer request is always `POST /mcp` with `Accept` and `Content-Type` both exactly `application/vnd.localmcp.secure+json`. Outer requests MUST NOT carry `Authorization`, `MCP-Protocol-Version`, or `Mcp-Session-Id` headers; their presence invalidates the envelope. The outer body is:

```json
{
  "profile": "localmcp-secure-v1",
  "suite": "x25519-hkdf-sha256-chacha20poly1305-v1",
  "requestId": "base64url-encoded-32-random-bytes",
  "ephemeralPublicKey": "base64url-encoded-32-byte-x25519-public-key",
  "sealed": "base64url-encoded-chacha20poly1305-sealed-payload"
}
```

An unknown or missing `profile` or `suite`, a request identifier that does not decode to exactly 32 bytes, or an ephemeral public key that is malformed, padded, non-canonical, or degenerate (all-zero shared secret) rejects the envelope with an empty HTTP 400 before any credential interpretation.

The request key is derived from `X25519(clientEphemeralKey, producerProcessKey)` with HKDF-SHA256 over a length-prefixed AAD binding the profile, suite, both public keys, the request identifier, the HTTP method, path, authority, and media type. The sealed plaintext is a binary record containing the logical method (`POST` or `DELETE`), an optional monotonic sequence number, the logical headers — `authorization` bearer, `accept`, `content-type`, `mcp-protocol-version`, `mcp-session-id` — and the JSON-RPC body. The decrypted logical body is bounded at 1 MiB independently of the outer envelope bound.

Responses are sealed with a key derived from the same shared secret and a digest of the exact outer request bytes, so a response can only be opened by the requester and only for that one request; swapping responses between requests fails authentication. Plaintext outer statuses (other than transport-level rejections) are never interpreted as authorization results by the client.

Replay is bounded in both directions: an `initialize` (no session) request identifier is one-shot per process, and each session enforces a 64-message anti-replay window over the sealed sequence numbers; a replayed coordinate receives a sealed `secure_replay_rejected` conflict. The producer's X25519 process key is generated per process launch and destroyed on stop, so captured envelopes cannot be decrypted or replayed against a restarted producer, and a listener that takes over a released port cannot open requests sealed to the previous process key.

## Required conformance tests

The implementation must cover at least:

- exact TXT encoding and rejection of missing, duplicate, malformed, or oversized fields;
- ignoring unknown TXT keys and descriptor members;
- descriptor Codable round trips and forward-compatible fixture decoding;
- rejection of redirects, non-loopback construction, identity/path/auth mismatches, unsupported schemas, unsupported channel-binding suites, malformed binding keys, and unsupported MCP versions;
- deduplicated added/updated/removed transitions and restart semantics;
- LocalOnly interface use in registration, browsing, resolution, and callbacks;
- the transcript, commitment, SAS, KDF, and AAD vectors, initiation replay, adaptive key substitution across pairing legs, expiry, cancellation, denial, rate limits, issuance, rotation (including lost responses and store failures after candidate issuance), and revocation;
- secure envelope tamper, replay, response swap, low-order and malformed keys, unknown suites, exact inner and outer payload-size boundaries, and process-key rotation across restarts; and
- proof that no discovery, descriptor, or outer-wire representation contains a secret.

## References

- [MCP 2025-11-25 Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [MCP 2025-11-25 lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
- [MCP 2025-11-25 schema](https://modelcontextprotocol.io/specification/2025-11-25/schema)
- [Apple `kDNSServiceInterfaceIndexLocalOnly`](https://developer.apple.com/documentation/dnssd/kdnsserviceinterfaceindexlocalonly)
- [IANA service name registry search for Matrix Configuration Protocol](https://www.iana.org/assignments/service-names-port-numbers/service-names-port-numbers.xhtml?search=matrix)
