import Foundation
import Testing

// The spawned producer advertises over the real system Bonjour daemon and the
// diagnostic CLI must rediscover it; hosted CI runners restrict mDNSResponder,
// so this suite runs only outside CI environments.
@Suite(
    "Separate-process HTTP example",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil)
)
struct SeparateProcessIntegrationTests {
    @Test("Producer and consumer complete an authenticated MCP call in distinct processes")
    func producerConsumerFlow() async throws {
        let producerURL = try builtExecutable(named: "local-mcp-example-producer")
        let consumerURL = try builtExecutable(named: "local-mcp-example-consumer")
        let diagnosticURL = try builtExecutable(named: "local-mcp")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-mcp-process-test-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let rendezvous = directory.appendingPathComponent("grant.json")

        let producer = Process()
        producer.executableURL = producerURL
        producer.arguments = [
            "--preissued-dev-grant",
            "--rendezvous", rendezvous.path,
        ]
        let producerInput = Pipe()
        let producerOutput = Pipe()
        let producerError = Pipe()
        producer.standardInput = producerInput
        producer.standardOutput = producerOutput
        producer.standardError = producerError
        try producer.run()

        do {
            try await waitForFile(rendezvous, producer: producer, timeout: 10)
            let attributes = try FileManager.default.attributesOfItem(atPath: rendezvous.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
            let secretDocument = try Data(contentsOf: rendezvous)
            let secretJSON = try #require(
                JSONSerialization.jsonObject(with: secretDocument) as? [String: Any]
            )
            let seededToken = try #require(secretJSON["accessToken"] as? String)
            #expect(!seededToken.isEmpty)

            let diagnostic = Process()
            diagnostic.executableURL = diagnosticURL
            diagnostic.arguments = ["discover", "--timeout", "3", "--json"]
            let diagnosticOutput = Pipe()
            let diagnosticError = Pipe()
            diagnostic.standardOutput = diagnosticOutput
            diagnostic.standardError = diagnosticError
            try diagnostic.run()
            try await waitForExit(diagnostic, timeout: 8)

            let diagnosticStdout = readAll(diagnosticOutput)
            let diagnosticStderr = readAll(diagnosticError)
            #expect(diagnostic.terminationStatus == 0, Comment(rawValue: diagnosticStderr))
            #expect(diagnosticStderr.isEmpty)
            #expect(!diagnosticStdout.contains(seededToken))
            let discovered = try #require(
                JSONSerialization.jsonObject(with: Data(diagnosticStdout.utf8)) as? [[String: Any]]
            )
            #expect(discovered.contains {
                $0["stableID"] as? String == "com.example.localmcp.separate-producer"
            })

            let consumer = Process()
            consumer.executableURL = consumerURL
            consumer.arguments = [
                "--preissued-dev-grant",
                "--rendezvous", rendezvous.path,
            ]
            let consumerOutput = Pipe()
            let consumerError = Pipe()
            consumer.standardOutput = consumerOutput
            consumer.standardError = consumerError
            try consumer.run()
            try await waitForExit(consumer, timeout: 15)

            let consumerStdout = readAll(consumerOutput)
            let consumerStderr = readAll(consumerError)
            #expect(consumer.terminationStatus == 0, Comment(rawValue: consumerStderr))
            #expect(consumerStderr.isEmpty)
            #expect(!consumerStdout.contains(seededToken))
            #expect(!FileManager.default.fileExists(atPath: rendezvous.path))

            let result = try #require(
                JSONSerialization.jsonObject(with: Data(consumerStdout.utf8)) as? [String: Any]
            )
            #expect(result["producerID"] as? String == "com.example.localmcp.separate-producer")
            #expect(result["protocolVersion"] as? String == "2025-11-25")
            #expect(result["tools"] as? [String] == ["example.echo"])
            #expect(result["result"] as? String == "hello across processes")

            producerInput.fileHandleForWriting.write(Data("\n".utf8))
            try producerInput.fileHandleForWriting.close()
            try await waitForExit(producer, timeout: 10)

            let producerStdout = readAll(producerOutput)
            let producerStderr = readAll(producerError)
            #expect(producer.terminationStatus == 0, Comment(rawValue: producerStderr))
            #expect(producerStderr.isEmpty)
            #expect(producerStdout.contains("ready com.example.localmcp.separate-producer"))
            #expect(!producerStdout.contains(seededToken))
        } catch {
            if producer.isRunning {
                producerInput.fileHandleForWriting.write(Data("\n".utf8))
                try? producerInput.fileHandleForWriting.close()
                try? await waitForExit(producer, timeout: 3)
                if producer.isRunning { producer.terminate() }
            }
            throw error
        }
    }

    @Test("A restarted producer process publishes a rotated channel binding and instance")
    func processKeyRotationAcrossRestarts() async throws {
        let first = try await launchProducerAndReadIdentity()
        let second = try await launchProducerAndReadIdentity()

        // Every producer process derives a fresh X25519 process key, so a
        // binding captured from one process never matches its successor and
        // any grant bound to the old instance fails closed after a restart.
        #expect(!first.channelBindingPublicKey.isEmpty)
        #expect(!second.channelBindingPublicKey.isEmpty)
        #expect(first.channelBindingPublicKey != second.channelBindingPublicKey)
        #expect(first.instanceID != second.instanceID)
        #expect(first.accessToken != second.accessToken)
    }

    private struct ProducerProcessIdentity {
        let instanceID: String
        let channelBindingPublicKey: String
        let accessToken: String
    }

    private func launchProducerAndReadIdentity() async throws -> ProducerProcessIdentity {
        let producerURL = try builtExecutable(named: "local-mcp-example-producer")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-mcp-rotation-test-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let rendezvous = directory.appendingPathComponent("grant.json")

        let producer = Process()
        producer.executableURL = producerURL
        producer.arguments = ["--preissued-dev-grant", "--rendezvous", rendezvous.path]
        let input = Pipe()
        producer.standardInput = input
        producer.standardOutput = Pipe()
        producer.standardError = Pipe()
        try producer.run()
        do {
            try await waitForFile(rendezvous, producer: producer, timeout: 10)
            let document = try JSONSerialization.jsonObject(
                with: try Data(contentsOf: rendezvous)
            ) as? [String: Any]
            let instance = document?["instance"] as? [String: Any]
            let binding = instance?["channelBinding"] as? [String: Any]
            let identity = ProducerProcessIdentity(
                instanceID: instance?["instanceId"] as? String ?? "",
                channelBindingPublicKey: binding?["publicKey"] as? String ?? "",
                accessToken: document?["accessToken"] as? String ?? ""
            )
            input.fileHandleForWriting.write(Data("\n".utf8))
            try input.fileHandleForWriting.close()
            try await waitForExit(producer, timeout: 10)
            #expect(producer.terminationStatus == 0)
            return identity
        } catch {
            if producer.isRunning {
                input.fileHandleForWriting.write(Data("\n".utf8))
                try? input.fileHandleForWriting.close()
                try? await waitForExit(producer, timeout: 3)
                if producer.isRunning { producer.terminate() }
            }
            throw error
        }
    }

    @Test("Development grant mode must be explicitly enabled")
    func preissuedModeIsExplicit() async throws {
        let producer = Process()
        producer.executableURL = try builtExecutable(named: "local-mcp-example-producer")
        let output = Pipe()
        let error = Pipe()
        producer.standardOutput = output
        producer.standardError = error
        try producer.run()
        try await waitForExit(producer, timeout: 5)

        #expect(producer.terminationStatus == 2)
        #expect(readAll(output).isEmpty)
        let message = readAll(error)
        #expect(message.contains("--preissued-dev-grant"))
        #expect(!message.localizedCaseInsensitiveContains("token"))
        #expect(!message.localizedCaseInsensitiveContains("credential"))
    }

    private func waitForFile(_ url: URL, producer: Process, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            if !producer.isRunning {
                throw ProcessTestError("The producer exited before publishing its rendezvous file.")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ProcessTestError("Timed out waiting for the producer rendezvous file.")
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !process.isRunning else {
            process.terminate()
            throw ProcessTestError("Timed out waiting for a subprocess to exit.")
        }
    }

    private func readAll(_ pipe: Pipe) -> String {
        String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func builtExecutable(named name: String) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let productsDirectory = environment["BUILT_PRODUCTS_DIR"] {
            let candidate = URL(fileURLWithPath: productsDirectory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }

        var directory = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let knownBuildDirectories = [
            ".build/debug",
            ".build/arm64-apple-macosx/debug",
            ".build/x86_64-apple-macosx/debug",
            ".build/out/Products/Debug",
        ]
        for relativeDirectory in knownBuildDirectories {
            let candidate = repository
                .appendingPathComponent(relativeDirectory, isDirectory: true)
                .appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw ProcessTestError("The built \(name) executable could not be located.")
    }
}

private struct ProcessTestError: Error, CustomStringConvertible, Sendable {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
