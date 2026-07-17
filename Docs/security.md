# Security model

## Security objective

LocalMCPKit exposes capabilities from a live app process. V1 must make that useful without turning ambient discovery or a localhost port into ambient authority.

The security boundary has three independent gates:

1. The listener and advertisement are confined to the same Mac.
2. A producer-side user explicitly approves a distinct consumer installation.
3. Every MCP request authenticates a live, unrevoked grant before command dispatch.

Passing one gate does not imply passing another. In particular, DNS-SD and the descriptor are never authenticated identity.

## Threat model

V1 considers these adversaries and failures:

- a website attempting DNS rebinding or cross-origin access to a localhost MCP server;
- another unprivileged process for the same user probing loopback ports, issuing pairing requests, or publishing a forged discovery record;
- a malformed or malicious DNS-SD/TXT/descriptor producer attempting arbitrary URL fetches, parser abuse, or identity confusion;
- a consumer presenting a missing, guessed, expired, rotated, or revoked token;
- accidental wildcard binding or LAN-visible discovery caused by configuration or framework defaults;
- oversized or slow requests, cancellation races, request floods, and partial startup/shutdown failures;
- host handlers or framework errors leaking command payloads or credentials to logs and diagnostics; and
- stale credentials surviving longer than the user's trust decision.

V1 does not claim to protect against root, a process with debugger/task-port access to either app, a compromised producer/consumer process, malicious code running inside the host app, or physical access to an unlocked account. Code-signing attestation is not part of V1 pairing; the displayed consumer identity is a user-correlated claim.

## V1 decision: producer endpoint authenticity

The stable producer ID, DNS-SD record, descriptor, and listener port are unauthenticated claims. If a consumer sends a persisted bearer token to a newly advertised instance solely because its stable ID matches, a hostile same-user process can advertise that ID, receive the token, and then impersonate or relay to the real producer. Host/Origin validation, LocalOnly DNS-SD, and checking whether the endpoint “accepts” the token do not prevent this disclosure—the impersonating endpoint sees the credential before any such result is trustworthy.

V1 resolves this boundary conservatively: stored grant metadata may be displayed or located by stable ID, but LocalMCPKit never automatically sends its bearer to a changed producer instance. A consumer must complete fresh explicit producer-side approval/rebinding before a replacement instance receives a bearer. This avoids disclosing a reusable credential to a same-user impersonator without inventing a code-signing or certificate-attestation protocol.

A future version may add a cryptographic producer binding established during approved pairing and verified before bearer disclosure. That would require a versioned protocol/ADR and compatibility tests; stable-ID matching alone will remain insufficient.

## Assets

Sensitive assets include:

- bearer credentials and their producer-side digests;
- consumer installation IDs when combined with grant metadata;
- pairing nonces and verification codes while pending;
- command inputs, outputs, and schemas that reveal private capabilities;
- the fact that a particular consumer was granted access; and
- host-app data reached by a command handler.

The stable producer ID, display name/version, per-launch instance ID, listener port, supported MCP versions, and `tools: true` capability are intentionally public to other local processes. The descriptor contains nothing more sensitive.

## Non-negotiable invariants

- The network listener binds exactly one IPv4 address: `127.0.0.1`.
- DNS-SD register, browse, resolve, and callback processing use `kDNSServiceInterfaceIndexLocalOnly` explicitly.
- No public option can select `0.0.0.0`, `::`, a hostname, a resolved interface, or a LAN address.
- Consumers construct loopback URLs and ignore advertised hostnames.
- Discovery never triggers tool invocation or automatic pairing approval.
- Authentication succeeds before MCP parsing/dispatch reaches a command handler.
- Invalid, missing, expired, rotated, or revoked credentials never reach a command handler.
- Descriptor and pairing routes receive the same Host/Origin checks as `/mcp`.
- Authorization headers, plaintext tokens, nonces, verification codes, and full command payloads never enter normal logs, errors, analytics, crash annotations, or copied diagnostics.
- Startup and shutdown clean up all partially acquired resources.

Violation of an invariant is a release blocker, not a configurable compatibility mode.

## Listener and URL policy

The listener API accepts a port policy, not a host string. Its default is an ephemeral port. Internally, the listener is created with the numeric IPv4 loopback address. After binding, the implementation verifies the bound local address and fails startup if it is not exactly `127.0.0.1`.

Consumers use only URLs of the form `http://127.0.0.1:<resolved-port>/<profile-path>`. They do not resolve `localhost`, use the SRV target, follow descriptor redirects, accept an absolute advertised URL, or fall back from loopback to another interface.

