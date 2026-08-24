import CryptoKit
import Darwin
import Foundation
import OSLog
import Security

// MARK: - Cross-process state safety

enum AdvisoryFileLock {
    static func withLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EBUSY) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

enum SecureFilesystem {
    static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func protectFile(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Streaming encrypted backup container

enum BackupArchiveCryptoError: LocalizedError {
    case archiveFailed(String)
    case invalidContainer
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case let .archiveFailed(message): "Backup archive operation failed: \(message)"
        case .invalidContainer: "The encrypted backup container is invalid or truncated."
        case .authenticationFailed: "The backup passphrase is incorrect or the archive was modified."
        }
    }
}

enum BackupArchiveCrypto {
    private static let magic = Data("VDLBACKUP1\n".utf8)
    private static let rounds: UInt32 = 120_000
    private static let chunkSize = 4 * 1_024 * 1_024

    static func encrypt(directory: URL, passphrase: String) throws -> URL {
        let zip = directory.deletingLastPathComponent()
            .appendingPathComponent(".\(directory.lastPathComponent)-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        let archive = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--keepParent", directory.path, zip.path],
            timeout: 24 * 60 * 60
        )
        guard archive.succeeded else { throw BackupArchiveCryptoError.archiveFailed(archive.output) }

        let destination = URL(fileURLWithPath: directory.path + ".vdlbackup", isDirectory: false)
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let input = try FileHandle(forReadingFrom: zip)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let key = deriveKey(passphrase: passphrase, salt: salt, rounds: rounds)
        try output.write(contentsOf: magic)
        try output.write(contentsOf: salt)
        try output.write(contentsOf: integerData(rounds))
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            let sealed = try AES.GCM.seal(chunk, using: key)
            guard let combined = sealed.combined else { throw BackupArchiveCryptoError.authenticationFailed }
            try output.write(contentsOf: integerData(UInt32(combined.count)))
            try output.write(contentsOf: combined)
        }
        try output.write(contentsOf: integerData(0))
        try output.synchronize()
        return destination
    }

    static func withDecryptedDirectory<T>(
        _ container: URL,
        passphrase: String,
        _ body: (URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vdl-restore-\(UUID().uuidString)", isDirectory: true)
        try SecureFilesystem.prepareDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("backup.zip")
        try decrypt(container: container, to: zip, passphrase: passphrase)
        let extraction = root.appendingPathComponent("Extracted", isDirectory: true)
        try SecureFilesystem.prepareDirectory(extraction)
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-q", zip.path, "-d", extraction.path],
            timeout: 24 * 60 * 60
        )
        guard result.succeeded else { throw BackupArchiveCryptoError.archiveFailed(result.output) }
        let children = try FileManager.default.contentsOfDirectory(
            at: extraction,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.hasDirectoryPath && $0.lastPathComponent.hasPrefix("VDL-Backup-") }
        guard children.count == 1, let directory = children.first else {
            throw BackupArchiveCryptoError.invalidContainer
        }
        return try body(directory)
    }

    private static func decrypt(container: URL, to destination: URL, passphrase: String) throws {
        let input = try FileHandle(forReadingFrom: container)
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        guard try input.read(upToCount: magic.count) == magic,
              let salt = try input.read(upToCount: 16), salt.count == 16,
              let roundData = try input.read(upToCount: 4), roundData.count == 4
        else { throw BackupArchiveCryptoError.invalidContainer }
        let configuredRounds = integer(from: roundData)
        guard configuredRounds >= 10_000, configuredRounds <= 1_000_000 else {
            throw BackupArchiveCryptoError.invalidContainer
        }
        let key = deriveKey(passphrase: passphrase, salt: salt, rounds: configuredRounds)
        while true {
            guard let sizeData = try input.read(upToCount: 4), sizeData.count == 4 else {
                throw BackupArchiveCryptoError.invalidContainer
            }
            let size = integer(from: sizeData)
            if size == 0 { break }
            guard size <= UInt32(chunkSize + 64),
                  let combined = try input.read(upToCount: Int(size)), combined.count == Int(size)
            else { throw BackupArchiveCryptoError.invalidContainer }
            do {
                let box = try AES.GCM.SealedBox(combined: combined)
                try output.write(contentsOf: AES.GCM.open(box, using: key))
            } catch {
                throw BackupArchiveCryptoError.authenticationFailed
            }
        }
        try output.synchronize()
    }

    private static func deriveKey(passphrase: String, salt: Data, rounds: UInt32) -> SymmetricKey {
        var digest = Data(SHA256.hash(data: Data(passphrase.utf8) + salt))
        for _ in 1..<rounds { digest = Data(SHA256.hash(data: digest + salt)) }
        return SymmetricKey(data: digest)
    }

    private static func integerData(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private static func integer(from data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

// MARK: - Companion backend contract

struct CompanionBackendContract: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let backendID: String
    let backendVersion: String
    let minimumHostAppVersion: String
    let hostControlProtocol: Int
    let exportExcludesCredentials: Bool
    let sourceRevision: String?

    var isCompatible: Bool {
        schemaVersion == 1
            && backendID == "vphone-cli"
            && hostControlProtocol == 3
            && exportExcludesCredentials
            && Self.compare(backendVersion, "0.8.0") >= 0
    }

    func supportsHostApp(_ version: String) -> Bool { Self.compare(version, minimumHostAppVersion) >= 0 }

    private static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

struct CompanionBackendAssessment: Codable, Hashable, Sendable {
    let binaryPath: String?
    let contract: CompanionBackendContract?
    let compatible: Bool
    let message: String

    static let unavailable = CompanionBackendAssessment(
        binaryPath: nil,
        contract: nil,
        compatible: false,
        message: "No reviewed vphone-cli companion backend was found."
    )
}

enum CompanionBackendInspector {
    static func inspect(binary: URL?) -> CompanionBackendAssessment {
        guard let binary else { return .unavailable }
        let result = ProcessExecutor.run(
            executable: binary,
            arguments: ["--vdl-contract"],
            timeout: 5,
            maximumOutputBytes: 64 * 1_024
        )
        let executableContract = result.succeeded
            ? result.output.data(using: .utf8).flatMap { try? JSONDecoder().decode(CompanionBackendContract.self, from: $0) }
            : nil
        let resource = binary
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/vdl-backend-contract.json")
        let bundledContract = (try? Data(contentsOf: resource))
            .flatMap { try? JSONDecoder().decode(CompanionBackendContract.self, from: $0) }
        guard let contract = executableContract ?? bundledContract else {
            return CompanionBackendAssessment(
                binaryPath: binary.path,
                contract: nil,
                compatible: false,
                message: "The companion did not return the required v1 backend contract (exit \(result.exitCode))."
            )
        }
        let hostVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.8.0"
        let compatible = contract.isCompatible && contract.supportsHostApp(hostVersion)
        return CompanionBackendAssessment(
            binaryPath: binary.path,
            contract: contract,
            compatible: compatible,
            message: compatible
                ? "Compatible vphone-cli \(contract.backendVersion), host-control protocol v\(contract.hostControlProtocol)\(executableContract == nil ? "; bundle metadata verified and host launch is checked separately" : "")."
                : "The companion contract/version is incompatible, or it does not guarantee credential-free exports."
        )
    }
}

// MARK: - Per-VM guest-control credential lifecycle

enum GuestCredentialLifecycleError: LocalizedError {
    case missingDeviceBundle
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingDeviceBundle: "The virtual-device bundle does not exist."
        case let .keychain(status): "The macOS Keychain rejected the guest credential operation (\(status))."
        }
    }
}

