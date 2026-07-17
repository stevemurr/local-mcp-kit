import CryptoKit
import Darwin
import Foundation
import LocalMCPConsumer
import LocalMCPContracts
import LocalMCPDiscovery
import LocalMCPProducer
import LocalMCPTesting
import Testing

private let secureRuntimeProducerIdentity = ProducerIdentity(
    stableID: "com.example.secure-runtime",
    displayName: "Secure Runtime",
    version: "1.0.0"
)

private let secureRuntimeConsumerIdentity = ConsumerIdentity(
    stableID: "com.example.secure-client",
    displayName: "Secure Client",
    version: "1.0.0",
    installationID: "dd7b17a1-57eb-4e51-9de9-32f5e8a934fb"
)

private let secureRuntimeInstanceID = "911ec7a0-c425-4fb0-aaba-01be91167ba5"
private let secureRuntimeMediaType = "application/vnd.localmcp.secure+json"

private final class SecureRuntimePairingLog: @unchecked Sendable {
    enum Event: Sendable, Equatable {
        case consumerDisplayed(PairingVerificationCode)
        case producerApproved(PairingVerificationCode)
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func append(_ event: Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private struct SecureRuntimeApprover: PairingApproving {
    let log: SecureRuntimePairingLog?

    init(log: SecureRuntimePairingLog? = nil) {
        self.log = log
    }

    func decide(_ challenge: PairingChallenge) async throws -> PairingDecision {
        log?.append(.producerApproved(challenge.verificationCode))
        return .approve
    }
}

private struct SecureRuntimeFixture: Sendable {
    let producer: LocalMCPProducer
    let transport: LocalMCPHTTPProducerTransport
    let store: InMemoryProducerGrantStore
    let instance: ProducerInstance
}

private func makeSecureRuntimeFixture(
    approver: any PairingApproving = SecureRuntimeApprover()
) async throws -> SecureRuntimeFixture {
    let catalog = DiscoveryCatalog()
    let store = InMemoryProducerGrantStore()
    let transport = LocalMCPHTTPProducerTransport()
    let producer = LocalMCPProducer(
        identity: secureRuntimeProducerIdentity,
        instanceID: secureRuntimeInstanceID,
        transport: transport,
        advertiser: catalog,
        grantStore: store,
        approval: approver
    )
    try await producer.start()
    guard let instance = await catalog.snapshot().first else {
        await producer.stop()
        throw LocalMCPError.producerUnavailable
    }
    return SecureRuntimeFixture(
        producer: producer,
        transport: transport,
        store: store,
        instance: instance
    )
}

private func makeSecureRuntimeConsumer(
    instance: ProducerInstance
) -> LocalMCPConsumer {
    LocalMCPConsumer(
        instance: instance,
        identity: secureRuntimeConsumerIdentity,
        connector: LocalMCPHTTPConnector(),
        grantStore: InMemoryConsumerGrantStore()
    )
}

private struct SecureRuntimeServiceStub: LocalMCPService {
    func requestPairing(_ request: PairingRequest) async throws -> AuthorizationGrant {
        throw LocalMCPError.pairingDenied
    }

    func authenticate(credential: AuthorizationCredential?) async throws {
        throw LocalMCPError.unauthorized
    }

    func initialize(
        supportedProtocolVersions: [String],
        credential: AuthorizationCredential?
    ) async throws -> LocalMCPInitialization {
        throw LocalMCPError.unauthorized
    }

    func initialized(credential: AuthorizationCredential?) async throws {
        throw LocalMCPError.unauthorized
    }

    func listCommands(credential: AuthorizationCredential?) async throws -> [CommandDefinition] {
        throw LocalMCPError.unauthorized
    }

    func callCommand(
        _ request: CommandCallRequest,
        credential: AuthorizationCredential?
    ) async throws -> CommandResult {
        throw LocalMCPError.unauthorized
    }
}

// Hosted CI runners wedge the Network.framework loopback listener before it
// serves its first request, so the real-listener suite runs only outside CI
// environments (locally and in the VM workflow).
@Suite(
    "Secure process-bound HTTP runtime",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil)
)
struct SecureRuntimeSecurityTests {
    @Test("process binding preparation is idempotent within an epoch and rotates after stop")
    func processBindingEpochs() async throws {
        let transport = LocalMCPHTTPProducerTransport()
        let first = try await transport.prepareProcessChannelBinding()
        let repeated = try await transport.prepareProcessChannelBinding()
        #expect(first == repeated)
        #expect(first.isSupported)

        await transport.stop()

        let rotated = try await transport.prepareProcessChannelBinding()
        #expect(rotated.isSupported)
        #expect(rotated != first)
        await transport.stop()
    }

    @Test("descriptor binding must exactly match the prepared process key")
    func descriptorBindingMismatch() async throws {
        let transport = LocalMCPHTTPProducerTransport()
        let prepared = try await transport.prepareProcessChannelBinding()
        let mismatched = ProducerChannelBinding(
            publicKey: try ChannelBindingPublicKey(
                rawRepresentation: [UInt8](repeating: 0x5a, count: 32)
            )
        )
        #expect(mismatched != prepared)

        let badDescriptor = ProducerDescriptor(
            instanceID: secureRuntimeInstanceID,
            server: secureRuntimeProducerIdentity,
            channelBinding: mismatched
        )
        await expectSecureRuntimeError(.invalidConfiguration) {
            _ = try await transport.start(
                endpointPath: "/mcp",
                descriptorPath: "/local-mcp/v1/descriptor.json",
                descriptor: badDescriptor,
                service: SecureRuntimeServiceStub()
            )
        }
        #expect(await transport.boundEndpoint == nil)
        #expect(try await transport.prepareProcessChannelBinding() == prepared)

        let matchingDescriptor = ProducerDescriptor(
            instanceID: secureRuntimeInstanceID,
            server: secureRuntimeProducerIdentity,
            channelBinding: prepared
        )
        let endpoint = try await transport.start(
            endpointPath: "/mcp",
            descriptorPath: "/local-mcp/v1/descriptor.json",
            descriptor: matchingDescriptor,
            service: SecureRuntimeServiceStub()
        )
        #expect(endpoint.port != 0)
        await transport.stop()
    }

