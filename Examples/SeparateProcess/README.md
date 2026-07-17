# Separate-process HTTP example

This development fixture runs a producer and consumer as different processes. It uses the production IPv4-loopback HTTP transport, MCP lifecycle adapter, and LocalOnly Bonjour advertiser. The diagnostic CLI can observe that advertisement. The fixture consumer reads the exact producer instance from its private rendezvous document, connects to that loopback endpoint, initializes MCP, sends `notifications/initialized`, lists `example.echo`, and calls it.

The library also ships production network pairing and separate producer/consumer Keychain stores. This fixture intentionally uses an explicit `--preissued-dev-grant` mode instead so the subprocess test is unattended and never opens approval UI or a developer's Keychain. The producer generates one random development grant and writes it to an owner-only (`0600`) rendezvous file. The credential is never passed in command-line arguments or printed; the consumer validates and removes the file before making a request.

This mode is a deterministic integration fixture, not an application authentication pattern. Shipping apps use producer-approved pairing with `KeychainProducerGrantStore` and `KeychainConsumerGrantStore`.

## Run

Build all executables:

```sh
swift build
```

Create a private location and start the producer:

```sh
mkdir -m 700 /tmp/local-mcp-separate-process
swift run local-mcp-example-producer \
  --preissued-dev-grant \
  --rendezvous /tmp/local-mcp-separate-process/grant.json
```

While the producer is waiting, use another terminal to inspect LocalOnly discovery:

```sh
swift run local-mcp discover --timeout 2
```

Then run the consumer:

```sh
swift run local-mcp-example-consumer \
  --preissued-dev-grant \
  --rendezvous /tmp/local-mcp-separate-process/grant.json
```

The consumer prints only non-secret result metadata. Return to the producer terminal and press Return to stop it and withdraw discovery.

## Automated coverage

The subprocess integration test launches both built executables, verifies the rendezvous file is owner-only, runs the complete authenticated lifecycle and echo call, confirms the consumer deletes the grant file, and asks the producer to stop cleanly:

```sh
swift test --filter SeparateProcess
```

The test does not use UI and must run on the host like the rest of the Swift package suite. UI-only testing remains confined to the VM workflow.