enum GuestCredentialVault {
    static let service = "com.elliotwilliams.ios-virtual-device-lab.guest-control"
    static let fileName = ".vdl-host-control-key"

    static func key(for device: VirtualDevice) throws -> Data {
        if let stored = try read(account: account(for: device)) {
            try materialize(stored, for: device)
            return stored
        }
        let legacyURL = device.bundleURL.appendingPathComponent(fileName)
        if let text = try? String(contentsOf: legacyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let decoded = Data(base64Encoded: text), decoded.count >= 32 {
            try store(decoded, account: account(for: device))
            return decoded
        }
        return try rotate(for: device)
    }

    @discardableResult
    static func rotate(for device: VirtualDevice) throws -> Data {
        guard FileManager.default.fileExists(atPath: device.bundleURL.path) else {
            throw GuestCredentialLifecycleError.missingDeviceBundle
        }
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        try store(data, account: account(for: device))
        try materialize(data, for: device)
        return data
    }

    static func revoke(for device: VirtualDevice) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: device),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GuestCredentialLifecycleError.keychain(status)
        }
        let handoff = device.bundleURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: handoff.path) {
            try FileManager.default.removeItem(at: handoff)
        }
    }

    static func removeExportedCredentialFiles(under root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return }
        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func account(for device: VirtualDevice) -> String {
        let canonical = device.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func materialize(_ data: Data, for device: VirtualDevice) throws {
        let handoff = device.bundleURL.appendingPathComponent(fileName)
        try data.base64EncodedString().write(to: handoff, atomically: true, encoding: .utf8)
        try SecureFilesystem.protectFile(handoff)
    }

    private static func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GuestCredentialLifecycleError.keychain(status) }
        return value as? Data
    }

    private static func store(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var insertion = query
            insertion.merge(attributes) { _, new in new }
            let status = SecItemAdd(insertion as CFDictionary, nil)
            guard status == errSecSuccess else { throw GuestCredentialLifecycleError.keychain(status) }
        } else if update != errSecSuccess {
            throw GuestCredentialLifecycleError.keychain(update)
        }
    }
}

