import Foundation
import LocalMCPContracts
import LocalMCPMCPAdapter

/// Production Streamable HTTP transport bound exclusively to numeric IPv4
/// loopback. Port zero selects an ephemeral port; no public host/interface knob
/// exists.
public actor LocalMCPHTTPProducerTransport: LocalMCPSecureDescriptorServingTransport {
    private let requestedPort: UInt16
    private let handlerTimeout: TimeInterval
    private let maximumConcurrentConnections: Int
    private let maximumSessions: Int
    private var listener: NumericLoopbackHTTPListener?
    private var adapter: MCPWireServerAdapter?
    private var endpoint: LoopbackEndpoint?
    private var activeDescriptor: ProducerDescriptor?
    private var processSecurityContext: MCPProcessSecurityContext?
    private var startInProgress = false

    public init(
        port: UInt16 = 0,
        handlerTimeout: TimeInterval = 30,
        maximumConcurrentConnections: Int = 64,
        maximumSessions: Int = 128
    ) {
        requestedPort = port
        self.handlerTimeout = handlerTimeout
        self.maximumConcurrentConnections = maximumConcurrentConnections
        self.maximumSessions = maximumSessions
    }

    /// Fails closed because a production HTTP transport must be given the
    /// descriptor route through `LocalMCPDescriptorServingTransport`.
    public func start(
        endpointPath: String,
        service: any LocalMCPService
    ) async throws -> LoopbackEndpoint {
        throw LocalMCPError.invalidConfiguration
    }

    public func start(
        endpointPath: String,
        descriptorPath: String,
        descriptor: ProducerDescriptor,
        service: any LocalMCPService
    ) async throws -> LoopbackEndpoint {
        if let endpoint {
            guard activeDescriptor == descriptor else {
                throw LocalMCPError.invalidConfiguration
            }
            return endpoint
        }
        guard !startInProgress else { throw LocalMCPError.invalidLifecycleState }
        guard endpointPath == "/mcp",
              descriptorPath == "/local-mcp/v1/descriptor.json",
              descriptor.mcp.endpoint == endpointPath,
              let processSecurityContext,
              descriptor.channelBinding == processSecurityContext.channelBinding
        else { throw LocalMCPError.invalidConfiguration }

        let limits: MCPHTTPServerLimits
        do {
            limits = try MCPHTTPServerLimits(
                handlerTimeout: handlerTimeout,
                maximumConcurrentConnections: maximumConcurrentConnections,
                maximumSessions: maximumSessions
            )
        } catch {
            throw LocalMCPError.invalidConfiguration
        }
        let adapter = try MCPWireServerAdapter(
            service: service,
            descriptor: descriptor,
            processSecurityContext: processSecurityContext,
            descriptorPath: descriptorPath,
            limits: limits
        )
        let listener = NumericLoopbackHTTPListener(
            requestedPort: requestedPort,
            limits: limits
        ) { request, authority in
            await adapter.handle(request, expectedAuthority: authority)
        }
        self.adapter = adapter
        self.listener = listener
        startInProgress = true
        defer { startInProgress = false }

        do {
            let port = try await listener.start()
            if Task.isCancelled {
                await listener.stop()
                await adapter.stop()
                self.listener = nil
                self.adapter = nil
                throw LocalMCPError.cancelled
            }
            let endpoint = try LoopbackEndpoint(port: port, path: endpointPath)
            self.endpoint = endpoint
            activeDescriptor = descriptor
            return endpoint
        } catch {
            await listener.stop()
            await adapter.stop()
            self.listener = nil
            self.adapter = nil
            self.processSecurityContext = nil
            self.endpoint = nil
            self.activeDescriptor = nil
            if let error = error as? LocalMCPError { throw error }
            throw LocalMCPError.bindFailed
        }
    }

    public func stop() async {
        let listener = listener
        let adapter = adapter
        let processSecurityContext = processSecurityContext
        self.listener = nil
        self.adapter = nil
        self.processSecurityContext = nil
        endpoint = nil
        activeDescriptor = nil
        await adapter?.stop()
        await listener?.stop()
        await processSecurityContext?.destroy()
    }

    /// Creates exactly one process key for the next listener epoch. Repeated
    /// preparation before stop returns the same public binding; stop removes
    /// the private context so the following epoch necessarily rotates.
    public func prepareProcessChannelBinding() async throws -> ProducerChannelBinding {
        if let processSecurityContext {
            guard await processSecurityContext.isUsable else {
                throw LocalMCPError.invalidLifecycleState
            }
            return processSecurityContext.channelBinding
        }
        guard listener == nil, adapter == nil, endpoint == nil else {
            throw LocalMCPError.invalidLifecycleState
        }
        do {
            let context = try MCPProcessSecurityContext()
            processSecurityContext = context
            return context.channelBinding
        } catch {
            throw LocalMCPError.invalidConfiguration
        }
    }

    /// Useful for diagnostics/tests without exposing a configurable bind host.
    public var boundEndpoint: LoopbackEndpoint? { endpoint }
}
