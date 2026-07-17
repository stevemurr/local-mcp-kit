# One consumer, two producers

This SwiftUI example proves that one consumer installation can discover and use two unrelated LocalMCPKit producers without mixing their commands, connections, or authorization grants.

## What runs

One process owns:

- an `InMemoryLocalMCPEnvironment` with discovery and connection boundaries;
- a Greeter producer exposing `greeting.hello`;
- a Calculator producer exposing `math.add`;
- one shared `ConsumerIdentity` and `InMemoryConsumerGrantStore`; and
- one `LocalMCPConsumer` session per discovered producer instance.

A consumer instance is intentionally bound to one stable producer. Sharing the identity and grant store represents one consumer app; using separate sessions preserves routing and authorization isolation.

The example follows this flow:

1. Register typed commands before either producer starts.
2. Start both producers and replay two discovery `added` events.
3. Create a producer-bound consumer session for each result.
4. Pair, initialize, send `initialized`, and list each producer's tools.
5. Call typed greeting and addition commands.
6. Revoke either grant and verify the other producer remains usable.
7. Stop both producers and remove both services and discovery records.

## Run

```sh
swift run local-mcp-two-producers-example
```

The executable is a native SwiftUI app. Its support target contains all orchestration and domain behavior; the app target is only presentation and input handling.

## Test

The scenario tests run with the normal package suite:

```sh
swift test --filter TwoProducerDemoTests
```

They cover startup, deterministic discovery, idempotency, unpaired gates, independent grants, initialization and listing, typed routing, command validation, overflow, isolated revocation, service reset trust behavior, failure rollback, lifecycle serialization, cleanup, and secret-free presentation state.

UI tests must run in the Tart VM, never on the host:

```sh
Scripts/run-ui-tests.sh
```

The repository-owned runner reads `.vm-uitest.conf`, clones an ephemeral Tart VM, syncs only source inputs, runs the UI-only scheme in the guest, copies the `.xcresult` bundle into `test-results/`, and deletes the temporary VM. It expects a golden image named `goldengate-xcode-golden`, guest user `xctester`, and SSH key `~/.ssh/localmcp_vm` by default. Override those portable defaults when needed:

```sh
GOLDEN_VM=my-xcode-golden \
GUEST_USER=developer \
VM_KEY="$HOME/.ssh/my_vm_key" \
Scripts/run-ui-tests.sh
```

The host needs Tart, XcodeGen, SSH, and rsync. The golden image must contain macOS, Xcode, and Remote Login with the selected key authorized. `TART_HOME` can point Tart at a non-default image store. Apple licensing prevents the repository from distributing a prepared macOS image.

## Current boundary

This is an honest Phase 1 example: discovery, transport, and credential stores are in memory. It does not claim to exercise sockets, HTTP wire encoding, Bonjour, Keychain, or separate processes. Those implementations replace the injected boundaries in later phases without changing the producer/consumer orchestration demonstrated here.

Pairing approval is automatic only to keep both logical apps visible in one small window. Production code must replace `DemoAutoPairingApprover` with a producer-owned user approval UI. The demo does not retain verification codes or expose credentials in snapshots or events.
