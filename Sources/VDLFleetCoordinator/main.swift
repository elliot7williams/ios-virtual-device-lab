@preconcurrency import Network
import CryptoKit
import Foundation
import Security

private let serverVersion = "1.1.0"
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

struct FleetHostEnrollment: Codable {
    let hostID: String
    let displayName: String
    let workerVersion: String
    let capabilities: [String]
    let enrolledAt: Date
}

struct FleetHeartbeat: Codable {
    let hostID: String
    let workerVersion: String
    let activeJobIDs: [UUID]
    let availableSlots: Int
    let sentAt: Date
}

struct FleetClaim: Codable {
    let hostID: String
    let claimedAt: Date
}

struct FleetRunningJob: Codable {
    let submission: FleetSubmission
    let hostID: String
    let claimedAt: Date
}

struct FleetProgress: Codable {
    let hostID: String
    let sequence: UInt64
    let phase: String
    let percent: Double
    let message: String
    let sentAt: Date
}

struct FleetResult: Codable {
    let hostID: String
    let succeeded: Bool
    let exitCode: Int
    let summary: String
    let evidenceSHA256: String?
    let completedAt: Date
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

struct FleetAuditEnvelope: Codable {
    let sequence: UInt64
    let previousHash: String
    let recordHash: String
    let signature: String?
    let signingCertificateSHA256: String?
    let canonicalRecord: String
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
    private var auditPrivateKey: SecKey?
    private var auditCertificateSHA256: String?
    private var auditSequence: UInt64 = 0
    private var auditPreviousHash = String(repeating: "0", count: 64)

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
        restoreAuditHead()
    }