    @Test("bound pairing displays the validated code before producer approval")
    func boundPairingCallbackOrder() async throws {
        let log = SecureRuntimePairingLog()
        let fixture = try await makeSecureRuntimeFixture(
            approver: SecureRuntimeApprover(log: log)
        )
        do {
            let consumer = makeSecureRuntimeConsumer(instance: fixture.instance)
            let grant = try await consumer.pair { code in
                log.append(.consumerDisplayed(code))
            }

            let channelBinding = try #require(fixture.instance.channelBinding)
            let endpointBinding = AuthorizationEndpointBinding(
                instanceID: fixture.instance.instanceID,
                channelBinding: channelBinding
            )
            #expect(grant.endpointBinding == endpointBinding)

            let events = log.snapshot()
            #expect(events.count == 2)
            guard events.count == 2,
                  case let .consumerDisplayed(displayed) = events[0],
                  case let .producerApproved(approved) = events[1]
            else {
                Issue.record("Expected display followed by approval")
                await fixture.producer.stop()
                return
            }
            #expect(displayed == approved)
            #expect(displayed.withUnsafeDisplayValue { $0.count } == 8)
            await fixture.producer.stop()
        } catch {
            await fixture.producer.stop()
            throw error
        }
    }

    @Test("production client keeps bearer, MCP headers, and JSON-RPC body off the outer wire")
    func outerWireConfidentiality() async throws {
        let fixture = try await makeSecureRuntimeFixture()
        let consumer = makeSecureRuntimeConsumer(instance: fixture.instance)
        let grant: AuthorizationGrant
        do {
            grant = try await consumer.pair()
        } catch {
            await fixture.producer.stop()
            throw error
        }
        let port = fixture.instance.endpoint.port
        await fixture.producer.stop()

        let listener = try secureRuntimeCaptureListener(port: port)
        let capture = Task.detached {
            try secureRuntimeCaptureOneRequest(listener: listener)
        }
        let initialize = Task {
            try await consumer.initialize(grant: grant)
        }
        let request = try await capture.value
        await expectSecureRuntimeError(.producerUnavailable) {
            _ = try await initialize.value
        }

        let requestText = String(decoding: request, as: UTF8.self)
        let lowercased = requestText.lowercased()
        let token = grant.credential.withUnsafeEncodedValue { $0 }
        #expect(requestText.hasPrefix("POST /mcp HTTP/1.1\r\n"))
        #expect(lowercased.contains("content-type: \(secureRuntimeMediaType)"))
        #expect(!lowercased.contains("authorization:"))
        #expect(!lowercased.contains("mcp-protocol-version:"))
        #expect(!lowercased.contains("mcp-session-id:"))
        #expect(!requestText.contains(token))

        let outerBody = try #require(secureRuntimeHTTPBody(request))
        let outerBodyText = String(decoding: outerBody, as: UTF8.self)
        #expect(!outerBodyText.contains("\"jsonrpc\""))
        #expect(!outerBodyText.contains("\"initialize\""))
        #expect(!outerBodyText.contains(MCPProtocolVersion.current.rawValue))
    }

    @Test("secure MCP envelopes reject tamper, replay, response swap, and low-order keys")
    func secureEnvelopeAdversaries() async throws {
        let fixture = try await makeSecureRuntimeFixture()
        do {
            let consumer = makeSecureRuntimeConsumer(instance: fixture.instance)
            let grant = try await consumer.pair()
            let pendingRecords = try await fixture.store.records()
            #expect(pendingRecords.count == 1)
            #expect(pendingRecords.allSatisfy {
                if case .pending = $0.state { return true }
                return false
            })
            let first = try SecureRuntimeRawRequest.initialize(
                instance: fixture.instance,
                credential: grant.credential,
                marker: "first"
            )
            let firstRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: first.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(secureRuntimeHTTPStatus(firstRaw) == 200)
            let firstInner = try first.open(firstRaw)
            #expect(firstInner.statusCode == 200)
            let sessionID = try #require(firstInner.headers["mcp-session-id"])
            let activatedRecords = try await fixture.store.records()
            #expect(activatedRecords.count == 1)
            #expect(activatedRecords.allSatisfy { $0.state == .active })

            let second = try SecureRuntimeRawRequest.initialize(
                instance: fixture.instance,
                credential: grant.credential,
                marker: "second"
            )
            let secondRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: second.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(secureRuntimeHTTPStatus(secondRaw) == 200)
            #expect(try second.open(secondRaw).statusCode == 200)
            #expect(throws: (any Error).self) {
                _ = try first.open(secondRaw)
            }

            let sendSequence: @Sendable (UInt64) async throws -> SecureRuntimeInnerResponse = {
                sequence in
                let request = try SecureRuntimeRawRequest.initialized(
                    instance: fixture.instance,
                    credential: grant.credential,
                    sessionID: sessionID,
                    sequence: sequence
                )
                let raw = try await secureRuntimeHTTPExchange(
                    port: fixture.instance.endpoint.port,
                    request: request.httpRequest(port: fixture.instance.endpoint.port)
                )
                #expect(secureRuntimeHTTPStatus(raw) == 200)
                return try request.open(raw)
            }
            #expect(try await sendSequence(5).statusCode == 202)
            #expect(try await sendSequence(3).statusCode == 202)
            #expect(try await sendSequence(3).statusCode == 409)
            #expect(try await sendSequence(70).statusCode == 202)
            #expect(try await sendSequence(6).statusCode == 409)

            let replayRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: first.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(secureRuntimeHTTPStatus(replayRaw) == 200)
            let replayInner = try first.open(replayRaw)
            #expect(replayInner.statusCode == 409)
            #expect(String(decoding: replayInner.body, as: UTF8.self).contains("secure_replay_rejected"))

            let tampered = try first.tamperingWithCiphertext()
            let tamperedRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: tampered.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(secureRuntimeHTTPStatus(tamperedRaw) == 400)
            #expect(secureRuntimeHTTPBody(tamperedRaw)?.isEmpty == true)

