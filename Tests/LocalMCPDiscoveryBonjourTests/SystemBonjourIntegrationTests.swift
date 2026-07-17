import Foundation
import LocalMCPContracts
import Testing
@testable import LocalMCPDiscoveryBonjour

// Hosted CI runners restrict mDNSResponder, so a real registration callback
// may never arrive there. The suite requires a real local Bonjour daemon and
// therefore runs only outside CI environments.
@Suite(
    "System Bonjour LocalOnly integration",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil)
)
struct SystemBonjourIntegrationTests {
    @Test("A real LocalOnly registration is visible to a real LocalOnly browser")
    func registerAndBrowse() async throws {
        let backend = SystemBonjourDNSServiceBackend()
        let recorder = BonjourEventRecorder()
        let serviceName = "LocalMCP-Test-\(UUID().uuidString)"
        let browser = try backend.browse(
            serviceType: DiscoveryAdvertisement.serviceType,
            interfaceIndex: bonjourLocalOnlyInterfaceIndex
        ) { event in
            Task { await recorder.append(event) }
        }
        defer { browser.cancel() }

        let txtRecord = try BonjourTXTRecordCodec.encode(
            DiscoveryAdvertisement(stableProducerID: bonjourTestProducer.stableID)
        )
        let registration = try await registerWithTimeout(
            backend,
            request: BonjourRegistrationRequest(
                name: serviceName,
                serviceType: DiscoveryAdvertisement.serviceType,
                interfaceIndex: bonjourLocalOnlyInterfaceIndex,
                port: 49_152,
                txtRecord: txtRecord
            )
        )
        defer { registration.cancel() }

        let found = await eventually(timeout: .seconds(5)) {
            await recorder.events().contains { event in
                guard case let .added(service) = event else { return false }
                return service.name == serviceName
                    && service.interfaceIndex == bonjourLocalOnlyInterfaceIndex
                    && service.serviceType.hasPrefix(DiscoveryAdvertisement.serviceType)
            }
        }
        let events = await recorder.events()
        #expect(found, "Observed browse events: \(events)")
    }

    private enum Timeout: Error { case registration }

    private func registerWithTimeout(
        _ backend: SystemBonjourDNSServiceBackend,
        request: BonjourRegistrationRequest
    ) async throws -> any BonjourDNSServiceOperation {
        // The timeout must not join a registration whose daemon callback
        // never arrives; a task group would await the hung child forever.
        let operation = LocalMCPAsyncOperation<any BonjourDNSServiceOperation>(
            timeoutAfter: 5,
            timeoutError: Timeout.registration
        ) {
            try await backend.register(request) { _ in }
        }
        return try await operation.value(cancellationError: Timeout.registration)
    }
}