    func run() throws {
        guard let identity = keychainIdentity(label: policy.serverIdentityLabel),
              let secIdentity = sec_identity_create(identity) else {
            throw FleetServerError.message("The configured server identity was not found in the Keychain.")
        }
        var privateKey: SecKey?
        var certificate: SecCertificate?
        guard SecIdentityCopyPrivateKey(identity, &privateKey) == errSecSuccess,
              SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let privateKey, let certificate else {
            throw FleetServerError.message("The server identity cannot sign audit records.")
        }
        auditPrivateKey = privateKey
        auditCertificateSHA256 = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
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
        let pathComponents = request.path.split(separator: "/").map(String.init)
        let permission: String = switch (request.method, request.path, pathComponents.count) {
        case ("GET", "/v1/health", _): "read"
        case ("POST", "/v1/hosts/enroll", _): "enroll"
        case ("POST", "/v1/hosts/heartbeat", _): "worker"
        case ("POST", "/v1/jobs", _): "submit"
        case ("POST", "/v1/jobs/next/claim", _): "worker"
        case ("GET", _, 3) where pathComponents.first == "v1" && pathComponents[1] == "jobs": "read"
        case ("POST", _, 4) where pathComponents.first == "v1" && pathComponents[1] == "jobs"
            && ["claim", "progress", "result"].contains(pathComponents[3]): "worker"
        case ("POST", _, 4) where pathComponents.first == "v1" && pathComponents[1] == "jobs"
            && pathComponents[3] == "cancel": "cancel"
        default: "unknown"
        }
        guard let principal, permission != "unknown", permits(principal.role, permission) else {
            let status = permission == "unknown" ? 404 : 403
            audit(request, subject: subject, fingerprint: fingerprint, status: status, requestID: nil, jobID: nil, message: "Request was not authorized.")
            respond(connection, status: status, object: ["error": status == 404 ? "not found" : "forbidden"])
            return
        }

        if request.path == "/v1/health" {
            audit(request, subject: subject, fingerprint: fingerprint, status: 200, requestID: nil, jobID: nil, message: "Authenticated health request.")
            respond(connection, status: 200, object: [
                "ok": true, "version": serverVersion,
                "host_id": Host.current().localizedName ?? "fleet-host",
                "protocol_schema": 1,
                "operations": ["enroll", "heartbeat", "submit", "claim", "progress", "result", "query", "cancel"],
            ])
            return
        }
        if request.path == "/v1/hosts/enroll" {
            do {
                let enrollment = try decode(FleetHostEnrollment.self, from: request.body)
                try validateIdentity(enrollment.hostID, subject: subject)
                try validateTimestamp(enrollment.enrolledAt)
                guard !enrollment.displayName.isEmpty, !enrollment.workerVersion.isEmpty,
                      !enrollment.capabilities.isEmpty, enrollment.capabilities.count <= 128 else {
                    throw FleetServerError.message("enrollment fields are invalid")
                }
                let destination = root.appendingPathComponent("Hosts/\(principalFile(enrollment.hostID)).enrollment.json")
                try write(enrollment, to: destination)
                audit(request, subject: subject, fingerprint: fingerprint, status: 200, requestID: nil, jobID: nil, message: "Worker enrollment recorded.")
                respond(connection, status: 200, object: ["ok": true, "host_id": enrollment.hostID])
            } catch { reject(error, request: request, connection: connection, subject: subject, fingerprint: fingerprint) }
            return
        }
        if request.path == "/v1/hosts/heartbeat" {
            do {
                let heartbeat = try decode(FleetHeartbeat.self, from: request.body)
                try validateIdentity(heartbeat.hostID, subject: subject)
                try validateTimestamp(heartbeat.sentAt)
                guard !heartbeat.workerVersion.isEmpty, heartbeat.activeJobIDs.count <= 100,
                      (0...100).contains(heartbeat.availableSlots) else {
                    throw FleetServerError.message("heartbeat fields are invalid")
                }
                let enrolled = root.appendingPathComponent("Hosts/\(principalFile(heartbeat.hostID)).enrollment.json")
                guard FileManager.default.fileExists(atPath: enrolled.path) else {
                    throw FleetServerError.message("worker must be enrolled before heartbeat")
                }
                try write(heartbeat, to: root.appendingPathComponent("Hosts/\(principalFile(heartbeat.hostID)).heartbeat.json"))
                let cancellations = heartbeat.activeJobIDs.filter {
                    FileManager.default.fileExists(atPath: root.appendingPathComponent("CancelRequests/\($0.uuidString).json").path)
                }.map(\.uuidString)
                audit(request, subject: subject, fingerprint: fingerprint, status: 200, requestID: nil, jobID: nil, message: "Worker heartbeat recorded.")
                respond(connection, status: 200, object: ["ok": true, "cancel_job_ids": cancellations])
            } catch { reject(error, request: request, connection: connection, subject: subject, fingerprint: fingerprint) }
            return
        }
        if request.path == "/v1/jobs" {
            do {
                let submission = try decode(FleetSubmission.self, from: request.body)
                guard !submission.workflowID.isEmpty, !submission.deviceName.isEmpty,
                      submission.workflowID.count <= 512, submission.deviceName.count <= 255 else {
                    throw FleetServerError.message("submission fields or timestamp are invalid")
                }
                try validateTimestamp(submission.submittedAt)
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
        if request.path == "/v1/jobs/next/claim" {
            do {
                let claim = try decode(FleetClaim.self, from: request.body)
                try validateIdentity(claim.hostID, subject: subject)
                try validateTimestamp(claim.claimedAt)
                let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
                let next = try FileManager.default.contentsOfDirectory(
                    at: inbox, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension == "json" }.sorted {
                    let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhs < rhs
                }.first
                guard let next, let jobID = UUID(uuidString: next.deletingPathExtension().lastPathComponent) else {
                    audit(request, subject: subject, fingerprint: fingerprint, status: 404, requestID: nil, jobID: nil, message: "No queued job is available.")
                    respond(connection, status: 404, object: ["error": "no queued job"])
                    return
                }
                let submission = try claimJob(jobID, claim: claim)
                audit(request, subject: subject, fingerprint: fingerprint, status: 200, requestID: submission.id, jobID: jobID, message: "Next queued job claimed by enrolled worker.")
                respond(connection, status: 200, encodable: submission)
            } catch { reject(error, request: request, connection: connection, subject: subject, fingerprint: fingerprint) }
            return
        }

        guard pathComponents.count >= 3, let jobID = UUID(uuidString: pathComponents[2]) else {
            respond(connection, status: 400, object: ["error": "invalid job identifier"])
            return
        }
        if request.method == "GET" {
            let state = jobState(jobID)
            let status = state == nil ? 404 : 200
            audit(request, subject: subject, fingerprint: fingerprint, status: status, requestID: nil, jobID: jobID, message: state == nil ? "Job was not found." : "Job status queried.")
            respond(connection, status: status, object: state.map { ["job_id": jobID.uuidString, "state": $0] } ?? ["error": "not found"])
            return
        }
        guard pathComponents.count == 4 else {
            respond(connection, status: 404, object: ["error": "not found"])
            return
        }
        let action = pathComponents[3]
        do {
            switch action {
            case "claim":
                let claim = try decode(FleetClaim.self, from: request.body)
                try validateIdentity(claim.hostID, subject: subject)
                try validateTimestamp(claim.claimedAt)
                let submission = try claimJob(jobID, claim: claim)
                audit(request, subject: subject, fingerprint: fingerprint, status: 200, requestID: submission.id, jobID: jobID, message: "Job claimed by enrolled worker.")
                respond(connection, status: 200, encodable: submission)
            case "progress":
                let progress = try decode(FleetProgress.self, from: request.body)
                try validateIdentity(progress.hostID, subject: subject)
                try validateTimestamp(progress.sentAt)
                guard progress.sequence > 0, (0...100).contains(progress.percent),
                      !progress.phase.isEmpty, progress.message.count <= 4_096 else {
                    throw FleetServerError.message("progress fields are invalid")
                }
                let running = try ownedRunningJob(jobID, hostID: progress.hostID)
                let progressURL = root.appendingPathComponent("Progress/\(jobID.uuidString).json")
                if let prior = try? decode(FleetProgress.self, from: Data(contentsOf: progressURL)),
                   progress.sequence <= prior.sequence {
                    throw FleetServerError.message("progress sequence must increase monotonically")
                }
                try write(progress, to: progressURL)
                let cancelRequested = FileManager.default.fileExists(atPath: root.appendingPathComponent("CancelRequests/\(jobID.uuidString).json").path)
                audit(request, subject: subject, fingerprint: fingerprint, status: 200, requestID: running.submission.id, jobID: jobID, message: "Monotonic worker progress recorded.")
                respond(connection, status: 200, object: ["ok": true, "cancel_requested": cancelRequested])
            case "result":
                let result = try decode(FleetResult.self, from: request.body)
                try validateIdentity(result.hostID, subject: subject)
                try validateTimestamp(result.completedAt)
                guard result.summary.count <= 16_384,
                      result.evidenceSHA256 == nil || result.evidenceSHA256?.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
                    throw FleetServerError.message("result fields are invalid")
                }
                let resultURL = root.appendingPathComponent("Results/\(jobID.uuidString).json")
                if FileManager.default.fileExists(atPath: resultURL.path) {
                    audit(request, subject: subject, fingerprint: fingerprint, status: 200, requestID: nil, jobID: jobID, message: "Idempotent result retry accepted.")
                    respond(connection, status: 200, object: ["ok": true, "job_id": jobID.uuidString])
                    return
                }
                let cancelledURL = root.appendingPathComponent("Cancelled/\(jobID.uuidString).json")
                if FileManager.default.fileExists(atPath: cancelledURL.path) {
                    audit(request, subject: subject, fingerprint: fingerprint, status: 200, requestID: nil, jobID: jobID, message: "Idempotent cancelled-result retry accepted.")
                    respond(connection, status: 200, object: ["ok": true, "job_id": jobID.uuidString])
                    return
                }
                let running = try ownedRunningJob(jobID, hostID: result.hostID)
                let cancellation = root.appendingPathComponent("CancelRequests/\(jobID.uuidString).json")
                let wasCancelled = FileManager.default.fileExists(atPath: cancellation.path)
                try write(result, to: wasCancelled ? cancelledURL : resultURL)
                try FileManager.default.removeItem(at: root.appendingPathComponent("Running/\(jobID.uuidString).json"))
                if wasCancelled { try? FileManager.default.removeItem(at: cancellation) }
                audit(request, subject: subject, fingerprint: fingerprint, status: 200, requestID: running.submission.id, jobID: jobID, message: wasCancelled ? "Cancelled worker result committed." : "Bounded worker result committed.")
                respond(connection, status: 200, object: ["ok": true, "job_id": jobID.uuidString])
            case "cancel":
                let queued = root.appendingPathComponent("Inbox/\(jobID.uuidString).json")
                let running = root.appendingPathComponent("Running/\(jobID.uuidString).json")
                let destination = root.appendingPathComponent("Cancelled/\(jobID.uuidString).json")
                if FileManager.default.fileExists(atPath: queued.path) {
                    try FileManager.default.moveItem(at: queued, to: destination)
                    try protect(destination)
                    audit(request, subject: subject, fingerprint: fingerprint, status: 200, requestID: nil, jobID: jobID, message: "Queued job cancelled.")
                    respond(connection, status: 200, object: ["ok": true, "job_id": jobID.uuidString, "state": "cancelled"])
                } else if FileManager.default.fileExists(atPath: running.path) {
                    let marker = root.appendingPathComponent("CancelRequests/\(jobID.uuidString).json")
                    try write(["job_id": jobID.uuidString, "requested_at": ISO8601DateFormatter().string(from: .now)], to: marker)
                    audit(request, subject: subject, fingerprint: fingerprint, status: 202, requestID: nil, jobID: jobID, message: "Running-job cancellation requested.")
                    respond(connection, status: 202, object: ["ok": true, "job_id": jobID.uuidString, "state": "cancelling"])
                } else {
                    throw FleetServerError.message("only queued or running jobs can be cancelled")
                }
            default:
                respond(connection, status: 404, object: ["error": "not found"])
            }
        } catch {
            audit(request, subject: subject, fingerprint: fingerprint, status: 409, requestID: nil, jobID: jobID, message: error.localizedDescription)
            respond(connection, status: 409, object: ["error": error.localizedDescription])
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try protect(url)
    }

    private func validateTimestamp(_ date: Date) throws {
        guard date <= Date().addingTimeInterval(300), date >= Date().addingTimeInterval(-3_600) else {
            throw FleetServerError.message("timestamp is outside the allowed clock window")
        }
    }

    private func validateIdentity(_ hostID: String, subject: String?) throws {
        guard !hostID.isEmpty, hostID.count <= 255, hostID == subject else {
            throw FleetServerError.message("body host identity must match the authenticated certificate subject")
        }
    }

    private func principalFile(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func ownedRunningJob(_ jobID: UUID, hostID: String) throws -> FleetRunningJob {
        let url = root.appendingPathComponent("Running/\(jobID.uuidString).json")
        let running = try decode(FleetRunningJob.self, from: Data(contentsOf: url))
        guard running.hostID == hostID else { throw FleetServerError.message("job is owned by another worker") }
        return running
    }

    private func claimJob(_ jobID: UUID, claim: FleetClaim) throws -> FleetSubmission {
        let source = root.appendingPathComponent("Inbox/\(jobID.uuidString).json")
        let runningURL = root.appendingPathComponent("Running/\(jobID.uuidString).json")
        if FileManager.default.fileExists(atPath: runningURL.path),
           let running = try? decode(FleetRunningJob.self, from: Data(contentsOf: runningURL)),
           running.hostID == claim.hostID {
            return running.submission
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw FleetServerError.message("job is not available to claim")
        }
        let submission = try decode(FleetSubmission.self, from: Data(contentsOf: source))
        try FileManager.default.moveItem(at: source, to: runningURL)
        let running = FleetRunningJob(submission: submission, hostID: claim.hostID, claimedAt: claim.claimedAt)
        try write(running, to: runningURL)
        return submission
    }

    private func jobState(_ jobID: UUID) -> String? {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Results/\(jobID.uuidString).json").path) { return "completed" }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Cancelled/\(jobID.uuidString).json").path) { return "cancelled" }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Running/\(jobID.uuidString).json").path) {
            return FileManager.default.fileExists(atPath: root.appendingPathComponent("CancelRequests/\(jobID.uuidString).json").path) ? "cancelling" : "running"
        }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Inbox/\(jobID.uuidString).json").path) { return "queued" }
        return nil
    }

