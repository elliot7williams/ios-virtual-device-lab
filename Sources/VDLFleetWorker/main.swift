import CryptoKit
import Foundation
import Security

private let workerVersion = "1.1.0"
private let maximumResponseBytes = 1_048_576

enum WorkerError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(message) = self { message } else { "Unknown fleet worker error." }
    }
}

struct WorkerConfiguration: Codable {
    let schemaVersion: Int
    let coordinatorURL: String
    let agentID: String
    let displayName: String
    let clientIdentityLabel: String
    let serverCertificateSHA256: String
    let vdlctlPath: String?
    let outputRoot: String
    let pollIntervalSeconds: Int
    let jobTimeoutSeconds: Int
    let maximumConcurrentJobs: Int
}

struct HostEnrollment: Codable {
    let hostID: String
    let displayName: String
    let workerVersion: String
    let capabilities: [String]
    let enrolledAt: Date
}

struct Heartbeat: Codable {
    let hostID: String
    let workerVersion: String
    let activeJobIDs: [UUID]
    let availableSlots: Int
    let sentAt: Date
}

struct HeartbeatReply: Codable {
    let ok: Bool
    let cancel_job_ids: [String]
}

struct Claim: Codable { let hostID: String; let claimedAt: Date }

struct Submission: Codable {
    let id: UUID
    let workflowID: String
    let deviceName: String
    let submittedAt: Date
}

struct ProgressUpdate: Codable {
    let hostID: String
    let sequence: UInt64
    let phase: String
    let percent: Double
    let message: String
    let sentAt: Date
}

struct ProgressReply: Codable { let ok: Bool; let cancel_requested: Bool }

struct WorkerResult: Codable {
    let hostID: String
    let succeeded: Bool
    let exitCode: Int
    let summary: String
    let evidenceSHA256: String?
    let completedAt: Date
}

struct SimpleReply: Codable { let ok: Bool? }

