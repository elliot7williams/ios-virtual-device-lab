import Foundation

public struct HTTPFixture: Codable, Sendable {
    public let method: String
    public let path: String
    public let status: Int
    public let contentType: String
    public let body: String
    public init(method: String = "GET", path: String, status: Int = 200, contentType: String = "application/json", body: String) {
        self.method = method; self.path = path; self.status = status; self.contentType = contentType; self.body = body
    }
}
public struct NetworkFixtureScenario: Codable, Sendable {
    public var schemaVersion = 1
    public var port: UInt16 = 8787
    public var dnsPort: UInt16 = 53535
    public var latencyMilliseconds: Int = 0
    public var bytesPerSecond: Int = 0
    public var lossPercent: Int = 0
    public var seed: String = "lab"
    public var offline = false
    public var simulatedDate: Date?
    public var dnsRecords: [String: String] = ["radio.test": "127.0.0.1"]
    public var responses: [HTTPFixture] = [HTTPFixture(path: "/health", body: "{\"ok\":true}")]
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1, port > 1024, dnsPort > 1024, port != dnsPort,
              (0...60000).contains(latencyMilliseconds), (0...100).contains(lossPercent), (0...104857600).contains(bytesPerSecond),
              seed.count <= 255, responses.count <= 1000, dnsRecords.count <= 1000,
              responses.allSatisfy({ ["GET", "POST", "PUT", "DELETE", "HEAD"].contains($0.method) && $0.path.hasPrefix("/") && $0.path.count <= 4096
                  && (100...599).contains($0.status) && $0.body.utf8.count <= 1_048_576 && !$0.contentType.isEmpty && $0.contentType.utf8.count <= 255
                  && $0.contentType.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) }),
              Set(responses.map { "\($0.method) \($0.path)" }).count == responses.count,
              dnsRecords.allSatisfy({ key, value in key.count <= 253 && value.split(separator: ".").count == 4 && value.split(separator: ".").allSatisfy { UInt8($0) != nil } }) else {
            throw EvolutionError.invalid("Invalid bounded network fixture scenario.")
        }
    }
    public func drops(_ requestIdentity: String) -> Bool {
        let hash = EvolutionFiles.digest(Data("\(seed):\(requestIdentity)".utf8))
        let value = UInt32(hash.prefix(8), radix: 16) ?? 0
        return offline || Int(value % 100) < lossPercent
    }
    public static func record(url: URL, path: String) async throws -> HTTPFixture {
        guard ["https", "http"].contains(url.scheme), path.hasPrefix("/"), url.user == nil, url.password == nil else {
            throw EvolutionError.invalid("Record an explicit HTTP URL without embedded credentials.")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        let (data, reply) = try await session.data(for: request)
        guard let reply = reply as? HTTPURLResponse, data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw EvolutionError.invalid("Recording supports UTF-8 responses up to 1 MiB.")
        }
        return HTTPFixture(path: path, status: reply.statusCode, contentType: reply.mimeType ?? "text/plain", body: text)
    }
}

public enum DNSFixture {
    public static func response(to data: Data, records: [String: String]) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 17, bytes[2] & 0x80 == 0, bytes[4] == 0, bytes[5] == 1 else { return nil }
        var offset = 12, labels = [String]()
        while offset < bytes.count {
            let count = Int(bytes[offset]); offset += 1
            if count == 0 { break }
            guard count <= 63, offset + count < bytes.count, labels.count < 128,
                  let label = String(bytes: bytes[offset..<(offset + count)], encoding: .ascii) else { return nil }
            labels.append(label); offset += count
        }
        guard offset + 4 <= bytes.count else { return nil }
        let type = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
        let klass = UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3])
        let address = records[labels.joined(separator: ".").lowercased()]?.split(separator: ".").compactMap { UInt8($0) }
        let found = type == 1 && klass == 1 && address?.count == 4
        var reply = Data([bytes[0], bytes[1], 0x81, found ? 0x80 : 0x83, 0, 1, 0, found ? 1 : 0, 0, 0, 0, 0])
        reply.append(contentsOf: bytes[12..<(offset + 4)])
        if found, let address {
            reply.append(contentsOf: [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4])
            reply.append(contentsOf: address)
        }
        return reply
    }
}