TLS is not required for V1 loopback because it would not establish producer identity without an additional trust system. The bearer grant and local confinement remain required. Adding TLS later would be defense in depth, not a replacement for pairing.

## Host and Origin policy

The request-context validator runs before authentication, route parsing, or body decoding.

### Host / authority

V1 accepts HTTP/1.1 only. For a listener bound to port `P`, the only accepted `Host` value is the exact ASCII authority:

```text
127.0.0.1:P
```

An absent authority is rejected. Multiple values, comma-joined values, user information, whitespace tricks, a trailing dot, `localhost`, IPv6 literals, another numeric spelling, another port, and any DNS name are rejected. Framework normalization must not broaden this allowlist. A rejected context receives HTTP 403 with a small sanitized response.

### Origin

Native clients normally omit `Origin`; an absent `Origin` is allowed. V1 defines no browser or web-view caller, so every present `Origin` is rejected by default, including `null`, an exact loopback-looking origin, and all preflight requests. No wildcard is permitted.

A future producer-hosted local web UI may add an explicitly configured list of exact serialized origins after a security review. Matching would include scheme, host, and port with no wildcard, suffix, regex, inherited trust, or `null` entry. This future extension does not weaken the V1 default.

This fail-closed policy implements the MCP Streamable HTTP requirement to validate Origin and prevents a hostile website from treating the localhost service as a cross-origin API.

## Route authorization

| Route | Authentication | Additional protection |
| --- | --- | --- |
| `GET /local-mcp/v1/descriptor.json` | None | Exact Host/Origin validation, no redirects, response limit, no secrets, `no-store`. |
| `POST /local-mcp/v1/pairing-requests` | No prior grant | Exact Host/Origin validation, size limit, rate/concurrency limits, short expiry, producer-side approval. |
| `/mcp` | Bearer grant on every request | Exact Host/Origin validation, limits/timeouts, MCP version checks, authorization before dispatch. |

Unknown routes still pass the cheap request-context and header limits before receiving a sanitized 404. Pairing is separate from MCP so unauthenticated approval traffic cannot be mistaken for JSON-RPC.

## Request processing order

The network producer applies checks in this order:

1. Confirm the listener accepted the connection on IPv4 loopback.
2. Enforce header count/byte/time limits.
3. Validate exact Host/authority and Origin policy.
4. Select a known method and route and enforce its body limit (the outer encrypted envelope bound for `/mcp`).
5. For `/mcp`, require the exact secure media type, then authenticate and decrypt the sealed envelope. An undecryptable, tampered, malformed, or wrongly bound envelope is an empty 400 that carries no credential information.
6. Consume the request's replay coordinate (one-shot initialize message ID, or the session's sequence window) before any suspended work.
7. Parse the logical bearer from the decrypted headers and validate the token/grant.
8. Decode the minimum MCP envelope, enforce the decrypted 1 MiB body limit, and negotiate/validate the protocol version.
9. Decode and validate command input against the bounded supported JSON Schema assertions before typed dispatch; V1 rejects backtracking regular-expression `pattern` assertions.
10. Create a package-owned `CommandContext` from the authenticated grant, deadline, cancellation signal, and generated request ID.
11. Invoke the app handler.
12. Encode a bounded, sanitized response and seal it to the request's response key.

Steps 8–12 cannot run for an unauthorized MCP request. Tests prove this with a handler invocation counter, not only an HTTP status assertion.

The bearer travels only inside the sealed envelope as one logical `authorization: Bearer <token>` header; a plaintext outer `Authorization` header invalidates the whole envelope. Malformed or duplicate logical authorization headers fail. Network responses use a generic unauthorized result for missing, wrong, expired, rotated, and revoked tokens so they do not become a grant-status oracle. A rolled-back, never-activated pairing candidate is removed rather than tombstoned, so its credential is indistinguishable from one that never existed. A consumer may map the rejection to a more specific local error only when its own credential metadata establishes that context.

The outer `/mcp` request is always `POST` with `Accept` and `Content-Type` exactly `application/vnd.localmcp.secure+json`. The decrypted logical request uses `Content-Type: application/json` and advertises both `application/json` and `text/event-stream` in its logical `Accept`, matching the MCP 2025-11-25 lifecycle carried inside the envelope. V1 responds with JSON rather than opening an SSE stream. `initialize` creates a session bound to the credential digest; later requests require the exact negotiated protocol version and logical `mcp-session-id`, plus a fresh sealed sequence number inside the session's 64-message anti-replay window. Sessions are bounded and a valid authenticated logical `DELETE` terminates one. A session cannot be reused with a different bearer.

