@preconcurrency import Network
import CryptoKit
import Foundation
import Security

private let serverVersion = "1.0.0"
private let maximumRequestBytes = 1_048_576

enum FleetServerError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(message) = self { message } else { "Unknown fleet coordinator error." }
    }
}

enum ServerRole: String, Codable {
    case viewer
    case operatorRole = "operator"
    case administrator
}

struct ServerPrincipal: Codable {
    let subject: String
    let role: ServerRole
    let certificateSHA256: String
    let enabled: Bool
}

struct FleetServerPolicy: Codable {
    let schemaVersion: Int
    let serverIdentityLabel: String
    let listenPort: UInt16
    let stateRoot: String
    let principals: [ServerPrincipal]
    let requirePlatformTrust: Bool
}

struct FleetSubmission: Codable {
    let id: UUID
    let workflowID: String
    let deviceName: String
    let submittedAt: Date
}

struct FleetAcknowledgement: Codable {
    let requestID: UUID
    let jobID: UUID?
    let accepted: Bool
    let message: String
}

struct AuditRecord: Codable {
    let id: UUID
    let occurredAt: Date
    let subject: String?
    let certificateSHA256: String?
    let method: String
    let path: String
    let statusCode: Int
    let requestID: UUID?
    let jobID: UUID?
    let message: String
}

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

final class FleetCoordinator: @unchecked Sendable {
    private let policy: FleetServerPolicy
    private let root: URL
    private let queue = DispatchQueue(label: "vdl.fleet.coordinator")
    private let fileLock = NSLock()
    private var listener: NWListener?

    init(policy: FleetServerPolicy) throws {
        guard policy.schemaVersion == 1,
              !policy.serverIdentityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              policy.listenPort > 0,
              !policy.principals.isEmpty else {
            throw FleetServerError.message("Policy schema, identity label, port, and principals are required.")
        }
        let enabled = policy.principals.filter(\.enabled)
        guard !enabled.isEmpty,
              enabled.allSatisfy({
                  !$0.subject.isEmpty
                      && $0.certificateSHA256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
              }),
              Set(enabled.map(\.subject)).count == enabled.count,
              Set(enabled.map { $0.certificateSHA256.lowercased() }).count == enabled.count else {
            throw FleetServerError.message("Enabled principals require unique subjects and unique 64-character certificate pins.")
        }
        let url = URL(fileURLWithPath: policy.stateRoot).standardizedFileURL
        guard url.path != "/", url.path != FileManager.default.homeDirectoryForCurrentUser.path else {
            throw FleetServerError.message("stateRoot must be a dedicated directory, not a filesystem or home root.")
        }
        self.policy = policy
        root = url
        try prepareDirectories()
    }