            let lowOrderBody = try first.replacingEphemeralPublicKey(
                with: [UInt8](repeating: 0, count: 32)
            )
            let lowOrderRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: secureRuntimeHTTPPost(
                    path: "/mcp",
                    port: fixture.instance.endpoint.port,
                    headers: [
                        "Accept": secureRuntimeMediaType,
                        "Content-Type": secureRuntimeMediaType,
                    ],
                    body: lowOrderBody
                )
            )
            #expect(secureRuntimeHTTPStatus(lowOrderRaw) == 400)
            #expect(secureRuntimeHTTPBody(lowOrderRaw)?.isEmpty == true)

            let forgedPlaintext401 = Data(
                "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\nContent-Length: 0\r\n\r\n".utf8
            )
            #expect(throws: (any Error).self) {
                _ = try first.open(forgedPlaintext401)
            }

            try await fixture.producer.revokeGrant(grant.metadata.grantID)
            let revoked = try SecureRuntimeRawRequest.initialize(
                instance: fixture.instance,
                credential: grant.credential,
                marker: "revoked"
            )
            let revokedRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: revoked.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(secureRuntimeHTTPStatus(revokedRaw) == 200)
            let revokedInner = try revoked.open(revokedRaw)
            #expect(revokedInner.statusCode == 401)
            #expect(revokedInner.headers["www-authenticate"] == "Bearer")

            let invalidCredential = try AuthorizationCredential(
                bytes: [UInt8](repeating: 0xa5, count: 32)
            )
            let invalid = try SecureRuntimeRawRequest.initialize(
                instance: fixture.instance,
                credential: invalidCredential,
                marker: "invalid"
            )
            let invalidRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: invalid.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(secureRuntimeHTTPStatus(invalidRaw) == 200)
            let invalidInner = try invalid.open(invalidRaw)
            #expect(invalidInner.statusCode == 401)
            #expect(invalidInner.headers["www-authenticate"] == "Bearer")
            await fixture.producer.stop()
        } catch {
            await fixture.producer.stop()
            throw error
        }
    }

    @Test("a relayed descriptor with a substituted channel binding cannot pair or decrypt")
    func forgedDescriptorRelay() async throws {
        let fixture = try await makeSecureRuntimeFixture()
        do {
            // The attacker relays the real endpoint but advertises its own key.
            var forged = fixture.instance
            forged.channelBinding = ProducerChannelBinding(
                publicKey: try ChannelBindingPublicKey(
                    Curve25519.KeyAgreement.PrivateKey().publicKey
                )
            )
            #expect(forged.channelBinding != fixture.instance.channelBinding)

            let forgedPairing = try SecureRuntimeRawPairing(
                instance: forged,
                publicKeyBytes: Array(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
                nonceByte: 0x44,
                secretByte: 0x54
            )
            let initiation = try await forgedPairing.beginResponse(
                port: fixture.instance.endpoint.port
            )
            #expect(secureRuntimeHTTPStatus(initiation) == 400)
            #expect(String(decoding: initiation, as: UTF8.self).contains("invalid_pairing_request"))

            // A request sealed to the forged binding is undecryptable noise to
            // the real producer and leaks nothing back.
            let consumer = makeSecureRuntimeConsumer(instance: fixture.instance)
            let grant = try await consumer.pair()
            let token = grant.credential.withUnsafeEncodedValue { $0 }
            let misSealed = try SecureRuntimeRawRequest.initialize(
                instance: forged,
                credential: grant.credential,
                marker: "forged-binding"
            )
            let misSealedRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: misSealed.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(secureRuntimeHTTPStatus(misSealedRaw) == 400)
            #expect(secureRuntimeHTTPBody(misSealedRaw)?.isEmpty == true)
            #expect(!String(decoding: misSealedRaw, as: UTF8.self).contains(token))

            // The correctly bound channel is unaffected.
            let genuine = try SecureRuntimeRawRequest.initialize(
                instance: fixture.instance,
                credential: grant.credential,
                marker: "genuine-binding"
            )
            let genuineRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: genuine.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(try genuine.open(genuineRaw).statusCode == 200)
            await fixture.producer.stop()
        } catch {
            await fixture.producer.stop()
            throw error
        }
    }

    @Test("an adaptively substituted ephemeral key cannot hijack a pairing completion")
    func adaptiveKeySubstitutionAcrossPairingLegs() async throws {
        let fixture = try await makeSecureRuntimeFixture()
        do {
            let valid = try SecureRuntimeRawPairing(
                instance: fixture.instance,
                publicKeyBytes: Array(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
                nonceByte: 0x45,
                secretByte: 0x55
            )
            let challenge = try await valid.begin(port: fixture.instance.endpoint.port)

            // The attacker races the completion leg with its own key while
            // replaying every committed field it observed.
            let substituted = try await valid.completeSubstitutingEphemeralKey(
                challenge: challenge,
                port: fixture.instance.endpoint.port,
                publicKeyBytes: Array(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)
            )
            #expect(secureRuntimeHTTPStatus(substituted) == 400)
            #expect(!String(decoding: substituted, as: UTF8.self).contains("accessToken"))

            // The legitimate initiator still completes against the same
            // pairing identifier afterwards.
            let completed = try await valid.complete(
                challenge: challenge,
                port: fixture.instance.endpoint.port
            )
            #expect(secureRuntimeHTTPStatus(completed) == 200)
            await fixture.producer.stop()
        } catch {
            await fixture.producer.stop()
            throw error
        }
    }

    @Test("secure envelopes reject missing suites, unknown suites, and malformed public keys")
    func envelopeSuiteAndKeyValidation() async throws {
        let fixture = try await makeSecureRuntimeFixture()
        do {
            let consumer = makeSecureRuntimeConsumer(instance: fixture.instance)
            let grant = try await consumer.pair()
            let template = try SecureRuntimeRawRequest.initialize(
                instance: fixture.instance,
                credential: grant.credential,
                marker: "suite-template"
            )

            var hostileBodies: [Data] = []
            // Unknown and missing crypto suites.
            hostileBodies.append(try template.replacingEnvelopeField(
                "suite",
                with: "x25519-future-suite-v2"
            ))
            hostileBodies.append(try template.replacingEnvelopeField("suite", with: nil))
            // Malformed ephemeral public keys: wrong length, padded encoding,
            // and non-base64url content.
            hostileBodies.append(try template.replacingEphemeralPublicKey(
                with: [UInt8](repeating: 1, count: 31)
            ))
            hostileBodies.append(try template.replacingEnvelopeField(
                "ephemeralPublicKey",
                with: "AAAA===="
            ))
            hostileBodies.append(try template.replacingEnvelopeField(
                "ephemeralPublicKey",
                with: "not/base64+url!"
            ))

            for hostileBody in hostileBodies {
                let raw = try await secureRuntimeHTTPExchange(
                    port: fixture.instance.endpoint.port,
                    request: secureRuntimeHTTPPost(
                        path: "/mcp",
                        port: fixture.instance.endpoint.port,
                        headers: [
                            "Accept": secureRuntimeMediaType,
                            "Content-Type": secureRuntimeMediaType,
                        ],
                        body: hostileBody
                    )
                )
                #expect(secureRuntimeHTTPStatus(raw) == 400)
                #expect(secureRuntimeHTTPBody(raw)?.isEmpty == true)
            }

            // The untouched template still authenticates, so every rejection
            // above was caused by the mutation alone.
            let acceptedRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: template.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(try template.open(acceptedRaw).statusCode == 200)
            await fixture.producer.stop()
        } catch {
            await fixture.producer.stop()
            throw error
        }
    }

    @Test("a lost rotation response leaves the active grant usable and the candidate inert")
    func pairingResponseLossDuringRotation() async throws {
        let fixture = try await makeSecureRuntimeFixture()
        do {
            let consumer = makeSecureRuntimeConsumer(instance: fixture.instance)
            let grant = try await consumer.pair()
            let activate = try SecureRuntimeRawRequest.initialize(
                instance: fixture.instance,
                credential: grant.credential,
                marker: "activate"
            )
            let activateRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: activate.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(try activate.open(activateRaw).statusCode == 200)

            // A rotation completes on the producer, but its sealed response
            // never reaches the consumer.
            let rotation = try SecureRuntimeRawPairing(
                instance: fixture.instance,
                publicKeyBytes: Array(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
                nonceByte: 0x46,
                secretByte: 0x56
            )
            let challenge = try await rotation.begin(port: fixture.instance.endpoint.port)
            let lost = try await rotation.complete(
                challenge: challenge,
                port: fixture.instance.endpoint.port
            )
            #expect(secureRuntimeHTTPStatus(lost) == 200)

            // The unactivated candidate is staged alongside the active grant
            // without displacing it.
            let records = try await fixture.store.records()
            #expect(records.count == 2)
            #expect(records.filter { $0.state == .active }.count == 1)

            let stillActive = try SecureRuntimeRawRequest.initialize(
                instance: fixture.instance,
                credential: grant.credential,
                marker: "after-loss"
            )
            let stillActiveRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: stillActive.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(try stillActive.open(stillActiveRaw).statusCode == 200)

            // A later successful rotation activates a fresh credential and
            // retires the old one.
            let replacement = try await consumer.pair()
            let replacementInitialize = try SecureRuntimeRawRequest.initialize(
                instance: fixture.instance,
                credential: replacement.credential,
                marker: "replacement"
            )
            let replacementRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: replacementInitialize.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(try replacementInitialize.open(replacementRaw).statusCode == 200)

            let retired = try SecureRuntimeRawRequest.initialize(
                instance: fixture.instance,
                credential: grant.credential,
                marker: "retired"
            )
            let retiredRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: retired.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(try retired.open(retiredRaw).statusCode == 401)
            await fixture.producer.stop()
        } catch {
            await fixture.producer.stop()
            throw error
        }
    }

    @Test("a consumer-store failure after candidate issuance preserves the previous grant")
    func consumerStoreFailureAfterCandidateIssuance() async throws {
        let fixture = try await makeSecureRuntimeFixture()
        do {
            let store = FailingSaveConsumerGrantStore()
            let consumer = LocalMCPConsumer(
                instance: fixture.instance,
                identity: secureRuntimeConsumerIdentity,
                connector: LocalMCPHTTPConnector(),
                grantStore: store
            )
            let first = try await consumer.pair()
            let activate = try SecureRuntimeRawRequest.initialize(
                instance: fixture.instance,
                credential: first.credential,
                marker: "first-activate"
            )
            let activateRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: activate.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(try activate.open(activateRaw).statusCode == 200)

            // The producer issues a rotation candidate, then the consumer
            // fails to persist it.
            await store.failNextSave()
            await expectSecureRuntimeError(.credentialStoreFailed) {
                _ = try await consumer.pair()
            }

            // The previous credential remains persisted and authenticated;
            // the orphaned candidate stays pending and cannot displace it.
            let persisted = try await store.grant(
                producerID: secureRuntimeProducerIdentity.stableID,
                consumer: secureRuntimeConsumerIdentity
            )
            #expect(persisted?.credential == first.credential)
            let records = try await fixture.store.records()
            #expect(records.filter { $0.state == .active }.count == 1)

            let stillActive = try SecureRuntimeRawRequest.initialize(
                instance: fixture.instance,
                credential: first.credential,
                marker: "still-active"
            )
            let stillActiveRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: stillActive.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(try stillActive.open(stillActiveRaw).statusCode == 200)

            // Recovery is a routine re-pair once the store is healthy again.
            let second = try await consumer.pair()
            let recovered = try SecureRuntimeRawRequest.initialize(
                instance: fixture.instance,
                credential: second.credential,
                marker: "recovered"
            )
            let recoveredRaw = try await secureRuntimeHTTPExchange(
                port: fixture.instance.endpoint.port,
                request: recovered.httpRequest(port: fixture.instance.endpoint.port)
            )
            #expect(try recovered.open(recoveredRaw).statusCode == 200)
            await fixture.producer.stop()
        } catch {
            await fixture.producer.stop()
            throw error
        }
    }

    @Test("pairing completion rejects commitment tamper and replay; low-order peers receive no bearer")
    func pairingCompletionAdversaries() async throws {
        let fixture = try await makeSecureRuntimeFixture()
        do {
            let valid = try SecureRuntimeRawPairing(
                instance: fixture.instance,
                publicKeyBytes: Array(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation),
                nonceByte: 0x41,
                secretByte: 0x51
            )
            let challenge = try await valid.begin(port: fixture.instance.endpoint.port)
            let duplicateInitiation = try await valid.beginResponse(
                port: fixture.instance.endpoint.port
            )
            #expect(secureRuntimeHTTPStatus(duplicateInitiation) == 409)
            #expect(String(decoding: duplicateInitiation, as: UTF8.self).contains("pairing_replayed"))
            let tampered = try await valid.complete(
                challenge: challenge,
                port: fixture.instance.endpoint.port,
                revealedSecretByte: 0x52
            )
            #expect(secureRuntimeHTTPStatus(tampered) == 400)

            let completed = try await valid.complete(
                challenge: challenge,
                port: fixture.instance.endpoint.port
            )
            #expect(secureRuntimeHTTPStatus(completed) == 200)
            #expect(secureRuntimeHTTPHeaders(completed)["content-type"] == secureRuntimeMediaType)
            #expect(!String(decoding: completed, as: UTF8.self).contains("accessToken"))

            let replay = try await valid.complete(
                challenge: challenge,
                port: fixture.instance.endpoint.port
            )
            #expect(secureRuntimeHTTPStatus(replay) == 409)
            #expect(String(decoding: replay, as: UTF8.self).contains("pairing_replayed"))

            let lowOrder = try SecureRuntimeRawPairing(
                instance: fixture.instance,
                publicKeyBytes: [UInt8](repeating: 0, count: 32),
                nonceByte: 0x42,
                secretByte: 0x61
            )
            let lowOrderResponse = try await lowOrder.beginResponse(
                port: fixture.instance.endpoint.port
            )
            #expect(secureRuntimeHTTPStatus(lowOrderResponse) == 400)
            #expect(!String(decoding: lowOrderResponse, as: UTF8.self).contains("accessToken"))
            let records = try await fixture.store.records()
            #expect(records.allSatisfy {
                if case .pending = $0.state { return true }
                return false
            })
            await fixture.producer.stop()
        } catch {
            await fixture.producer.stop()
            throw error
        }
    }
}

