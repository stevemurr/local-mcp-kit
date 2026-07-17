import Foundation
import LocalMCPContracts

enum BonjourTXTRecordError: Error, Sendable, Equatable {
    case invalidAdvertisement
    case malformedRecord
    case recordTooLarge
}

/// Strict DNS-SD TXT codec for the fixed LocalMCPKit V1 discovery profile.
///
/// The wire order is deterministic to keep diagnostics and conformance fixtures
/// stable. Readers accept additive unknown keys, but reject duplicate, uppercase,
/// non-UTF-8, malformed, and oversized entries before interpreting required keys.
enum BonjourTXTRecordCodec {
    static let maximumEncodedLength = 512
    static let requiredKeyOrder = ["v", "id", "path", "desc", "auth"]

    static func encode(_ advertisement: DiscoveryAdvertisement) throws -> Data {
        let values = advertisement.txtValues
        do {
            _ = try DiscoveryAdvertisement(txtValues: values)
        } catch {
            throw BonjourTXTRecordError.invalidAdvertisement
        }

        var data = Data()
        for key in requiredKeyOrder {
            guard let value = values[key] else {
                throw BonjourTXTRecordError.invalidAdvertisement
            }
            let entry = Data("\(key)=\(value)".utf8)
            guard !entry.isEmpty, entry.count <= Int(UInt8.max) else {
                throw BonjourTXTRecordError.recordTooLarge
            }
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        guard data.count <= maximumEncodedLength else {
            throw BonjourTXTRecordError.recordTooLarge
        }
        return data
    }

    static func decode(_ data: Data) throws -> DiscoveryAdvertisement {
        let values = try decodeValues(data)
        do {
            return try DiscoveryAdvertisement(txtValues: values)
        } catch {
            throw BonjourTXTRecordError.invalidAdvertisement
        }
    }

    static func decodeValues(_ data: Data) throws -> [String: String] {
        guard !data.isEmpty, data.count <= maximumEncodedLength else {
            throw data.count > maximumEncodedLength
                ? BonjourTXTRecordError.recordTooLarge
                : BonjourTXTRecordError.malformedRecord
        }

        let bytes = [UInt8](data)
        var offset = 0
        var values: [String: String] = [:]

        while offset < bytes.count {
            let length = Int(bytes[offset])
            offset += 1
            guard length > 0, offset + length <= bytes.count else {
                throw BonjourTXTRecordError.malformedRecord
            }

            let entryBytes = bytes[offset ..< offset + length]
            offset += length
            guard let entry = String(bytes: entryBytes, encoding: .utf8),
                  let separator = entry.firstIndex(of: "=")
            else {
                throw BonjourTXTRecordError.malformedRecord
            }

            let key = String(entry[..<separator])
            let value = String(entry[entry.index(after: separator)...])
            guard isValidKey(key), values.updateValue(value, forKey: key) == nil else {
                throw BonjourTXTRecordError.malformedRecord
            }
        }

        return values
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        return key.utf8.allSatisfy { byte in
            (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) ||
                (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) ||
                byte == UInt8(ascii: "-")
        }
    }
}