Each active `tools/call` is keyed by session and JSON-RPC request ID. `notifications/cancelled`, HTTP client disconnect, consumer task cancellation, handler deadline, and producer stop cancel the corresponding work. Cancelled work cannot later publish a successful response. Listener connection tasks and session/call tables are released on shutdown.

## Pairing and grants

The wire exchange, verification-code derivation, 120-second pending lifetime, and request limits are defined in [the discovery profile](../Spec/local-discovery-v1.md#pairing-exchange). Both the deterministic in-memory state machine and production network route implement those logical states.

Pairing approval is producer-side and one-shot. The host callback receives display identity plus a short code and returns allow/deny for one pending request. It cannot approve an arbitrary stable ID globally. Closing the request, expiry, producer shutdown, or callback cancellation destroys the pending state.

A grant is unique per consumer installation. Successful approval mints a 256-bit random bearer token. A constant producer-wide token, deterministic token, reusable pairing nonce, or token shared between consumers is prohibited.

### Consumer identity decision

V1 consumer identity is the tuple of an app-supplied reverse-DNS stable ID and a random per-installation UUID. Display name and version are presentation metadata. The installation ID is generated once with secure randomness and stored beside consumer credential metadata; it is not derived from hardware, username, path, signing certificate, or bundle installation location.

This representation distinguishes two installations of the same app while avoiding device fingerprinting. It is not attestation. The producer UI must say which app claims the identity and show the verification code rather than presenting the stable ID as verified fact.

### Credential storage decision

Real apps use injectable Keychain-backed stores:

- The consumer stores the plaintext token, grant ID, producer stable ID, consumer stable ID/installation ID, and expiry metadata.
- The producer stores grant metadata and `SHA-256(token)`, not the plaintext token.
- Items are non-synchronizable and use a `ThisDeviceOnly` accessibility class. The default store uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- The default Keychain access group is the embedding app's own group (`nil` explicit access-group attribute). LocalMCPKit does not create a shared package-wide group.
- A host may opt into an explicitly supplied Keychain access group only when its signing/entitlement configuration already authorizes that group. The producer and consumer never need to share a Keychain group with each other.

Tests use in-memory stores and must not read or write a developer's Keychain.

Token validation decodes an exact-length token, hashes it, and compares fixed-length digests with a constant-time equality routine. Token material is held only as long as required and is excluded from `CustomStringConvertible`, `CustomDebugStringConvertible`, Codable grant metadata, and error associated values.

### Revocation and rotation

Revocation updates durable producer state before reporting success and invalidates all subsequent requests immediately. A request authenticated before revocation may complete; V1 revocation does not retroactively cancel a running app handler. Every request authenticated after revocation is rejected before dispatch.

Network rotation is a new explicitly approved pairing request for the same producer/consumer installation tuple. Approval creates a new random token, returns the plaintext once on that pending request, and atomically replaces the old digest. Failure leaves either the old grant valid or the new grant valid, never both accidentally and never neither without an explicit operator revocation. There is no standalone token retrieval endpoint.

Producer restart reloads grants from Keychain. Consumer restart can read its own token as operator/rebinding metadata. Loading those records does not authenticate a replacement network instance, and the consumer never sends the bearer automatically after an instance change.

## Resource limits

The initial network defaults and hard ceilings are intentionally conservative and must be injectable downward for tests:

| Resource | V1 baseline |
| --- | --- |
| Request headers | 32 KiB total, at most 100 fields, 10-second completion timeout |
| Descriptor response | 64 KiB maximum |
| Pairing request body | 8 KiB maximum |
| MCP HTTP request body | 1 MiB maximum |
| Decoded command arguments | 256 KiB default encoded-size budget; a command may declare a smaller limit |
| Handler execution | 30-second default deadline; configurable from 0.05 through 300 seconds |
| Pending pairing | 120 seconds, at most 3 concurrent, at most 5 starts per rolling minute |

These are package limits in addition to schema constraints. A body rejected on declared length is not read; chunked bodies stop once the limit is crossed. Responses are bounded before allocation where possible. The listener caps active connections at 64 and sessions at 128 by default, rejects excess work with bounded responses, and does not start unbounded tasks.

Cancellation propagates from disconnected requests, explicit MCP cancellation, consumer cancellation, producer stop, and deadline expiry. A cancelled handler cannot later publish a response as if successful.

## Discovery and descriptor handling

TXT records and descriptors are hostile input. Parsers use size limits, reject duplicate required keys, validate fixed relative paths before URL construction, ignore unknown additive fields, and fail closed for unsupported required semantics.

The service instance label, TXT stable ID, SRV hostname, descriptor display name, and version are never interpolated unescaped into shell commands, file paths, log format strings, or UI markup. Descriptor fetching cannot reach arbitrary URLs because consumers synthesize the URL with numeric loopback and the resolved port.

An incompatible descriptor is shown separately from an offline producer. This reduces pressure to bypass checks as “network flakiness.”

## Command safety

Registration requires an explicit JSON input schema and safety annotations. Schemas and annotations help consumers present and filter tools, but they do not enforce host-app data authorization by themselves.

Omitted annotations remain conservative: destructive and open-world default to
true. A producer must explicitly assert false only when its implementation and
data policy justify that claim.

Host handlers must apply the app's existing access controls and privacy policy. They receive a sanitized consumer/grant identity, cancellation, deadline, and trace ID. They do not receive the bearer token. The generic package never requests filesystem access or imports File Search models.

Typed decode failures, unknown commands, and handler errors return stable sanitized MCP errors. Debug builds may attach a private underlying error to an in-process diagnostic sink, but user-visible descriptions and copied bundles remain redacted.

## Logging and diagnostics

Default logs may include:

- lifecycle transition;
- stable producer ID;
- per-launch instance ID;
- command name;
- grant ID or consumer installation ID only in redacted/hashed form;
- generated request/trace ID;
- duration, result category, and byte counts; and
- sanitized error category.

Default logs never include:

- authorization headers or tokens/digests;
- pairing nonces or verification codes;
- full request/response bodies or command arguments/results;
- Keychain payloads;
- raw framework errors that may embed headers/URLs; or
- filesystem paths or user content.

Diagnostic export uses an allowlist of fields, not a post-hoc regex redactor. Types containing secrets provide deliberately redacted descriptions. Tests search captured logs and error descriptions for seeded secret values.

## Lifecycle failure safety

Startup acquires resources in stages and records each successful acquisition. Failure unwinds in reverse order. The producer cannot publish `running` until the listener, routes, and LocalOnly registration are all ready. Pairing requests are not accepted before that point.

Shutdown withdraws discovery first, rejects new pairing/MCP work, cancels pending approvals, drains/cancels active handlers within a bound, closes the listener, and clears per-process state. Repeated or concurrent start/stop calls converge on one state. Tests inject failure after every stage and assert no listener, advertisement, task, or pending request remains.

## Minimum producer operator UI

Every shipping producer integration supplies:

- an enable/disable control, with disabled as a genuine stopped state;
- current status (`stopped`, `starting`, `running`, `stopping`, or sanitized failure);
- an approval prompt showing claimed consumer name/ID, recognizable installation suffix, verification code, and explicit Allow/Deny actions;
- a list of grants with consumer identity, issue/last-use metadata when available, and immediate revoke;
- a rotate operation or a revoke-and-repair flow;
- clear indication that discovery is not trust and access is local to this Mac; and
- a redacted diagnostics view/export.

Approval must not be a passive notification, timed default-allow, or hidden background decision. A host may require stronger confirmation.

## Verification checklist

Security-relevant tests include:

- public configuration cannot express a wildcard/LAN bind;
- actual listener address is `127.0.0.1` and shutdown releases its port;
- LocalOnly interface index is used for every DNS-SD operation/callback;
- absent/wrong-port/hostname/multiple Host values are rejected;
- absent Origin is allowed and every present Origin is rejected by V1 defaults;
- missing, malformed, wrong, expired, rotated, and revoked tokens fail before dispatch;
- body/header/time/concurrency limits stop work at the correct layer;
- pairing nonce replay, expiry, cancellation, rate limit, denial, issue, rotation, and revoke are race-safe;
- descriptor redirect and arbitrary-host attempts are rejected;
- every startup failure stage and repeated start/stop leaves no resources;
- cancellation/deadline reaches handlers; and
- seeded credentials/payloads are absent from logs, errors, descriptions, and discovery data.

No network-capable build is published while authentication can be bypassed.

## References

- [Local discovery and pairing profile](../Spec/local-discovery-v1.md)
- [Architecture](architecture.md)
- [MCP 2025-11-25 transport security requirements](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports#security-warning)
