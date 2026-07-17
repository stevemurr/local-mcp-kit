import Foundation
import LocalMCPContracts
import Testing
@testable import LocalMCPDiscoveryBonjour

@Suite("Bonjour descriptor response validation")
struct BonjourDescriptorLoaderTests {
    private let requestedURL = URL(
        string: "http://127.0.0.1:49152/local-mcp/v1/descriptor.json"
    )!

    private func descriptorData(extraTopLevel: String = "") throws -> Data {
        let suffix = extraTopLevel.isEmpty ? "" : ",\(extraTopLevel)"
        return Data(
            """
            {"schemaVersion":"1","instanceId":"90f3fc7c-b047-4af2-bac1-33b5b0563d16","server":{"id":"com.example.bonjour-producer","name":"Bonjour Producer","version":"1.0.0"},"mcp":{"transport":"localmcp-secure-http","endpoint":"/mcp","protocolVersions":["2025-11-25"],"authentication":"pairing-channel"},"capabilities":{"tools":true},"channelBinding":{"suite":"x25519-hkdf-sha256-chacha20poly1305-v1","publicKey":"UlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlI"}\(suffix)}
            """.utf8
        )
    }

    @Test("A bounded JSON response decodes and ignores additive members")
    func validResponse() throws {
        let data = try descriptorData(extraTopLevel: "\"future\":{\"enabled\":true}")
        let descriptor = try URLSessionBonjourDescriptorLoader.decodeDescriptorResponse(
            data,
            requestedURL: requestedURL,
            responseURL: requestedURL,
            statusCode: 200,
            contentType: "application/json; charset=utf-8",
            expectedContentLength: Int64(data.count)
        )

        #expect(descriptor == bonjourTestDescriptor())
    }