final class MutualTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let identity: SecIdentity
    private let certificate: SecCertificate
    private let serverPin: String

    init(identity: SecIdentity, certificate: SecCertificate, serverPin: String) {
        self.identity = identity
        self.certificate = certificate
        self.serverPin = serverPin.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(
                .useCredential,
                URLCredential(identity: identity, certificates: [certificate], persistence: .forSession)
            )
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  SecTrustEvaluateWithError(trust, nil),
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
                .map { String(format: "%02x", $0) }.joined()
            guard fingerprint == serverPin else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

final class FleetWorkerClient: @unchecked Sendable {
    private let configuration: WorkerConfiguration
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(configuration: WorkerConfiguration) throws {
        guard configuration.schemaVersion == 1,
              let base = URL(string: configuration.coordinatorURL), base.scheme == "https",
              base.host != nil, base.user == nil, base.password == nil,
              !configuration.agentID.isEmpty, configuration.agentID.count <= 255,
              !configuration.displayName.isEmpty,
              configuration.serverCertificateSHA256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
              (2...300).contains(configuration.pollIntervalSeconds),
              (60...86_400).contains(configuration.jobTimeoutSeconds),
              (1...32).contains(configuration.maximumConcurrentJobs) else {
            throw WorkerError.message("Configuration fields, HTTPS URL, certificate pin, polling, timeout, or concurrency are invalid.")
        }
        guard let identity = Self.keychainIdentity(label: configuration.clientIdentityLabel) else {
            throw WorkerError.message("The configured client identity was not found in the Keychain.")
        }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            throw WorkerError.message("The client identity has no certificate.")
        }
        self.configuration = configuration
        baseURL = base
        let delegate = MutualTLSDelegate(
            identity: identity, certificate: certificate,
            serverPin: configuration.serverCertificateSHA256
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = 60
        sessionConfiguration.waitsForConnectivity = false
        session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func runOnce() async throws -> Bool {
        try await enroll()
        _ = try await heartbeat(active: [])
        guard let job = try await claimNext() else {
            print("No queued fleet jobs")
            return false
        }
        try await execute(job)
        return true
    }

    func runDaemon() async throws {
        try await enroll()
        while !Task.isCancelled {
            do {
                _ = try await heartbeat(active: [])
                if let job = try await claimNext() { try await execute(job) }
            } catch {
                FileHandle.standardError.write(Data("vdl-fleetworker: \(error.localizedDescription)\n".utf8))
            }
            try await Task.sleep(for: .seconds(configuration.pollIntervalSeconds))
        }
    }

    private func enroll() async throws {
        let body = HostEnrollment(
            hostID: configuration.agentID, displayName: configuration.displayName,
            workerVersion: workerVersion,
            capabilities: ["heartbeat", "claim", "progress", "result", "cancellation"],
            enrolledAt: .now
        )
        let _: SimpleReply = try await send("POST", path: "v1/hosts/enroll", body: body)
    }

    private func heartbeat(active: [UUID]) async throws -> HeartbeatReply {
        try await send("POST", path: "v1/hosts/heartbeat", body: Heartbeat(
            hostID: configuration.agentID, workerVersion: workerVersion,
            activeJobIDs: active, availableSlots: max(0, configuration.maximumConcurrentJobs - active.count),
            sentAt: .now
        ))
    }

    private func claimNext() async throws -> Submission? {
        do {
            return try await send("POST", path: "v1/jobs/next/claim", body: Claim(
                hostID: configuration.agentID, claimedAt: .now
            ))
        } catch let error as WorkerError where error.localizedDescription.contains("HTTP 404") {
            return nil
        }
    }

    private func execute(_ job: Submission) async throws {
        let root = URL(fileURLWithPath: configuration.outputRoot).standardizedFileURL
        guard root.path != "/", root.path != FileManager.default.homeDirectoryForCurrentUser.path else {
            throw WorkerError.message("outputRoot must be a dedicated directory")
        }
        let output = root.appendingPathComponent(job.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: output, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let log = output.appendingPathComponent("worker.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        let executable = try resolveVDLCTL()
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "run", "--workflow", job.workflowID, "--device", job.deviceName,
            "--output", output.path,
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        var sequence: UInt64 = 1
        let started = Date()
        var cancellationRequested = false
        while process.isRunning {
            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= Double(configuration.jobTimeoutSeconds) {
                cancellationRequested = true
                process.terminate()
            }
            let heartbeatReply = try await heartbeat(active: [job.id])
            cancellationRequested = cancellationRequested || heartbeatReply.cancel_job_ids.contains(job.id.uuidString)
            let progress: ProgressReply = try await send(
                "POST", path: "v1/jobs/\(job.id.uuidString)/progress",
                body: ProgressUpdate(
                    hostID: configuration.agentID, sequence: sequence,
                    phase: cancellationRequested ? "cancelling" : "running",
                    percent: min(99, elapsed / Double(configuration.jobTimeoutSeconds) * 100),
                    message: cancellationRequested ? "Cancellation acknowledged by worker." : "Worker process is running.",
                    sentAt: .now
                )
            )
            cancellationRequested = cancellationRequested || progress.cancel_requested
            if cancellationRequested && process.isRunning { process.terminate() }
            sequence += 1
            if process.isRunning { try await Task.sleep(for: .seconds(configuration.pollIntervalSeconds)) }
        }
        process.waitUntilExit()
        try logHandle.synchronize()
        let digest = try fileDigest(log)
        let exitCode = cancellationRequested ? 130 : Int(process.terminationStatus)
        let succeeded = exitCode == 0
        let result = WorkerResult(
            hostID: configuration.agentID, succeeded: succeeded, exitCode: exitCode,
            summary: cancellationRequested ? "Job cancelled by controller or timeout."
                : succeeded ? "vdlctl workflow completed successfully." : "vdlctl workflow failed with exit \(exitCode).",
            evidenceSHA256: digest, completedAt: .now
        )
        let _: SimpleReply = try await send("POST", path: "v1/jobs/\(job.id.uuidString)/result", body: result)
        print("\(succeeded ? "PASS" : cancellationRequested ? "CANCELLED" : "FAIL") — \(job.id.uuidString) — \(output.path)")
    }

    private func send<Body: Encodable, Reply: Decodable>(
        _ method: String, path: String, body: Body
    ) async throws -> Reply {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme == "https", url.host == baseURL.host else {
            throw WorkerError.message("Request path escaped the configured coordinator.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.agentID, forHTTPHeaderField: "X-VDL-Agent-ID")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        guard data.count <= maximumResponseBytes else { throw WorkerError.message("Coordinator response exceeds 1 MiB.") }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(decoding: data.prefix(4_096), as: UTF8.self)
            throw WorkerError.message("HTTP \(status): \(text)")
        }
        return try decoder.decode(Reply.self, from: data)
    }

    private func resolveVDLCTL() throws -> URL {
        let candidates = [
            configuration.vdlctlPath.map(URL.init(fileURLWithPath:)),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("vdlctl"),
            URL(fileURLWithPath: "/Applications/iOS Virtual Device Lab.app/Contents/MacOS/vdlctl"),
        ].compactMap { $0 }
        guard let value = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw WorkerError.message("A runnable vdlctl executable was not found.")
        }
        let attributes = try value.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw WorkerError.message("vdlctl must be a regular non-symlink executable.")
        }
        return value
    }

    private func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func keychainIdentity(label: String) -> SecIdentity? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity, kSecAttrLabel: label,
            kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecIdentity)
    }
}

func loadConfiguration(_ path: String) throws -> WorkerConfiguration {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
          let size = values.fileSize, size > 0, size <= 1_048_576 else {
        throw WorkerError.message("Configuration must be a regular JSON file no larger than 1 MiB.")
    }
    return try JSONDecoder().decode(WorkerConfiguration.self, from: Data(contentsOf: url))
}

func option(_ name: String, arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func usage() {
    print("""
    vdl-fleetworker \(workerVersion) — mTLS virtual-device fleet worker

    Usage:
      vdl-fleetworker --config <fleet-worker.json> --once
      vdl-fleetworker --config <fleet-worker.json> --daemon

    The worker self-enrolls using its policy-authorized certificate, heartbeats,
    claims one queued job at a time, streams monotonic progress/cancellation,
    invokes vdlctl, and commits a bounded checksum-pinned result.
    """)
}

@main
enum VDLFleetWorker {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") { usage(); return }
        do {
            guard let path = option("--config", arguments: arguments),
                  arguments.contains("--once") || arguments.contains("--daemon") else {
                throw WorkerError.message("--config and either --once or --daemon are required")
            }
            let client = try FleetWorkerClient(configuration: loadConfiguration(path))
            if arguments.contains("--daemon") { try await client.runDaemon() }
            else { _ = try await client.runOnce() }
        } catch {
            FileHandle.standardError.write(Data("vdl-fleetworker: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
