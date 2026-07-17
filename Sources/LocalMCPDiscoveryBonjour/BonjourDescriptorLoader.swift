import Foundation
import LocalMCPContracts

protocol BonjourDescriptorLoading: Sendable {
    func loadDescriptor(from url: URL) async throws -> ProducerDescriptor
}

enum BonjourDescriptorLoadingError: Error, Sendable, Equatable {
    case invalidURL
    case redirectOrUnexpectedResponse
    case responseTooLarge
    case invalidContentType
    case invalidJSON
    case timedOut
}

struct URLSessionBonjourDescriptorLoader: BonjourDescriptorLoading {
    static let maximumResponseSize = 64 * 1_024
    static let productionHardDeadline: TimeInterval = 10
    static var disabledProxyConfiguration: [AnyHashable: Any] {
        [
            // Use the stable CFNetwork dictionary key strings rather than the
            // newer typed constants so the package remains compatible with its
            // macOS 13 deployment target.
            "HTTPEnable": false,
            "HTTPSEnable": false,
            "SOCKSEnable": false,
            "ProxyAutoConfigEnable": false,
            "ProxyAutoDiscoveryEnable": false,
        ]
    }

    private let hardDeadline: TimeInterval

    init(hardDeadline: TimeInterval = productionHardDeadline) {
        precondition(hardDeadline >= 0 && hardDeadline.isFinite)
        self.hardDeadline = hardDeadline
    }

    func loadDescriptor(from url: URL) async throws -> ProducerDescriptor {
        guard url.scheme == "http",
              url.host == "127.0.0.1",
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path == "/local-mcp/v1/descriptor.json"
        else {
            throw BonjourDescriptorLoadingError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(nil, forHTTPHeaderField: "Origin")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10

        let delegate = RejectRedirectsDelegate()
        let configuration = Self.makeSessionConfiguration()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        // URLRequest.timeoutInterval is an inactivity timeout. It cannot bound
        // a peer that continuously drips bytes, so race the complete transfer
        // (headers, body, and bounded decode) against a wall-clock deadline.
        // LocalMCPAsyncOperation releases this caller without joining a losing,
        // cancellation-insensitive child; invalidating the session below also
        // closes the underlying URLSession task on every exit path.
        let immutableRequest = request
        let transfer = LocalMCPAsyncOperation<ProducerDescriptor>(
            timeoutAfter: hardDeadline,
            timeoutError: BonjourDescriptorLoadingError.timedOut
        ) {
            try await Self.fetchDescriptor(session: session, request: immutableRequest, url: url)
        }
        do {
            let descriptor = try await transfer.value()
            session.invalidateAndCancel()
            return descriptor
        } catch {
            session.invalidateAndCancel()
            if error is CancellationError { throw CancellationError() }
            if let loadingError = error as? BonjourDescriptorLoadingError {
                throw loadingError
            }
            throw BonjourDescriptorLoadingError.redirectOrUnexpectedResponse
        }
    }

    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Numeric-loopback traffic is a host-local security boundary. Never
        // inherit HTTP, HTTPS, SOCKS, PAC, or WPAD settings that could route a
        // descriptor request through another process or off the machine.
        configuration.connectionProxyDictionary = disabledProxyConfiguration
        return configuration
    }

    private static func fetchDescriptor(
        session: URLSession,
        request: URLRequest,
        url: URL
    ) async throws -> ProducerDescriptor {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw BonjourDescriptorLoadingError.timedOut
        } catch {
            throw BonjourDescriptorLoadingError.redirectOrUnexpectedResponse
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              httpResponse.url == url
        else {
            throw BonjourDescriptorLoadingError.redirectOrUnexpectedResponse
        }
        guard let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              contentType == "application/json"
        else {
            throw BonjourDescriptorLoadingError.invalidContentType
        }
        if response.expectedContentLength > Int64(Self.maximumResponseSize) {
            throw BonjourDescriptorLoadingError.responseTooLarge
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), Self.maximumResponseSize))
        }
        do {
            for try await byte in bytes {
                guard data.count < Self.maximumResponseSize else {
                    throw BonjourDescriptorLoadingError.responseTooLarge
                }
                data.append(byte)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BonjourDescriptorLoadingError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw BonjourDescriptorLoadingError.timedOut
        } catch {
            throw BonjourDescriptorLoadingError.redirectOrUnexpectedResponse
        }

        do {
            return try Self.decodeDescriptorResponse(
                data,
                requestedURL: url,
                responseURL: httpResponse.url,
                statusCode: httpResponse.statusCode,
                contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"),
                expectedContentLength: response.expectedContentLength
            )
        } catch {
            throw BonjourDescriptorLoadingError.invalidJSON
        }
    }

    static func decodeDescriptorResponse(
        _ data: Data,
        requestedURL: URL,
        responseURL: URL?,
        statusCode: Int,
        contentType: String?,
        expectedContentLength: Int64
    ) throws -> ProducerDescriptor {
        guard statusCode == 200, responseURL == requestedURL else {
            throw BonjourDescriptorLoadingError.redirectOrUnexpectedResponse
        }
        guard let normalizedContentType = contentType?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              normalizedContentType == "application/json"
        else {
            throw BonjourDescriptorLoadingError.invalidContentType
        }
        guard expectedContentLength <= Int64(Self.maximumResponseSize),
              data.count <= Self.maximumResponseSize
        else {
            throw BonjourDescriptorLoadingError.responseTooLarge
        }
        try StrictJSONDuplicateKeyValidator.validate(data)
        return try JSONDecoder().decode(ProducerDescriptor.self, from: data)
    }
}