    @Test("Redirects, errors, and wrong content types fail closed")
    func responseContextValidation() throws {
        let data = try descriptorData()
        let redirectURL = URL(
            string: "http://127.0.0.1:49153/local-mcp/v1/descriptor.json"
        )!
        #expect(throws: BonjourDescriptorLoadingError.redirectOrUnexpectedResponse) {
            try URLSessionBonjourDescriptorLoader.decodeDescriptorResponse(
                data,
                requestedURL: requestedURL,
                responseURL: redirectURL,
                statusCode: 200,
                contentType: "application/json",
                expectedContentLength: Int64(data.count)
            )
        }
        #expect(throws: BonjourDescriptorLoadingError.redirectOrUnexpectedResponse) {
            try URLSessionBonjourDescriptorLoader.decodeDescriptorResponse(
                data,
                requestedURL: requestedURL,
                responseURL: requestedURL,
                statusCode: 302,
                contentType: "application/json",
                expectedContentLength: Int64(data.count)
            )
        }
        #expect(throws: BonjourDescriptorLoadingError.invalidContentType) {
            try URLSessionBonjourDescriptorLoader.decodeDescriptorResponse(
                data,
                requestedURL: requestedURL,
                responseURL: requestedURL,
                statusCode: 200,
                contentType: "text/html",
                expectedContentLength: Int64(data.count)
            )
        }
    }

    @Test("Declared and streamed descriptor sizes are independently bounded")
    func responseSizeLimits() throws {
        let data = try descriptorData()
        #expect(throws: BonjourDescriptorLoadingError.responseTooLarge) {
            try URLSessionBonjourDescriptorLoader.decodeDescriptorResponse(
                data,
                requestedURL: requestedURL,
                responseURL: requestedURL,
                statusCode: 200,
                contentType: "application/json",
                expectedContentLength: Int64(URLSessionBonjourDescriptorLoader.maximumResponseSize + 1)
            )
        }
        #expect(throws: BonjourDescriptorLoadingError.responseTooLarge) {
            try URLSessionBonjourDescriptorLoader.decodeDescriptorResponse(
                Data(repeating: UInt8(ascii: " "), count: URLSessionBonjourDescriptorLoader.maximumResponseSize + 1),
                requestedURL: requestedURL,
                responseURL: requestedURL,
                statusCode: 200,
                contentType: "application/json",
                expectedContentLength: -1
            )
        }
    }

    @Test("Duplicate object keys are rejected, including escaped aliases")
    func duplicateKeys() throws {
        let duplicateTopLevel = Data(
            """
            {"schemaVersion":"1","schemaVersion":"1","instanceId":"90f3fc7c-b047-4af2-bac1-33b5b0563d16","server":{"id":"com.example.bonjour-producer","name":"Bonjour Producer","version":"1.0.0"},"mcp":{"transport":"localmcp-secure-http","endpoint":"/mcp","protocolVersions":["2025-11-25"],"authentication":"pairing-channel"},"capabilities":{"tools":true},"channelBinding":{"suite":"x25519-hkdf-sha256-chacha20poly1305-v1","publicKey":"UlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlI"}}
            """.utf8
        )
        let escapedAlias = Data(
            """
            {"schemaVersion":"1","instanceId":"90f3fc7c-b047-4af2-bac1-33b5b0563d16","server":{"id":"com.example.bonjour-producer","\\u0069d":"com.example.bonjour-producer","name":"Bonjour Producer","version":"1.0.0"},"mcp":{"transport":"localmcp-secure-http","endpoint":"/mcp","protocolVersions":["2025-11-25"],"authentication":"pairing-channel"},"capabilities":{"tools":true},"channelBinding":{"suite":"x25519-hkdf-sha256-chacha20poly1305-v1","publicKey":"UlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlI"}}
            """.utf8
        )

        for data in [duplicateTopLevel, escapedAlias] {
            #expect(throws: (any Error).self) {
                try URLSessionBonjourDescriptorLoader.decodeDescriptorResponse(
                    data,
                    requestedURL: requestedURL,
                    responseURL: requestedURL,
                    statusCode: 200,
                    contentType: "application/json",
                    expectedContentLength: Int64(data.count)
                )
            }
        }
    }

    @Test("Strict descriptor JSON parsing rejects excessive nesting")
    func nestingDepthLimit() throws {
        let accepted = Data(
            (String(repeating: "[", count: 64) + "0" + String(repeating: "]", count: 64)).utf8
        )
        let rejected = Data(
            (String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)).utf8
        )

        try StrictJSONDuplicateKeyValidator.validate(accepted)
        #expect(throws: BonjourDescriptorLoadingError.invalidJSON) {
            try StrictJSONDuplicateKeyValidator.validate(rejected)
        }
    }

    @Test("Only the exact numeric-loopback descriptor URL is accepted")
    func urlPolicy() async {
        let loader = URLSessionBonjourDescriptorLoader()
        let invalidURLs = [
            "http://localhost:49152/local-mcp/v1/descriptor.json",
            "http://192.168.1.2:49152/local-mcp/v1/descriptor.json",
            "http://127.0.0.1:49152/other.json",
            "https://127.0.0.1:49152/local-mcp/v1/descriptor.json",
            "http://user@127.0.0.1:49152/local-mcp/v1/descriptor.json",
            "http://127.0.0.1:49152/local-mcp/v1/descriptor.json?query=1",
        ]

        for value in invalidURLs {
            do {
                _ = try await loader.loadDescriptor(from: URL(string: value)!)
                Issue.record("Accepted invalid descriptor URL: \(value)")
            } catch let error as BonjourDescriptorLoadingError {
                #expect(error == .invalidURL)
            } catch {
                Issue.record("Unexpected error type for \(value): \(type(of: error))")
            }
        }
    }

    @Test("Descriptor sessions explicitly disable every system proxy path")
    func proxyPolicy() throws {
        let configuration = URLSessionBonjourDescriptorLoader.makeSessionConfiguration()
        let proxyDictionary = try #require(configuration.connectionProxyDictionary)
        let expectedKeys = [
            "HTTPEnable",
            "HTTPSEnable",
            "SOCKSEnable",
            "ProxyAutoConfigEnable",
            "ProxyAutoDiscoveryEnable",
        ]

        #expect(Set(proxyDictionary.keys.compactMap { $0 as? String }) == Set(expectedKeys))
        for key in expectedKeys {
            let value = try #require(proxyDictionary[key] as? NSNumber)
            #expect(!value.boolValue)
        }
    }

    @Test("A slow-drip response cannot extend the hard transfer deadline")
    func slowDripHardDeadline() async throws {
        let server = try SlowDripLoopbackServer()
        let url = URL(
            string: "http://127.0.0.1:\(server.port)/local-mcp/v1/descriptor.json"
        )!
        let loader = URLSessionBonjourDescriptorLoader(hardDeadline: 0.15)
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await loader.loadDescriptor(from: url)
            Issue.record("A continuously active slow-drip response escaped the hard deadline.")
        } catch let error as BonjourDescriptorLoadingError {
            #expect(error == .timedOut)
        } catch {
            Issue.record("Unexpected slow-drip error: \(error)")
        }

        #expect(started.duration(to: clock.now) < .seconds(2))
        #expect(await eventually { server.clientDisconnected })
        await server.stop()
    }

    @Test("Caller cancellation closes a descriptor transfer immediately")
    func cancellationClosesTransfer() async throws {
        let server = try SlowDripLoopbackServer()
        let url = URL(
            string: "http://127.0.0.1:\(server.port)/local-mcp/v1/descriptor.json"
        )!
        let loader = URLSessionBonjourDescriptorLoader()
        let loading = Task {
            try await loader.loadDescriptor(from: url)
        }
        #expect(await eventually { server.clientConnected })

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        loading.cancel()
        do {
            _ = try await loading.value
            Issue.record("Cancelled descriptor transfer returned a value.")
        } catch is CancellationError {
            // Expected stable cancellation surface.
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }

        #expect(cancelledAt.duration(to: clock.now) < .seconds(2))
        #expect(await eventually { server.clientDisconnected })
        await server.stop()
    }
}
