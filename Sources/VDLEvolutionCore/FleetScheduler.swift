import Foundation

public struct FleetSchedulingPolicy: Codable, Sendable {
    public var maximumConcurrentPerHost: Int = 1
    public var maximumQueuedPerSubject: Int = 100
    public var maximumAttempts: Int = 3
    public var retryBackoffSeconds: Double = 30
    public var leaseSeconds: Double = 300
    public var agingSeconds: Double = 300
    public init() {}
    public func validate() throws {
        guard (1...32).contains(maximumConcurrentPerHost), (1...10000).contains(maximumQueuedPerSubject), (1...10).contains(maximumAttempts),
              (1...86400).contains(retryBackoffSeconds), (30...86400).contains(leaseSeconds), (30...86400).contains(agingSeconds) else {
            throw EvolutionError.invalid("Scheduler policy is outside bounded concurrency, quota, retry, lease, or fairness limits.")
        }
    }
}
public struct FleetScheduleEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let subject: String
    public let submittedAt: Date
    public let priority: Int
    public let requiredCapabilities: [String]
    public var attempts: Int = 0
    public var eligibleAt: Date
    public var hostID: String?
    public var leaseExpiresAt: Date?
    public init(id: UUID, subject: String, submittedAt: Date, priority: Int = 0, requiredCapabilities: [String] = []) {
        self.id = id; self.subject = subject; self.submittedAt = submittedAt; self.priority = priority
        self.requiredCapabilities = requiredCapabilities; eligibleAt = submittedAt
    }
}
public struct FleetHostMaintenance: Codable, Sendable {
    public let hostID: String
    public var draining: Bool
    public var unavailableUntil: Date?
    public init(hostID: String, draining: Bool, unavailableUntil: Date? = nil) {
        self.hostID = hostID; self.draining = draining; self.unavailableUntil = unavailableUntil
    }
}
public enum FleetScheduler {
    public static func isCurrentAttempt(reportAt: Date, claimedAt: Date) -> Bool {
        reportAt >= claimedAt
    }
    public static func next(entries: [FleetScheduleEntry], host: FleetHostMaintenance, capabilities: Set<String>, activeCount: Int,
                            policy: FleetSchedulingPolicy, now: Date = .now) -> FleetScheduleEntry? {
        guard (try? policy.validate()) != nil, !host.draining, (host.unavailableUntil ?? .distantPast) <= now,
              activeCount < policy.maximumConcurrentPerHost else { return nil }
        let runningPerSubject = Dictionary(grouping: entries.filter { $0.hostID != nil }, by: \.subject).mapValues(\.count)
        return entries.filter {
            $0.hostID == nil && $0.eligibleAt <= now && $0.attempts < policy.maximumAttempts && Set($0.requiredCapabilities).isSubset(of: capabilities)
        }.sorted { a, b in
            let ap = a.priority + Int(max(0, now.timeIntervalSince(a.submittedAt)) / policy.agingSeconds)
            let bp = b.priority + Int(max(0, now.timeIntervalSince(b.submittedAt)) / policy.agingSeconds)
            if ap != bp { return ap > bp }
            let ar = runningPerSubject[a.subject, default: 0], br = runningPerSubject[b.subject, default: 0]
            if ar != br { return ar < br }
            if a.submittedAt != b.submittedAt { return a.submittedAt < b.submittedAt }
            return a.id.uuidString < b.id.uuidString
        }.first
    }
    public static func retry(_ entry: FleetScheduleEntry, policy: FleetSchedulingPolicy, now: Date = .now) throws -> FleetScheduleEntry {
        try policy.validate()
        guard entry.attempts < policy.maximumAttempts else { throw EvolutionError.invalid("Job retry limit reached.") }
        var copy = entry
        copy.hostID = nil; copy.leaseExpiresAt = nil
        copy.eligibleAt = now.addingTimeInterval(min(86400, policy.retryBackoffSeconds * pow(2, Double(max(0, entry.attempts - 1)))))
        return copy
    }
}

