import CryptoKit
import Darwin
import Foundation

public enum EvolutionError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(value) = self { value } else { "Invalid operation" } }
}

public enum EvolutionFiles {
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func validDigest(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
    public static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
    public static func load<T: Decodable>(_ type: T.Type, _ url: URL, maximumBytes: Int = 8_388_608) throws -> T {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= maximumBytes else {
            throw EvolutionError.invalid("Expected a bounded regular file: \(url.lastPathComponent)")
        }
        return try decode(type, data: Data(contentsOf: url))
    }
    public static func save<T: Encodable>(_ value: T, _ url: URL) throws {
        try directory(url.deletingLastPathComponent())
        try encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func lock<T>(_ url: URL, _ action: () throws -> T) throws -> T {
        try directory(url.deletingLastPathComponent())
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(.EBUSY) }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
    public static func hashFile(_ url: URL) throws -> (digest: String, bytes: Int64) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw EvolutionError.invalid("Artifact must be a regular file.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hash.update(data: chunk); bytes += Int64(chunk.count)
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
}

public struct EvolutionCommand: Codable, Sendable {
    public let output: String
    public let exitCode: Int32
    public let timedOut: Bool
    public var passed: Bool { exitCode == 0 && !timedOut }
}

private final class BoundedOutput: @unchecked Sendable {
    let lock = NSLock()
    var data = Data()
    func append(_ chunk: Data) { lock.lock(); defer { lock.unlock() }; data.append(chunk.prefix(max(0, 8_388_608 - data.count))) }
    func value() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

public enum EvolutionProcess {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30, directory: URL? = nil) -> EvolutionCommand {
        let process = Process(), pipe = Pipe(), output = BoundedOutput()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe; process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in output.append(handle.availableData) }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return EvolutionCommand(output: error.localizedDescription, exitCode: 127, timedOut: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        output.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return EvolutionCommand(output: output.value(), exitCode: process.terminationStatus, timedOut: timedOut)
    }
}

public struct HostPolicyCheck: Codable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let passed: Bool
    public let detail: String
}

public enum HostPolicyInspector {
    public static func inspect(binary: URL?) -> [HostPolicyCheck] {
        let sip = EvolutionProcess.run("/usr/bin/csrutil", ["status"])
        let research = EvolutionProcess.run("/usr/bin/csrutil", ["allow-research-guests", "status"], timeout: 5)
        var checks = [
            HostPolicyCheck(name: "SIP", passed: sip.passed, detail: sip.output),
            HostPolicyCheck(name: "Research Guests", passed: research.passed && research.output.lowercased().contains("enabled") && !research.output.contains("Pick a macOS"), detail: research.output),
        ]
        guard let binary else { return checks + [HostPolicyCheck(name: "Backend", passed: false, detail: "Select an installed backend executable.")] }
        let signature = EvolutionProcess.run("/usr/bin/codesign", ["-dv", "--verbose=4", binary.path])
        let launch = EvolutionProcess.run(binary.path, ["--help"], timeout: 10)
        let bypass = EvolutionProcess.run("/usr/bin/pgrep", ["-x", "vphone-amfidont"])
        let assessment = EvolutionProcess.run("/usr/sbin/spctl", ["--assess", "--type", "execute", binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path])
        checks += [
            HostPolicyCheck(name: "Backend signature / CDHash", passed: signature.passed, detail: signature.output),
            HostPolicyCheck(name: "Backend launch", passed: launch.passed, detail: "Exit \(launch.exitCode). \(launch.output.prefix(600))"),
            HostPolicyCheck(name: "amfidont process", passed: bypass.passed, detail: bypass.passed ? "vphone-amfidont is running. Recheck after backend replacement: its authorization can be CDHash scoped." : "The packaged backend helper is available for a user-started session after Recovery setup."),
            HostPolicyCheck(name: "Gatekeeper assessment", passed: assessment.passed, detail: assessment.output),
        ]
        return checks
    }
}

public struct UpstreamSnapshot: Codable, Sendable {
    public let repository: String
    public let installedRevision: String
    public let upstreamRevision: String
    public let checkedAt: Date
    public let compareURL: String
    public var changed: Bool { installedRevision != upstreamRevision }
}

public enum UpstreamTracker {
    public static func check(installedRevision: String) async throws -> UpstreamSnapshot {
        guard installedRevision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw EvolutionError.invalid("Pin the full installed vphone source revision before checking upstream.")
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/Lakr233/vphone-cli/commits/main")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iOS-Virtual-Device-Lab", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_097_152,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = object["sha"] as? String, sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw EvolutionError.invalid("GitHub did not return a valid bounded upstream revision.")
        }
        return UpstreamSnapshot(repository: "Lakr233/vphone-cli", installedRevision: installedRevision, upstreamRevision: sha, checkedAt: .now,
            compareURL: "https://github.com/Lakr233/vphone-cli/compare/\(installedRevision)...\(sha)")
    }
}