private func expectSecureRuntimeError(
    _ expected: LocalMCPError,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected \(expected)")
    } catch let error as LocalMCPError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

private struct SecureRuntimeInnerResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

private enum SecureRuntimeWireError: Error {
    case malformed
    case authentication
}

private struct SecureRuntimeRawRequest {
    private static let requestKeyInfo = Data("LocalMCPKit secure request key v1".utf8)
    private static let responseKeyInfo = Data("LocalMCPKit secure response key v1".utf8)

    let body: Data
    let requestID: String
    let responseKey: SymmetricKey
    let responseAAD: Data

    static func initialize(
        instance: ProducerInstance,
        credential: AuthorizationCredential,
        marker: String
    ) throws -> SecureRuntimeRawRequest {
        let token = credential.withUnsafeEncodedValue { $0 }
        let logicalBody = try JSONSerialization.data(
            withJSONObject: [
                "id": marker,
                "jsonrpc": "2.0",
                "method": "initialize",
                "params": [
                    "capabilities": [:],
                    "clientInfo": ["name": "Raw security test", "version": "1"],
                    "protocolVersion": MCPProtocolVersion.current.rawValue,
                ],
            ],
            options: [.sortedKeys]
        )
        return try seal(
            instance: instance,
            logicalHeaders: [
                "accept": "application/json, text/event-stream",
                "authorization": "Bearer \(token)",
                "content-type": "application/json",
            ],
            logicalBody: logicalBody,
            sequence: nil
        )
    }