private final class RejectRedirectsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Validates JSON syntax while retaining object member occurrence information,
/// which `JSONDecoder`'s keyed containers intentionally erase.
package enum StrictJSONDuplicateKeyValidator {
    package static func validate(_ data: Data) throws {
        var parser = Parser(bytes: [UInt8](data))
        try parser.parseDocument()
    }

    private struct Parser {
        static let maximumNestingDepth = 64
        let bytes: [UInt8]
        var offset = 0

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            guard offset == bytes.count else { throw BonjourDescriptorLoadingError.invalidJSON }
        }

        mutating func parseValue(depth: Int) throws {
            guard depth <= Self.maximumNestingDepth, offset < bytes.count else {
                throw BonjourDescriptorLoadingError.invalidJSON
            }
            switch bytes[offset] {
            case UInt8(ascii: "{"):
                try parseObject(depth: depth)
            case UInt8(ascii: "["):
                try parseArray(depth: depth)
            case UInt8(ascii: "\""):
                _ = try parseString()
            case UInt8(ascii: "t"):
                try consumeLiteral("true")
            case UInt8(ascii: "f"):
                try consumeLiteral("false")
            case UInt8(ascii: "n"):
                try consumeLiteral("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"):
                try parseNumber()
            default:
                throw BonjourDescriptorLoadingError.invalidJSON
            }
        }

        mutating func parseObject(depth: Int) throws {
            offset += 1
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return }

            var keys: Set<String> = []
            while true {
                skipWhitespace()
                let key = try parseString()
                guard keys.insert(key).inserted else {
                    throw BonjourDescriptorLoadingError.invalidJSON
                }
                skipWhitespace()
                guard consume(UInt8(ascii: ":")) else {
                    throw BonjourDescriptorLoadingError.invalidJSON
                }
                skipWhitespace()
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consume(UInt8(ascii: "}")) { return }
                guard consume(UInt8(ascii: ",")) else {
                    throw BonjourDescriptorLoadingError.invalidJSON
                }
            }
        }

        mutating func parseArray(depth: Int) throws {
            offset += 1
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return }
            while true {
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consume(UInt8(ascii: "]")) { return }
                guard consume(UInt8(ascii: ",")) else {
                    throw BonjourDescriptorLoadingError.invalidJSON
                }
                skipWhitespace()
            }
        }

        mutating func parseString() throws -> String {
            let start = offset
            guard consume(UInt8(ascii: "\"")) else {
                throw BonjourDescriptorLoadingError.invalidJSON
            }
            var escaped = false
            while offset < bytes.count {
                let byte = bytes[offset]
                offset += 1
                if escaped {
                    escaped = false
                    if byte == UInt8(ascii: "u") {
                        guard offset + 4 <= bytes.count,
                              bytes[offset ..< offset + 4].allSatisfy(Self.isHexDigit)
                        else { throw BonjourDescriptorLoadingError.invalidJSON }
                        offset += 4
                    } else if !["\"", "\\", "/", "b", "f", "n", "r", "t"]
                        .map(UInt8.init(ascii:)).contains(byte)
                    {
                        throw BonjourDescriptorLoadingError.invalidJSON
                    }
                    continue
                }
                if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    let encoded = Data(bytes[start ..< offset])
                    return try JSONDecoder().decode(String.self, from: encoded)
                } else if byte < 0x20 {
                    throw BonjourDescriptorLoadingError.invalidJSON
                }
            }
            throw BonjourDescriptorLoadingError.invalidJSON
        }

        mutating func parseNumber() throws {
            if consume(UInt8(ascii: "-")), offset == bytes.count {
                throw BonjourDescriptorLoadingError.invalidJSON
            }
            if consume(UInt8(ascii: "0")) {
                if offset < bytes.count,
                   (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[offset])
                {
                    throw BonjourDescriptorLoadingError.invalidJSON
                }
            } else {
                try consumeDigits(requireAtLeastOne: true)
            }
            if consume(UInt8(ascii: ".")) {
                try consumeDigits(requireAtLeastOne: true)
            }
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "e") || bytes[offset] == UInt8(ascii: "E") {
                offset += 1
                if offset < bytes.count, bytes[offset] == UInt8(ascii: "+") || bytes[offset] == UInt8(ascii: "-") {
                    offset += 1
                }
                try consumeDigits(requireAtLeastOne: true)
            }
        }

        mutating func consumeDigits(requireAtLeastOne: Bool) throws {
            let start = offset
            while offset < bytes.count,
                  (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[offset])
            {
                offset += 1
            }
            if requireAtLeastOne, offset == start {
                throw BonjourDescriptorLoadingError.invalidJSON
            }
        }

        mutating func consumeLiteral(_ literal: StaticString) throws {
            let literalBytes = Array("\(literal)".utf8)
            guard offset + literalBytes.count <= bytes.count,
                  Array(bytes[offset ..< offset + literalBytes.count]) == literalBytes
            else { throw BonjourDescriptorLoadingError.invalidJSON }
            offset += literalBytes.count
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard offset < bytes.count, bytes[offset] == byte else { return false }
            offset += 1
            return true
        }

        mutating func skipWhitespace() {
            while offset < bytes.count,
                  [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")]
                    .contains(bytes[offset])
            {
                offset += 1
            }
        }

        static func isHexDigit(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte) ||
                (UInt8(ascii: "A") ... UInt8(ascii: "F")).contains(byte)
        }
    }
}
