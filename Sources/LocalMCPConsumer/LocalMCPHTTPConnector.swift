import Foundation
import LocalMCPContracts
import LocalMCPMCPAdapter

/// Resolves a validated discovery instance to an authenticated, channel-bound
/// LocalMCP secure HTTP connection over numeric IPv4 loopback.
public struct LocalMCPHTTPConnector: LocalMCPConnecting {
    private let requestTimeout: TimeInterval
    private let maximumResponseBytes: Int

    public init(
        requestTimeout: TimeInterval = 35,
        maximumResponseBytes: Int = 1_024 * 1_024
    ) {
        self.requestTimeout = requestTimeout
        self.maximumResponseBytes = maximumResponseBytes
    }

    public func connect(to instance: ProducerInstance) async throws -> any LocalMCPService {
        guard instance.endpoint.path == "/mcp",
              instance.descriptorURL.port == instance.endpoint.port,
              instance.descriptorURL.path == "/local-mcp/v1/descriptor.json",
              instance.channelBinding?.isSupported == true,
              case .compatible = instance.compatibility
        else { throw LocalMCPError.invalidConfiguration }
        do {
            return try MCPWireClientService(
                instance: instance,
                requestTimeout: requestTimeout,
                maximumResponseBytes: maximumResponseBytes
            )
        } catch let error as LocalMCPError {
            throw error
        } catch {
            throw LocalMCPError.producerUnavailable
        }
    }
}