    static func initialized(
        instance: ProducerInstance,
        credential: AuthorizationCredential,
        sessionID: String,
        sequence: UInt64
    ) throws -> SecureRuntimeRawRequest {
        let token = credential.withUnsafeEncodedValue { $0 }
        let logicalBody = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:],
            ],
            options: [.sortedKeys]
        )
        return try seal(
            instance: instance,
            logicalHeaders: [
                "accept": "application/json, text/event-stream",
                "authorization": "Bearer \(token)",
                "content-type": "application/json",
                "mcp-protocol-version": MCPProtocolVersion.current.rawValue,
                "mcp-session-id": sessionID,
            ],
            logicalBody: logicalBody,
            sequence: sequence
        )
    }

    private static func seal(
        instance: ProducerInstance,
        logicalHeaders: [String: String],
        logicalBody: Data,
        sequence: UInt64?
    ) throws -> SecureRuntimeRawRequest {
        let binding = try #require(instance.channelBinding)
        let encodedProducerPublicKey = try secureRuntimeEncodedScalar(binding.publicKey)
        guard let producerPublicBytes = secureRuntimeBase64URLDecode(encodedProducerPublicKey) else {
            throw SecureRuntimeWireError.malformed
        }
        let producerPublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Data(producerPublicBytes)
        )
        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublicBytes = Array(ephemeralPrivateKey.publicKey.rawRepresentation)
        let requestIDBytes = secureRuntimeRandomBytes(count: 32)
        let requestID = secureRuntimeBase64URLEncode(requestIDBytes)
        let authority = "127.0.0.1:\(instance.endpoint.port)"
        let requestAAD = secureRuntimeLengthPrefixed([
            Array("LocalMCPKit secure request aad v1".utf8),
            Array("localmcp-secure-v1".utf8),
            Array(binding.suite.utf8),
            producerPublicBytes,
            ephemeralPublicBytes,
            requestIDBytes,
            Array("POST".utf8),
            Array("/mcp".utf8),
            Array(authority.utf8),
            Array(secureRuntimeMediaType.utf8),
        ])
        let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: producerPublicKey)
        let requestKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(SHA256.hash(data: requestAAD)),
            sharedInfo: requestKeyInfo,
            outputByteCount: 32
        )
        let plaintext = try secureRuntimeEncodeRequestPayload(
            headers: logicalHeaders,
            body: logicalBody,
            sequence: sequence
        )
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: requestKey,
            authenticating: requestAAD
        )
        let body = try JSONSerialization.data(
            withJSONObject: [
                "ephemeralPublicKey": secureRuntimeBase64URLEncode(ephemeralPublicBytes),
                "profile": "localmcp-secure-v1",
                "requestId": requestID,
                "sealed": secureRuntimeBase64URLEncode(Array(sealed.combined)),
                "suite": ProducerChannelBinding.supportedSuite,
            ],
            options: [.sortedKeys]
        )
        let requestDigest = Data(SHA256.hash(data: secureRuntimeLengthPrefixed([
            Array("LocalMCPKit secure request digest v1".utf8),
            Array("POST".utf8),
            Array("/mcp".utf8),
            Array(authority.utf8),
            Array(secureRuntimeMediaType.utf8),
            [UInt8](body),
        ])))
        let responseKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: requestDigest,
            sharedInfo: responseKeyInfo,
            outputByteCount: 32
        )
        let responseAAD = secureRuntimeLengthPrefixed([
            Array("LocalMCPKit secure response aad v1".utf8),
            requestIDBytes,
            [UInt8](requestDigest),
            Array(secureRuntimeMediaType.utf8),
        ])
        return SecureRuntimeRawRequest(
            body: body,
            requestID: requestID,
            responseKey: responseKey,
            responseAAD: responseAAD
        )
    }

    func httpRequest(port: UInt16) -> Data {
        secureRuntimeHTTPPost(
            path: "/mcp",
            port: port,
            headers: [
                "Accept": secureRuntimeMediaType,
                "Content-Type": secureRuntimeMediaType,
            ],
            body: body
        )
    }

    func open(_ rawHTTPResponse: Data) throws -> SecureRuntimeInnerResponse {
        guard secureRuntimeHTTPStatus(rawHTTPResponse) == 200,
              secureRuntimeHTTPHeaders(rawHTTPResponse)["content-type"] == secureRuntimeMediaType,
              let body = secureRuntimeHTTPBody(rawHTTPResponse),
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["profile"] as? String == "localmcp-secure-v1",
              object["suite"] as? String == ProducerChannelBinding.supportedSuite,
              object["requestId"] as? String == requestID,
              let sealedString = object["sealed"] as? String,
              let sealedBytes = secureRuntimeBase64URLDecode(sealedString)
        else { throw SecureRuntimeWireError.malformed }
        do {
            let box = try ChaChaPoly.SealedBox(combined: Data(sealedBytes))
            let plaintext = try ChaChaPoly.open(
                box,
                using: responseKey,
                authenticating: responseAAD
            )
            return try secureRuntimeParseResponsePayload(plaintext)
        } catch let error as SecureRuntimeWireError {
            throw error
        } catch {
            throw SecureRuntimeWireError.authentication
        }
    }

    func tamperingWithCiphertext() throws -> SecureRuntimeRawRequest {
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let sealedString = object["sealed"] as? String,
              var sealedBytes = secureRuntimeBase64URLDecode(sealedString),
              !sealedBytes.isEmpty
        else { throw SecureRuntimeWireError.malformed }
        sealedBytes[sealedBytes.count - 1] ^= 1
        object["sealed"] = secureRuntimeBase64URLEncode(sealedBytes)
        return SecureRuntimeRawRequest(
            body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            requestID: requestID,
            responseKey: responseKey,
            responseAAD: responseAAD
        )
    }

    func replacingEphemeralPublicKey(with bytes: [UInt8]) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw SecureRuntimeWireError.malformed
        }
        object["ephemeralPublicKey"] = secureRuntimeBase64URLEncode(bytes)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Overwrites (or removes, when `value` is nil) one top-level envelope
    /// member while leaving the sealed payload untouched.
    func replacingEnvelopeField(_ name: String, with value: String?) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw SecureRuntimeWireError.malformed
        }
        if let value {
            object[name] = value
        } else {
            object.removeValue(forKey: name)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private struct SecureRuntimeRawPairing: @unchecked Sendable {
    struct Challenge {
        let pairingID: String
        let serverNonce: String
    }

    let instance: ProducerInstance
    let initiation: [String: Any]
    let secret: String

    init(
        instance: ProducerInstance,
        publicKeyBytes: [UInt8],
        nonceByte: UInt8,
        secretByte: UInt8
    ) throws {
        let binding = try #require(instance.channelBinding)
        let secretBytes = [UInt8](repeating: secretByte, count: 32)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let request = try PairingRequest(
            consumer: secureRuntimeConsumerIdentity,
            requestNonce: PairingNonce(bytes: [UInt8](repeating: nonceByte, count: 32)),
            expectedProducerPublicKey: binding.publicKey,
            expectedInstanceID: instance.instanceID,
            expectedEndpoint: instance.endpoint.url.absoluteString,
            initiatorPrivateKeyRawRepresentation: Array(privateKey.rawRepresentation),
            clientSecret: PairingSecret(bytes: secretBytes)
        )
        guard var encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)
        ) as? [String: Any]
        else { throw SecureRuntimeWireError.malformed }
        encoded["consumerEphemeralPublicKey"] = secureRuntimeBase64URLEncode(publicKeyBytes)
        self.instance = instance
        secret = secureRuntimeBase64URLEncode(secretBytes)
        initiation = encoded
    }

    func begin(port: UInt16) async throws -> Challenge {
        let response = try await beginResponse(port: port)
        guard secureRuntimeHTTPStatus(response) == 201,
              let responseBody = secureRuntimeHTTPBody(response),
              let object = try JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let pairingID = object["pairingId"] as? String,
              let serverNonce = object["serverNonce"] as? String
        else { throw SecureRuntimeWireError.malformed }
        return Challenge(pairingID: pairingID, serverNonce: serverNonce)
    }

    func beginResponse(port: UInt16) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: initiation, options: [.sortedKeys])
        return try await secureRuntimeHTTPExchange(
            port: port,
            request: secureRuntimeHTTPPost(
                path: "/local-mcp/v1/pairing-requests",
                port: port,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                ],
                body: body
            )
        )
    }

    func complete(
        challenge: Challenge,
        port: UInt16,
        revealedSecretByte: UInt8? = nil
    ) async throws -> Data {
        var completion = initiation
        completion["pairingId"] = challenge.pairingID
        completion["serverNonce"] = challenge.serverNonce
        completion["revealedClientSecret"] = revealedSecretByte.map {
            secureRuntimeBase64URLEncode([UInt8](repeating: $0, count: 32))
        } ?? secret
        let body = try JSONSerialization.data(withJSONObject: completion, options: [.sortedKeys])
        return try await secureRuntimeHTTPExchange(
            port: port,
            request: secureRuntimeHTTPPost(
                path: "/local-mcp/v1/pairing-requests/\(challenge.pairingID)",
                port: port,
                headers: [
                    "Accept": secureRuntimeMediaType,
                    "Content-Type": "application/json",
                ],
                body: body
            )
        )
    }

    /// Sends a completion whose ephemeral key differs from the committed
    /// initiation, imitating an attacker adapting between pairing legs.
    func completeSubstitutingEphemeralKey(
        challenge: Challenge,
        port: UInt16,
        publicKeyBytes: [UInt8]
    ) async throws -> Data {
        var completion = initiation
        completion["consumerEphemeralPublicKey"] = secureRuntimeBase64URLEncode(publicKeyBytes)
        completion["pairingId"] = challenge.pairingID
        completion["serverNonce"] = challenge.serverNonce
        completion["revealedClientSecret"] = secret
        let body = try JSONSerialization.data(withJSONObject: completion, options: [.sortedKeys])
        return try await secureRuntimeHTTPExchange(
            port: port,
            request: secureRuntimeHTTPPost(
                path: "/local-mcp/v1/pairing-requests/\(challenge.pairingID)",
                port: port,
                headers: [
                    "Accept": secureRuntimeMediaType,
                    "Content-Type": "application/json",
                ],
                body: body
            )
        )
    }
}

