import Foundation
import LocalMCPContracts
import Testing
@testable import LocalMCPDiscoveryBonjour

@Suite("System Bonjour LocalOnly integration", .serialized)
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
        try await withThrowingTaskGroup(of: (any BonjourDNSServiceOperation).self) { group in
            group.addTask {
                try await backend.register(request) { _ in }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw Timeout.registration
            }
            guard let operation = try await group.next() else {
                throw Timeout.registration
            }
            group.cancelAll()
            return operation
        }
    }
}