    private func reject(
        _ error: Error, request: HTTPRequest, connection: NWConnection,
        subject: String?, fingerprint: String?
    ) {
        audit(request, subject: subject, fingerprint: fingerprint, status: 400, requestID: nil, jobID: nil, message: error.localizedDescription)
        respond(connection, status: 400, object: ["error": error.localizedDescription])
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
        case .operatorRole: ["read", "enroll", "submit", "worker", "cancel"].contains(permission)
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
        fileLock.lock()
        defer { fileLock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let canonicalData = try? encoder.encode(record),
              let canonicalRecord = String(data: canonicalData, encoding: .utf8) else { return }
        let sequence = auditSequence + 1
        let hashInput = Data("\(sequence)\n\(auditPreviousHash)\n\(canonicalRecord)".utf8)
        let digest = Data(SHA256.hash(data: hashInput))
        let recordHash = digest.map { String(format: "%02x", $0) }.joined()
        var signature: String?
        if let key = auditPrivateKey {
            let algorithm: SecKeyAlgorithm = SecKeyIsAlgorithmSupported(key, .sign, .ecdsaSignatureDigestX962SHA256)
                ? .ecdsaSignatureDigestX962SHA256 : .rsaSignatureDigestPKCS1v15SHA256
            if SecKeyIsAlgorithmSupported(key, .sign, algorithm),
               let signed = SecKeyCreateSignature(key, algorithm, digest as CFData, nil) as Data? {
                signature = signed.base64EncodedString()
            }
        }
        let envelope = FleetAuditEnvelope(
            sequence: sequence, previousHash: auditPreviousHash, recordHash: recordHash,
            signature: signature, signingCertificateSHA256: auditCertificateSHA256,
            canonicalRecord: canonicalRecord
        )
        guard var data = try? encoder.encode(envelope) else { return }
        data.append(0x0A)
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
            auditSequence = sequence
            auditPreviousHash = recordHash
        } catch { }
    }