/// Recovery is offline and creates a new dedicated tree. A file lock prevents two local coordinators.
/// Remote promotion still requires fencing the previous coordinator before bringing the replacement online.
public enum FleetRecoveryArchive {
    public static func snapshot(root: URL, destination: URL) throws {
        let allowed = ["Hosts", "Inbox", "Running", "Progress", "Results", "Cancelled", "CancelRequests", "Schedule", "Maintenance"]
        guard !FileManager.default.fileExists(atPath: destination.path),
              !destination.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw EvolutionError.invalid("Choose a new backup directory outside fleet state.") }
        try EvolutionFiles.directory(destination)
        var checksums = [String: String]()
        for name in allowed {
            let directory = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                let key = "\(name)/\(file.lastPathComponent)", identity = try EvolutionFiles.hashFile(file)
                let target = destination.appendingPathComponent(key)
                try EvolutionFiles.directory(target.deletingLastPathComponent())
                try FileManager.default.copyItem(at: file, to: target)
                guard try EvolutionFiles.hashFile(target).digest == identity.digest else { throw EvolutionError.invalid("Backup checksum mismatch.") }
                checksums[key] = identity.digest
            }
        }
        let audit = root.appendingPathComponent("audit.jsonl")
        if FileManager.default.fileExists(atPath: audit.path) {
            checksums["audit.jsonl"] = try EvolutionFiles.hashFile(audit).digest
            try FileManager.default.copyItem(at: audit, to: destination.appendingPathComponent("audit.jsonl"))
            guard try EvolutionFiles.hashFile(destination.appendingPathComponent("audit.jsonl")).digest == checksums["audit.jsonl"] else { throw EvolutionError.invalid("Audit changed during backup.") }
        }
        let policy = root.appendingPathComponent("scheduling-policy.json")
        if FileManager.default.fileExists(atPath: policy.path) {
            checksums["scheduling-policy.json"] = try EvolutionFiles.hashFile(policy).digest
            try FileManager.default.copyItem(at: policy, to: destination.appendingPathComponent("scheduling-policy.json"))
            guard try EvolutionFiles.hashFile(destination.appendingPathComponent("scheduling-policy.json")).digest == checksums["scheduling-policy.json"] else {
                throw EvolutionError.invalid("Scheduling policy changed during backup.")
            }
        }
        try EvolutionFiles.save(checksums, destination.appendingPathComponent("checksums.json"))
    }
    public static func restore(source: URL, destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw EvolutionError.invalid("Restore requires a new dedicated state directory.") }
        let checksums = try EvolutionFiles.load([String: String].self, source.appendingPathComponent("checksums.json"))
        guard !checksums.isEmpty, checksums.count <= 100000 else { throw EvolutionError.invalid("Empty or excessive recovery manifest.") }
        let allowed = Set(["Hosts", "Inbox", "Running", "Progress", "Results", "Cancelled", "CancelRequests", "Schedule", "Maintenance"])
        for (name, digest) in checksums {
            let components = name.split(separator: "/")
            guard ["audit.jsonl", "scheduling-policy.json"].contains(name) || (components.count == 2 && allowed.contains(String(components[0])) && !components.contains("..") && name.hasSuffix(".json")),
                  EvolutionFiles.validDigest(digest), try EvolutionFiles.hashFile(source.appendingPathComponent(name)).digest == digest else {
                throw EvolutionError.invalid("Recovery manifest path or checksum failed.")
            }
        }
        try EvolutionFiles.directory(destination)
        for (name, digest) in checksums {
            let target = destination.appendingPathComponent(name)
            try EvolutionFiles.directory(target.deletingLastPathComponent())
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: target)
            guard try EvolutionFiles.hashFile(target).digest == digest else { throw EvolutionError.invalid("Restore checksum failed.") }
        }
    }
}