/// Consumer store whose next save fails after the producer has already issued
/// a rotation candidate.
private actor FailingSaveConsumerGrantStore: ConsumerGrantStoring {
    struct Outage: Error {}

    private let backing = InMemoryConsumerGrantStore()
    private var nextSaveFails = false

    func failNextSave() {
        nextSaveFails = true
    }

    func save(_ grant: AuthorizationGrant) async throws {
        if nextSaveFails {
            nextSaveFails = false
            throw Outage()
        }
        try await backing.save(grant)
    }

    func grant(
        producerID: String,
        consumer: ConsumerIdentity
    ) async throws -> AuthorizationGrant? {
        try await backing.grant(producerID: producerID, consumer: consumer)
    }

    func remove(
        producerID: String,
        consumer: ConsumerIdentity,
        ifCredentialMatches credential: AuthorizationCredential?
    ) async throws {
        try await backing.remove(
            producerID: producerID,
            consumer: consumer,
            ifCredentialMatches: credential
        )
    }
}

private func secureRuntimeEncodedScalar<Value: Encodable>(_ value: Value) throws -> String {
    let data = try JSONEncoder().encode(value)
    guard let string = try JSONSerialization.jsonObject(
        with: data,
        options: [.fragmentsAllowed]
    ) as? String else {
        throw SecureRuntimeWireError.malformed
    }
    return string
}