    private func restoreAuditHead() {
        let url = root.appendingPathComponent("audit.jsonl")
        guard let data = try? Data(contentsOf: url), data.count <= 128 * 1_024 * 1_024,
              let contents = String(data: data, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        var sequence: UInt64 = 0
        var previous = String(repeating: "0", count: 64)
        for line in contents.split(separator: "\n") {
            guard let envelope = try? decoder.decode(FleetAuditEnvelope.self, from: Data(line.utf8)),
                  envelope.sequence == sequence + 1,
                  envelope.previousHash == previous else { return }
            let expected = SHA256.hash(data: Data("\(envelope.sequence)\n\(envelope.previousHash)\n\(envelope.canonicalRecord)".utf8))
                .map { String(format: "%02x", $0) }.joined()
            guard expected == envelope.recordHash else { return }
            sequence = envelope.sequence
            previous = envelope.recordHash
        }
        auditSequence = sequence
        auditPreviousHash = previous
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["Inbox", "Running", "Progress", "Results", "Cancelled", "CancelRequests", "Hosts"] {
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
      vdl-fleetd --protocol-json

    The policy pins the Keychain server identity, listening port, dedicated state root,
    and a unique client-certificate SHA-256 for every enabled viewer/operator/admin.
    The server exposes the versioned enroll, heartbeat, submit, claim, progress,
    result, query, and cancellation lifecycle. Every authorization decision is
    written to a certificate-signed, hash-chained audit ledger.
    """)
}

func printProtocolManifest() {
    let object: [String: Any] = [
        "schema_version": 1,
        "server_version": serverVersion,
        "maximum_request_bytes": maximumRequestBytes,
        "authentication": "mutual-tls-with-certificate-pinning",
        "audit": "sha256-chain-with-server-identity-signature",
        "operations": [
            ["method": "GET", "path": "/v1/health", "permission": "read"],
            ["method": "POST", "path": "/v1/hosts/enroll", "permission": "policy-authorized-self-enrollment"],
            ["method": "POST", "path": "/v1/hosts/heartbeat", "permission": "worker"],
            ["method": "POST", "path": "/v1/jobs", "permission": "submit"],
            ["method": "POST", "path": "/v1/jobs/{id}/claim", "permission": "worker"],
            ["method": "POST", "path": "/v1/jobs/next/claim", "permission": "worker"],
            ["method": "POST", "path": "/v1/jobs/{id}/progress", "permission": "worker"],
            ["method": "POST", "path": "/v1/jobs/{id}/result", "permission": "worker"],
            ["method": "GET", "path": "/v1/jobs/{id}", "permission": "read"],
            ["method": "POST", "path": "/v1/jobs/{id}/cancel", "permission": "cancel"],
        ],
    ]
    let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data ?? Data("{}".utf8), as: UTF8.self))
}

@main
enum VDLFleetCoordinator {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") { usage(); return }
        if arguments.contains("--protocol-json") { printProtocolManifest(); return }
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