    func run() throws {
        guard let identity = keychainIdentity(label: policy.serverIdentityLabel),
              let secIdentity = sec_identity_create(identity) else {
            throw FleetServerError.message("The configured server identity was not found in the Keychain.")
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        let allowedPins = Set(policy.principals.filter(\.enabled).map { $0.certificateSHA256.lowercased() })
        let requirePlatformTrust = policy.requirePlatformTrust
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let trustReference = sec_trust_copy_ref(trust).takeRetainedValue()
            var trustError: CFError?
            let trusted = !requirePlatformTrust || SecTrustEvaluateWithError(trustReference, &trustError)
            let pin = Self.leafFingerprint(trustReference)
            complete(trusted && pin.map { allowedPins.contains($0) } == true)
        }, queue)

        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: policy.listenPort)!)
        self.listener = listener
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("vdl-fleetd \(serverVersion) listening with mTLS on port \(self.policy.listenPort)")
            case let .failed(error):
                fputs("vdl-fleetd listener failed: \(error)\n", stderr)
                exit(1)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        dispatchMain()
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready: self.receive(connection, buffer: Data())
            case .failed, .cancelled: connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var next = buffer
            if let data { next.append(data) }
            guard next.count <= maximumRequestBytes else {
                self.respond(connection, status: 413, object: ["error": "request exceeds 1 MiB"])
                return
            }
            if let request = Self.parseRequest(next) {
                self.handle(request, on: connection)
            } else if complete || error != nil {
                self.respond(connection, status: 400, object: ["error": "incomplete or invalid HTTP request"])
            } else {
                self.receive(connection, buffer: next)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        let fingerprint = peerFingerprint(connection)
        let subject = request.headers["x-vdl-agent-id"]
        let principal = policy.principals.first {
            $0.enabled && $0.subject == subject
                && $0.certificateSHA256.caseInsensitiveCompare(fingerprint ?? "") == .orderedSame
        }
        let permission: String = switch (request.method, request.path) {
        case ("GET", "/v1/health"): "read"
        case ("POST", "/v1/jobs"): "submit"
        case ("POST", let path) where path.hasPrefix("/v1/jobs/") && path.hasSuffix("/cancel"): "cancel"
        default: "unknown"
        }
        guard let principal, permission != "unknown", permits(principal.role, permission) else {
            let status = permission == "unknown" ? 404 : 403
            audit(request, subject: subject, fingerprint: fingerprint, status: status, requestID: nil, jobID: nil, message: "Request was not authorized.")
            respond(connection, status: status, object: ["error": status == 404 ? "not found" : "forbidden"])
            return
        }

        if request.method == "GET" {
            audit(request, subject: subject, fingerprint: fingerprint, status: 200, requestID: nil, jobID: nil, message: "Authenticated health request.")
            respond(connection, status: 200, object: [
                "ok": true, "version": serverVersion,
                "host_id": Host.current().localizedName ?? "fleet-host",
            ])
            return
        }
        if request.path == "/v1/jobs" {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let submission = try decoder.decode(FleetSubmission.self, from: request.body)
                guard !submission.workflowID.isEmpty, !submission.deviceName.isEmpty,
                      submission.submittedAt <= Date().addingTimeInterval(300),
                      submission.submittedAt >= Date().addingTimeInterval(-3_600) else {
                    throw FleetServerError.message("submission fields or timestamp are invalid")
                }
                // Use the caller's correlation UUID as the durable job UUID. A
                // retry therefore cannot enqueue the same request twice.
                let jobID = submission.id
                let existing = ["Inbox", "Running", "Results", "Cancelled"]
                    .map { self.root.appendingPathComponent("\($0)/\(jobID.uuidString).json") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
                if existing != nil {
                    let acknowledgement = FleetAcknowledgement(
                        requestID: submission.id, jobID: jobID, accepted: true,
                        message: "The correlated fleet request was already recorded; no duplicate job was created."
                    )
                    audit(request, subject: subject, fingerprint: fingerprint, status: 200, requestID: submission.id, jobID: jobID, message: acknowledgement.message)
                    respond(connection, status: 200, encodable: acknowledgement)
                    return
                }
                let jobURL = root.appendingPathComponent("Inbox/\(jobID.uuidString).json")
                try request.body.write(to: jobURL, options: [.atomic, .completeFileProtectionUnlessOpen])
                try protect(jobURL)
                let acknowledgement = FleetAcknowledgement(
                    requestID: submission.id, jobID: jobID, accepted: true,
                    message: "The mTLS-authenticated fleet coordinator accepted the job."
                )
                audit(request, subject: subject, fingerprint: fingerprint, status: 202, requestID: submission.id, jobID: jobID, message: acknowledgement.message)
                respond(connection, status: 202, encodable: acknowledgement)
            } catch {
                audit(request, subject: subject, fingerprint: fingerprint, status: 400, requestID: nil, jobID: nil, message: error.localizedDescription)
                respond(connection, status: 400, object: ["error": error.localizedDescription])
            }
            return
        }

        let components = request.path.split(separator: "/")
        guard components.count == 4, let jobID = UUID(uuidString: String(components[2])) else {
            respond(connection, status: 400, object: ["error": "invalid job identifier"])
            return
        }
        let source = root.appendingPathComponent("Inbox/\(jobID.uuidString).json")
        let destination = root.appendingPathComponent("Cancelled/\(jobID.uuidString).json")
        do {
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw FleetServerError.message("only queued jobs can be cancelled")
            }
            try FileManager.default.moveItem(at: source, to: destination)
            try protect(destination)
            audit(request, subject: subject, fingerprint: fingerprint, status: 200, requestID: nil, jobID: jobID, message: "Queued job cancelled.")
            respond(connection, status: 200, object: ["ok": true, "job_id": jobID.uuidString])
        } catch {
            audit(request, subject: subject, fingerprint: fingerprint, status: 409, requestID: nil, jobID: jobID, message: error.localizedDescription)
            respond(connection, status: 409, object: ["error": error.localizedDescription])
        }
    }

    private func peerFingerprint(_ connection: NWConnection) -> String? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        var result: String?
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            guard result == nil else { return }
            let reference = sec_certificate_copy_ref(certificate).takeRetainedValue()
            result = SHA256.hash(data: SecCertificateCopyData(reference) as Data)
                .map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    private func permits(_ role: ServerRole, _ permission: String) -> Bool {
        switch role {
        case .viewer: permission == "read"
        case .operatorRole: ["read", "submit", "cancel"].contains(permission)
        case .administrator: true
        }
    }

    private func respond<T: Encodable>(_ connection: NWConnection, status: Int, encodable: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(encodable)) ?? Data("{\"error\":\"encoding failed\"}".utf8)
        respond(connection, status: status, body: data)
    }

    private func respond(_ connection: NWConnection, status: Int, object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{\"error\":\"encoding failed\"}".utf8)
        respond(connection, status: status, body: data)
    }

    private func respond(_ connection: NWConnection, status: Int, body: Data) {
        let reason: String = switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        default: "Error"
        }
        let header = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func audit(
        _ request: HTTPRequest, subject: String?, fingerprint: String?, status: Int,
        requestID: UUID?, jobID: UUID?, message: String
    ) {
        let record = AuditRecord(
            id: UUID(), occurredAt: .now, subject: subject,
            certificateSHA256: fingerprint, method: request.method, path: request.path,
            statusCode: status, requestID: requestID, jobID: jobID, message: message
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        fileLock.lock()
        defer { fileLock.unlock() }
        let url = root.appendingPathComponent("audit.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch { }
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["Inbox", "Running", "Results", "Cancelled"] {
            let url = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    private func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func keychainIdentity(label: String) -> SecIdentity? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: label,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecIdentity)
    }

    private static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let certificate = SecTrustCopyCertificateChain(trust).flatMap({ ($0 as? [SecCertificate])?.first }) else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func parseRequest(_ data: Data) -> HTTPRequest? {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: marker),
              let header = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let requestLine = first.split(separator: " ")
        guard requestLine.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0, contentLength <= maximumRequestBytes else { return nil }
        let bodyStart = range.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        return HTTPRequest(
            method: String(requestLine[0]), path: String(requestLine[1]),
            headers: headers, body: Data(data[bodyStart..<(bodyStart + contentLength)])
        )
    }
}

func value(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func usage() {
    print("""
    vdl-fleetd \(serverVersion) — mTLS fleet coordinator

    Usage:
      vdl-fleetd --policy <fleet-server-policy.json>

    The policy pins the Keychain server identity, listening port, dedicated state root,
    and a unique client-certificate SHA-256 for every enabled viewer/operator/admin.
    The server exposes GET /v1/health, POST /v1/jobs, and queued-job cancellation.
    """)
}

@main
enum VDLFleetCoordinator {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") { usage(); return }
        do {
            guard let path = value(after: "--policy", in: arguments) else {
                throw FleetServerError.message("--policy is required")
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 1_048_576 else {
                throw FleetServerError.message("policy must be a regular JSON file no larger than 1 MiB")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let policy = try decoder.decode(FleetServerPolicy.self, from: Data(contentsOf: url))
            try FleetCoordinator(policy: policy).run()
        } catch {
            fputs("vdl-fleetd: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