private func secureRuntimeEncodeRequestPayload(
    headers: [String: String],
    body: Data,
    sequence: UInt64?
) throws -> Data {
    var writer = SecureRuntimeBinaryWriter()
    writer.appendBytes(Array("LMCPREQ".utf8) + [1])
    writer.appendByte(1)
    if let sequence {
        guard sequence != 0 else { throw SecureRuntimeWireError.malformed }
        writer.appendByte(1)
        writer.appendUInt64(sequence)
    } else {
        writer.appendByte(0)
    }
    writer.appendUInt16(UInt16(headers.count))
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
        try writer.appendShortString(name)
        try writer.appendData(Data(value.utf8))
    }
    try writer.appendData(body)
    return writer.data
}

private func secureRuntimeParseResponsePayload(_ data: Data) throws -> SecureRuntimeInnerResponse {
    var reader = SecureRuntimeBinaryReader(data: data)
    guard try reader.readBytes(count: 8) == Array("LMCPRES".utf8) + [1] else {
        throw SecureRuntimeWireError.malformed
    }
    let status = Int(try reader.readUInt16())
    let headerCount = Int(try reader.readUInt16())
    var headers: [String: String] = [:]
    for _ in 0..<headerCount {
        let name = try reader.readShortString()
        let value = try reader.readData()
        guard let string = String(data: value, encoding: .utf8) else {
            throw SecureRuntimeWireError.malformed
        }
        headers[name] = string
    }
    let body = try reader.readData()
    guard reader.isAtEnd else { throw SecureRuntimeWireError.malformed }
    return SecureRuntimeInnerResponse(statusCode: status, headers: headers, body: body)
}

private struct SecureRuntimeBinaryWriter {
    private(set) var data = Data()

    mutating func appendByte(_ value: UInt8) {
        data.append(value)
    }