// MARK: - Crash and freeze forensics

struct LaunchHealthRecord: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var launchID: UUID
    var appVersion: String?
    var launchedAt: Date
    var readyAt: Date?
    var cleanExitAt: Date?
    var consecutiveUncleanLaunches: Int
    var safeMode: Bool
    var lastHangAt: Date?
    var lastPhase: String
}

@MainActor
final class LaunchHealthMonitor: ObservableObject {
    static let shared = LaunchHealthMonitor()
    private let logger = Logger(subsystem: "com.elliotwilliams.ios-virtual-device-lab", category: "lifecycle")
    private let heartbeat = HeartbeatState()
    private var timer: DispatchSourceTimer?
    private var paths = LabPaths.default

    @Published private(set) var record = LaunchHealthRecord(
        schemaVersion: 1,
        launchID: UUID(),
        appVersion: nil,
        launchedAt: .now,
        readyAt: nil,
        cleanExitAt: nil,
        consecutiveUncleanLaunches: 0,
        safeMode: false,
        lastHangAt: nil,
        lastPhase: "initializing"
    )

    func begin(paths: LabPaths) {
        self.paths = paths
        try? SecureFilesystem.prepareDirectory(paths.stateRoot)
        let url = markerURL(paths: paths)
        let previous = try? HardeningJSON.load(LaunchHealthRecord.self, from: url)
        let failures = previous?.cleanExitAt == nil ? (previous?.consecutiveUncleanLaunches ?? 0) + 1 : 0
        record = LaunchHealthRecord(
            schemaVersion: 1,
            launchID: UUID(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            launchedAt: .now,
            readyAt: nil,
            cleanExitAt: nil,
            consecutiveUncleanLaunches: failures,
            safeMode: failures >= 3,
            lastHangAt: previous?.lastHangAt,
            lastPhase: failures >= 3 ? "safe-mode" : "launching"
        )
        persist()
        logger.info("Launch \(self.record.launchID.uuidString, privacy: .public) began; safe mode \(self.record.safeMode)")
        startWatchdog()
    }

    func markReady() {
        record.readyAt = .now
        record.lastPhase = "ready"
        persist()
    }

    func markCleanExit() {
        record.cleanExitAt = .now
        record.consecutiveUncleanLaunches = 0
        record.lastPhase = "clean-exit"
        persist()
        timer?.cancel()
        timer = nil
    }

    func disableSafeMode() {
        record.safeMode = false
        record.consecutiveUncleanLaunches = 0
        record.lastPhase = "safe-mode-cleared"
        persist()
    }

    fileprivate func markHangDetected() {
        record.lastHangAt = .now
        record.lastPhase = "hang-detected"
        persist()
    }

    private func startWatchdog() {
        timer?.cancel()
        heartbeat.touch()
        let source = makeLaunchHangWatchdog(heartbeat: heartbeat)
        source.resume()
        timer = source
    }

    private func persist() {
        try? HardeningJSON.save(record, to: markerURL(paths: paths))
    }

    private func markerURL(paths: LabPaths) -> URL {
        paths.stateRoot.appendingPathComponent("launch-health.json")
    }
}

private func makeLaunchHangWatchdog(heartbeat: HeartbeatState) -> DispatchSourceTimer {
    let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "vdl.hang-watchdog", qos: .utility))
    source.schedule(deadline: .now() + 2, repeating: 2)
    source.setEventHandler {
        DispatchQueue.main.async { heartbeat.touch() }
        if heartbeat.shouldRecordHang { recordLaunchHang() }
    }
    return source
}

private func recordLaunchHang() {
    let root = LabPaths.default.stateRoot.appendingPathComponent("Crash Reports", isDirectory: true)
    try? SecureFilesystem.prepareDirectory(root)
    let report = root.appendingPathComponent("hang-\(Int(Date().timeIntervalSince1970)).txt")
    let text = "Detected a main-thread heartbeat stall at \(Date().formatted(.iso8601)). See launch-health.json for the active launch and phase.\n"
    try? text.write(to: report, atomically: true, encoding: .utf8)
    try? SecureFilesystem.protectFile(report)
    Task { @MainActor in
        LaunchHealthMonitor.shared.markHangDetected()
    }
}

private final class HeartbeatState: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    private var lastHangReport = Date.distantPast
    func touch() { lock.withLock { date = .now } }
    var shouldRecordHang: Bool {
        lock.withLock {
            let now = Date()
            guard now.timeIntervalSince(date) > 8,
                  now.timeIntervalSince(lastHangReport) > 60 else { return false }
            lastHangReport = now
            return true
        }
    }
}