    mutating func appendBytes(_ value: [UInt8]) {
        data.append(contentsOf: value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        appendByte(UInt8(truncatingIfNeeded: value >> 8))
        appendByte(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32(_ value: UInt32) {
        appendByte(UInt8(truncatingIfNeeded: value >> 24))
        appendByte(UInt8(truncatingIfNeeded: value >> 16))
        appendByte(UInt8(truncatingIfNeeded: value >> 8))
        appendByte(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            appendByte(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func appendShortString(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= Int(UInt16.max) else { throw SecureRuntimeWireError.malformed }
        appendUInt16(UInt16(bytes.count))
        data.append(bytes)
    }

    mutating func appendData(_ value: Data) throws {
        guard value.count <= Int(UInt32.max) else { throw SecureRuntimeWireError.malformed }
        appendUInt32(UInt32(value.count))
        data.append(value)
    }
}

private struct SecureRuntimeBinaryReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { offset == data.count }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw SecureRuntimeWireError.malformed }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= data.count - count else {
            throw SecureRuntimeWireError.malformed
        }
        let range = offset..<(offset + count)
        offset += count
        return Array(data[range])
    }

    mutating func readUInt16() throws -> UInt16 {
        UInt16(try readByte()) << 8 | UInt16(try readByte())
    }

    mutating func readUInt32() throws -> UInt32 {
        UInt32(try readByte()) << 24 |
            UInt32(try readByte()) << 16 |
            UInt32(try readByte()) << 8 |
            UInt32(try readByte())
    }

    mutating func readShortString() throws -> String {
        let bytes = try readBytes(count: Int(try readUInt16()))
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw SecureRuntimeWireError.malformed
        }
        return string
    }

    mutating func readData() throws -> Data {
        Data(try readBytes(count: Int(try readUInt32())))
    }
}

private func secureRuntimeLengthPrefixed(_ fields: [[UInt8]]) -> Data {
    var writer = SecureRuntimeBinaryWriter()
    for field in fields {
        writer.appendUInt32(UInt32(field.count))
        writer.appendBytes(field)
    }
    return writer.data
}

private func secureRuntimeRandomBytes(count: Int) -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
}

private func secureRuntimeBase64URLEncode(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func secureRuntimeBase64URLDecode(_ value: String) -> [UInt8]? {
    guard !value.contains("=") else { return nil }
    let standard = value
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
    guard let data = Data(base64Encoded: padded) else { return nil }
    let bytes = [UInt8](data)
    return secureRuntimeBase64URLEncode(bytes) == value ? bytes : nil
}

private func secureRuntimeHTTPPost(
    path: String,
    port: UInt16,
    headers: [String: String],
    body: Data
) -> Data {
    var head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
    for key in headers.keys.sorted() {
        head += "\(key): \(headers[key]!)\r\n"
    }
    head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    var request = Data(head.utf8)
    request.append(body)
    return request
}

private func secureRuntimeHTTPStatus(_ data: Data) -> Int? {
    guard let firstLine = String(decoding: data, as: UTF8.self)
        .components(separatedBy: "\r\n")
        .first
    else { return nil }
    let pieces = firstLine.split(separator: " ")
    return pieces.count >= 2 ? Int(pieces[1]) : nil
}

private func secureRuntimeHTTPHeaders(_ data: Data) -> [String: String] {
    guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { return [:] }
    let head = String(decoding: data[..<boundary.lowerBound], as: UTF8.self)
    var headers: [String: String] = [:]
    for line in head.components(separatedBy: "\r\n").dropFirst() {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = line[..<colon].lowercased()
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        headers[name] = value
    }
    return headers
}

private func secureRuntimeHTTPBody(_ data: Data) -> Data? {
    guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    return Data(data[boundary.upperBound...])
}

private func secureRuntimeHTTPExchange(port: UInt16, request: Data) async throws -> Data {
    try await Task.detached {
        let descriptor = try secureRuntimeOpenLoopbackSocket(port: port)
        defer { Darwin.close(descriptor) }
        try secureRuntimeWriteAll(request, to: descriptor)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw SecureRuntimeWireError.malformed }
            response.append(contentsOf: buffer.prefix(count))
            guard response.count <= 2 * 1_024 * 1_024 else {
                throw SecureRuntimeWireError.malformed
            }
        }
        return response
    }.value
}

private func secureRuntimeOpenLoopbackSocket(port: UInt16) throws -> Int32 {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw SecureRuntimeWireError.malformed }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        Darwin.close(descriptor)
        throw SecureRuntimeWireError.malformed
    }
    return descriptor
}

private func secureRuntimeWriteAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        var sent = 0
        while sent < data.count {
            let count = Darwin.send(descriptor, base.advanced(by: sent), data.count - sent, 0)
            guard count > 0 else { throw SecureRuntimeWireError.malformed }
            sent += count
        }
    }
}

private func secureRuntimeCaptureListener(port: UInt16) throws -> Int32 {
    let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard listener >= 0 else { throw SecureRuntimeWireError.malformed }
    var reuse: Int32 = 1
    guard Darwin.setsockopt(
        listener,
        SOL_SOCKET,
        SO_REUSEADDR,
        &reuse,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        Darwin.close(listener)
        throw SecureRuntimeWireError.malformed
    }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, Darwin.listen(listener, 1) == 0 else {
        Darwin.close(listener)
        throw SecureRuntimeWireError.malformed
    }
    return listener
}

private func secureRuntimeCaptureOneRequest(listener: Int32) throws -> Data {
    defer { Darwin.close(listener) }
    let connection = Darwin.accept(listener, nil, nil)
    guard connection >= 0 else { throw SecureRuntimeWireError.malformed }
    defer { Darwin.close(connection) }

    var request = Data()
    var expectedLength: Int?
    var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
    while expectedLength.map({ request.count < $0 }) ?? true {
        let count = Darwin.recv(connection, &buffer, buffer.count, 0)
        guard count > 0 else { throw SecureRuntimeWireError.malformed }
        request.append(contentsOf: buffer.prefix(count))
        guard request.count <= 2 * 1_024 * 1_024 else {
            throw SecureRuntimeWireError.malformed
        }
        if expectedLength == nil,
           let boundary = request.range(of: Data("\r\n\r\n".utf8))
        {
            let headers = secureRuntimeHTTPHeaders(request)
            guard let contentLength = headers["content-length"].flatMap(Int.init) else {
                throw SecureRuntimeWireError.malformed
            }
            expectedLength = boundary.upperBound + contentLength
        }
    }
    try secureRuntimeWriteAll(
        Data(
            (
                "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\n" +
                    "Content-Length: 0\r\nConnection: close\r\n\r\n"
            ).utf8
        ),
        to: connection
    )
    return request
}
