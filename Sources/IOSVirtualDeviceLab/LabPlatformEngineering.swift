import CryptoKit
import Foundation

// MARK: - 1. Backend adapter SDK and conformance

struct BackendAdapterManifest: Identifiable, Codable, Hashable, Sendable {
    var schemaVersion: Int
    var id: String
    var name: String
    var version: String
    var protocolVersion: Int
    var capabilities: [String]
    var minimumLabVersion: String
    var executablePath: String?
    var licenseReference: String
}

struct AdapterConformanceCheck: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let passed: Bool
    let evidence: String
}

struct AdapterConformanceReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let adapterID: String?
    let checks: [AdapterConformanceCheck]
    var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
    static let empty = AdapterConformanceReport(generatedAt: .distantPast, adapterID: nil, checks: [])
}

enum BackendAdapterConformance {
    static let protocolVersion = 3
    static let labVersion = "0.10.0"
    static let capabilities = Set([
        "lifecycle", "pause", "screenshots", "automation", "guestLogs", "networking",
        "audio", "performanceMetrics", "crashExport", "xcodeDeployment", "snapshotRestore",
        "deterministicReset", "timelineVideo",
    ])

    static let example = BackendAdapterManifest(
        schemaVersion: 1,
        id: "com.example.virtual-device-adapter",
        name: "Example Virtual Device Adapter",
        version: "0.1.0",
        protocolVersion: protocolVersion,
        capabilities: ["lifecycle", "screenshots", "snapshotRestore"],
        minimumLabVersion: "0.10.0",
        executablePath: nil,
        licenseReference: "THIRD_PARTY.md#example-virtual-device-adapter"
    )

    static func evaluate(_ manifest: BackendAdapterManifest) -> AdapterConformanceReport {
        let identifier = try? NSRegularExpression(pattern: "^[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+){2,}$")
        let semver = try? NSRegularExpression(pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
        func matches(_ expression: NSRegularExpression?, _ value: String) -> Bool {
            expression?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
        let unknown = manifest.capabilities.filter { !capabilities.contains($0) }.sorted()
        let duplicates = Dictionary(grouping: manifest.capabilities, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        let executable: AdapterConformanceCheck
        if let path = manifest.executablePath, !path.isEmpty {
            executable = .init(
                id: "executable", passed: FileManager.default.isExecutableFile(atPath: path),
                evidence: FileManager.default.isExecutableFile(atPath: path) ? "Executable is present and runnable." : "Configured executable is missing or is not executable."
            )
        } else {
            executable = .init(id: "executable", passed: true, evidence: "Manifest-only validation; runtime probe was not requested.")
        }
        return AdapterConformanceReport(generatedAt: .now, adapterID: manifest.id, checks: [
            .init(id: "schema", passed: manifest.schemaVersion == 1, evidence: "Schema \(manifest.schemaVersion); required 1."),
            .init(id: "identifier", passed: matches(identifier, manifest.id), evidence: "Adapter IDs must be stable, reverse-domain identifiers."),
            .init(id: "version", passed: matches(semver, manifest.version), evidence: "Adapter version must use semantic versioning."),
            .init(
                id: "minimum-lab-version",
                passed: matches(semver, manifest.minimumLabVersion) && version(manifest.minimumLabVersion, isAtMost: labVersion),
                evidence: "Adapter requires lab \(manifest.minimumLabVersion); this build is \(labVersion)."
            ),
            .init(id: "protocol", passed: manifest.protocolVersion == protocolVersion, evidence: "Protocol \(manifest.protocolVersion); required \(protocolVersion)."),
            .init(id: "capabilities", passed: !manifest.capabilities.isEmpty && unknown.isEmpty && duplicates.isEmpty,
                  evidence: unknown.isEmpty && duplicates.isEmpty ? "\(manifest.capabilities.count) declared capability/capabilities are recognized." : "Unknown: \(unknown.joined(separator: ", ")); duplicates: \(duplicates.joined(separator: ", "))."),
            executable,
            .init(id: "license", passed: !manifest.licenseReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  evidence: "A provenance and license reference is required for every adapter."),
        ])
    }

    static func load(_ url: URL) throws -> BackendAdapterManifest {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else {
            throw CocoaError(.fileReadTooLarge)
        }
        return try HardeningJSON.load(BackendAdapterManifest.self, from: url)
    }

    private static func version(_ required: String, isAtMost current: String) -> Bool {
        func components(_ value: String) -> [Int]? {
            let core = value.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
            let values = core.split(separator: ".").compactMap { Int($0) }
            return values.count == 3 ? values : nil
        }
        guard let required = components(required), let current = components(current) else { return false }
        return required.lexicographicallyPrecedes(current) || required == current
    }

    static func exportSDK(to directory: URL) throws -> URL {
        try SecureFilesystem.prepareDirectory(directory)
        let manifest = directory.appendingPathComponent("adapter-manifest.example.json")
        try HardeningJSON.save(example, to: manifest)
        let schema: [String: Any] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": "https://virtualdevicelab.dev/schemas/backend-adapter-manifest-v1.json",
            "title": "Virtual Device Lab Backend Adapter Manifest",
            "type": "object",
            "additionalProperties": false,
            "required": ["schemaVersion", "id", "name", "version", "protocolVersion", "capabilities", "minimumLabVersion", "licenseReference"],
            "properties": [
                "schemaVersion": ["const": 1], "id": ["type": "string"], "name": ["type": "string"],
                "version": ["type": "string"], "protocolVersion": ["const": protocolVersion],
                "capabilities": ["type": "array", "uniqueItems": true, "items": ["type": "string", "enum": capabilities.sorted()]] as [String: Any],
                "minimumLabVersion": ["type": "string"], "executablePath": ["type": ["string", "null"]],
                "licenseReference": ["type": "string"],
            ] as [String: Any],
        ]
        let schemaURL = directory.appendingPathComponent("adapter-manifest.schema.json")
        try JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys])
            .write(to: schemaURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try SecureFilesystem.protectFile(schemaURL)
        let readme = """
        # Virtual Device Lab Backend Adapter SDK

        Implement protocol v\(protocolVersion), declare only capabilities the executable actually supports, and keep the adapter process outside the SwiftUI frontend. Run `vdlctl adapter check --manifest adapter-manifest.json` before installation. Runtime operations fail closed when a declared capability is unavailable.
        """
        let readmeURL = directory.appendingPathComponent("README.md")
        try Data(readme.utf8).write(to: readmeURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try SecureFilesystem.protectFile(readmeURL)
        return directory
    }
}

// MARK: - 2. Deterministic test reset

struct DeterministicResetPolicy: Codable, Hashable, Sendable {
    var restoreGoldenSnapshot: Bool
    var reinstallApplication: Bool
    var resetAppData: Bool
    var resetPermissions: Bool
    var resetKeychain: Bool
    var resetNetwork: Bool
    var reapplyEnvironment: Bool

    static let standard = DeterministicResetPolicy(
        restoreGoldenSnapshot: true, reinstallApplication: true, resetAppData: true,
        resetPermissions: true, resetKeychain: true, resetNetwork: true, reapplyEnvironment: true
    )
}

struct ResetPlanStep: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let order: Int
    let action: String
    let supported: Bool
    let evidence: String
}

struct DeterministicResetPlan: Codable, Hashable, Sendable {
    let id: UUID
    let generatedAt: Date
    let deviceName: String?
    let fixtureID: UUID?
    let steps: [ResetPlanStep]
    let blockers: [String]
    var canExecute: Bool { blockers.isEmpty && !steps.isEmpty && steps.allSatisfy(\.supported) }
    static let empty = DeterministicResetPlan(id: UUID(), generatedAt: .distantPast, deviceName: nil, fixtureID: nil, steps: [], blockers: ["No reset has been planned."])
}

enum DeterministicResetPlanner {
    static func plan(
        device: VirtualDevice?, fixture: CanonicalVMFixture?, policy: DeterministicResetPolicy,
        backendCapabilities: Set<String>
    ) -> DeterministicResetPlan {
        var blockers: [String] = []
        if device == nil { blockers.append("Select a virtual device.") }
        if device?.isRunning == true { blockers.append("Stop the virtual device before deterministic reset.") }
        if fixture == nil { blockers.append("Record a verified canonical fixture for this device.") }
        if let device, let fixture, fixture.deviceName != device.name { blockers.append("The fixture belongs to a different virtual device.") }
        var actions: [(Bool, String, String, String)] = [
            (policy.restoreGoldenSnapshot, "Restore the hash-verified golden snapshot", "snapshotRestore", "Restores the guest disk and machine state."),
            (policy.reinstallApplication, "Uninstall and reinstall the pinned application build", "xcodeDeployment", "Prevents an existing install from hiding deployment failures."),
            (policy.resetAppData, "Clear application container and caches", "deterministicReset", "Requires an authenticated guest reset operation."),
            (policy.resetPermissions, "Reset privacy permission decisions", "deterministicReset", "Reapplies the selected environment profile."),
            (policy.resetKeychain, "Clear application keychain namespace", "deterministicReset", "Never exports guest keychain contents."),
            (policy.resetNetwork, "Reset network state and proxy configuration", "networking", "Returns the guest to the declared network profile."),
            (policy.reapplyEnvironment, "Reapply locale, time zone, appearance, and pressure settings", "automation", "Makes repeated test inputs comparable."),
        ]
        actions = actions.filter(\.0)
        let steps = actions.enumerated().map { index, entry in
            let supported = backendCapabilities.contains(entry.2)
            return ResetPlanStep(id: UUID(), order: index + 1, action: entry.1, supported: supported,
                                 evidence: supported ? entry.3 : "Backend capability `\(entry.2)` is not available.")
        }
        let missing = steps.filter { !$0.supported }.map(\.evidence)
        blockers.append(contentsOf: missing)
        return DeterministicResetPlan(id: UUID(), generatedAt: .now, deviceName: device?.name, fixtureID: fixture?.id, steps: steps, blockers: blockers)
    }
}

// MARK: - 3. Build, signing, and symbol catalog

struct BuildIdentityRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let importedAt: Date
    let artifactID: UUID
    let appName: String
    let bundleIdentifier: String?
    let marketingVersion: String?
    let buildNumber: String?
    let sha256: String?
    let signingTeamIdentifier: String?
    let signingAuthority: String?
    let entitlementsSHA256: String?
    let executableUUIDs: [String]
    let dSYMPaths: [String]
    let sourceRevision: String?
    let warnings: [String]
}

enum BuildIdentityCatalog {
    static func index(artifact: AppArtifact, sourceRevision: String? = nil, dSYM: URL? = nil) -> BuildIdentityRecord {
        let url = artifact.url
        var info: [String: Any] = [:]
        if url.pathExtension.lowercased() == "app",
           let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            info = plist
        }
        var warnings: [String] = []
        if info.isEmpty { warnings.append("Bundle metadata is unavailable; import an expanded .app to index Info.plist fields.") }
        let signing = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-d", "--verbose=4", url.path], timeout: 30, maximumOutputBytes: 256 * 1_024
        ).output
        func signingValue(_ prefix: String) -> String? {
            guard let line = signing.components(separatedBy: .newlines).first(where: { $0.hasPrefix(prefix) }) else { return nil }
            let value = String(line.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }
        let entitlements = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-d", "--entitlements", ":-", url.path],
            timeout: 30, maximumOutputBytes: 1_048_576
        )
        let entitlementsHash = entitlements.succeeded && !entitlements.output.isEmpty
            ? SHA256.hash(data: Data(entitlements.output.utf8)).map { String(format: "%02x", $0) }.joined() : nil
        let binaryName = info["CFBundleExecutable"] as? String
        let binary = binaryName.map { url.appendingPathComponent($0) } ?? url
        let uuids = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/dwarfdump"), arguments: ["--uuid", binary.path],
            timeout: 30, maximumOutputBytes: 256 * 1_024
        ).output.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("UUID: ") else { return nil }
            return line.split(separator: " ").dropFirst().first.map(String.init)
        }
        if signingValue("TeamIdentifier=") == nil { warnings.append("No signing team identity was found.") }
        if uuids.isEmpty { warnings.append("No executable UUID was found; crash symbolication will be unavailable.") }
        return BuildIdentityRecord(
            id: UUID(), importedAt: .now, artifactID: artifact.id, appName: artifact.name,
            bundleIdentifier: info["CFBundleIdentifier"] as? String,
            marketingVersion: info["CFBundleShortVersionString"] as? String,
            buildNumber: info["CFBundleVersion"] as? String, sha256: artifact.sha256,
            signingTeamIdentifier: signingValue("TeamIdentifier="), signingAuthority: signingValue("Authority="),
            entitlementsSHA256: entitlementsHash, executableUUIDs: uuids,
            dSYMPaths: dSYM.map { [$0.path] } ?? [],
            sourceRevision: sourceRevision.flatMap { $0.isEmpty ? nil : $0 }, warnings: warnings
        )
    }
}

// MARK: - 4. Reproducible failure bundles

struct FailureReplayManifest: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let schemaVersion: Int
    let generatedAt: Date
    let runID: UUID
    let runName: String
    let runState: TestRunState
    let deviceNames: [String]
    let appArtifactID: UUID?
    let labfile: LabfileDocument?
    let environmentAssignments: [String: UUID]
    let fixtureIDs: [UUID]
    let diagnosticPaths: [String]
    let screenshotPaths: [String]
    let exclusions: [String]
}

struct FailureReplayBundleRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let generatedAt: Date
    let runID: UUID
    let path: String
    let manifestSHA256: String
}

enum FailureReplayBundler {
    static func create(
        run: TestRunRecord, labfile: LabfileDocument?, assignments: [String: UUID],
        fixtures: [CanonicalVMFixture], paths: LabPaths
    ) throws -> FailureReplayBundleRecord {
        guard run.state == .failed || run.results.contains(where: { $0.state == .failed }) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let directory = paths.stateRoot.appendingPathComponent("Failure Replay Bundles", isDirectory: true)
            .appendingPathComponent("\(run.id.uuidString)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try SecureFilesystem.prepareDirectory(directory)
        let deviceNames = run.results.map(\.deviceName)
        let manifest = FailureReplayManifest(
            id: UUID(), schemaVersion: 1, generatedAt: .now, runID: run.id, runName: run.name,
            runState: run.state, deviceNames: deviceNames, appArtifactID: run.appArtifactID, labfile: labfile,
            environmentAssignments: assignments.filter { deviceNames.contains($0.key) },
            fixtureIDs: fixtures.filter { deviceNames.contains($0.deviceName) }.map(\.id),
            diagnosticPaths: run.results.compactMap(\.diagnosticBundlePath), screenshotPaths: run.results.compactMap(\.screenshotPath),
            exclusions: ["Apple firmware", "virtual disks", "guest credentials", "signing keys", "secret values", "raw external files"]
        )
        let manifestURL = directory.appendingPathComponent("replay-manifest.json")
        try HardeningJSON.save(manifest, to: manifestURL)
        func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var commandParts = ["vdlctl", "run", "--workflow", run.kind == .deployment ? "deployment" : "boot-smoke"]
        for device in deviceNames { commandParts += ["--device", device] }
        if let artifactID = run.appArtifactID { commandParts += ["--app-artifact", artifactID.uuidString] }
        commandParts += ["--output", "./replay-results"]
        let command = "#!/bin/zsh\nset -euo pipefail\n" + commandParts.map(shellQuote).joined(separator: " ") + "\n"
        let commandURL = directory.appendingPathComponent("replay.command")
        try Data(command.utf8).write(to: commandURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commandURL.path)
        return FailureReplayBundleRecord(
            id: manifest.id, generatedAt: manifest.generatedAt, runID: run.id, path: directory.path,
            manifestSHA256: try fileSHA256(manifestURL)
        )
    }
}

// MARK: - 5. Flakiness and regression analysis

struct RetryAndRegressionPolicy: Codable, Hashable, Sendable {
    var maximumRetries: Int
    var retryInfrastructureFailuresOnly: Bool
    var flakyPassRateFloorPercent: Double
    var quarantineFailureCount: Int
    var performanceRegressionPercent: Double
    static let standard = RetryAndRegressionPolicy(
        maximumRetries: 1, retryInfrastructureFailuresOnly: true, flakyPassRateFloorPercent: 20,
        quarantineFailureCount: 3, performanceRegressionPercent: 20
    )
}

struct RunTrend: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let runName: String
    let deviceName: String
    let sampleCount: Int
    let passRatePercent: Double
    let consecutiveFailures: Int
    let p50DurationSeconds: Double?
    let p95DurationSeconds: Double?
    let flaky: Bool
    let quarantined: Bool
    let performanceRegression: Bool
}

struct RunTrendReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let trends: [RunTrend]
    static let empty = RunTrendReport(generatedAt: .distantPast, trends: [])
}

enum RunTrendAnalyzer {
    private struct Observation { let passed: Bool; let completedAt: Date; let duration: Double }

    static func evaluate(runs: [TestRunRecord], policy: RetryAndRegressionPolicy) -> RunTrendReport {
        var groups: [String: (String, String, [Observation])] = [:]
        for run in runs {
            for result in run.results where result.state == .passed || result.state == .failed {
                let completed = result.completedAt ?? run.completedAt ?? result.startedAt
                let observation = Observation(
                    passed: result.state == .passed, completedAt: completed,
                    duration: max(0, completed.timeIntervalSince(result.startedAt))
                )
                let key = "\(run.name.lowercased())|\(result.deviceName.lowercased())"
                groups[key, default: (run.name, result.deviceName, [])].2.append(observation)
            }
        }
        let trends = groups.map { key, group -> RunTrend in
            let ordered = group.2.sorted { $0.completedAt < $1.completedAt }
            let passRate = Double(ordered.filter(\.passed).count) / Double(ordered.count) * 100
            let consecutive = ordered.reversed().prefix { !$0.passed }.count
            let durations = ordered.map(\.duration).sorted()
            func percentile(_ p: Double) -> Double? {
                guard !durations.isEmpty else { return nil }
                return durations[min(durations.count - 1, max(0, Int(ceil(Double(durations.count) * p)) - 1))]
            }
            let recent = ordered.suffix(max(1, ordered.count / 3)).map(\.duration)
            let prior = ordered.dropLast(recent.count).map(\.duration)
            let recentMean = recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count)
            let priorMean = prior.isEmpty ? 0 : prior.reduce(0, +) / Double(prior.count)
            let regressed = prior.count >= 2 && recentMean > priorMean * (1 + policy.performanceRegressionPercent / 100)
            return RunTrend(
                id: key, runName: group.0, deviceName: group.1, sampleCount: ordered.count,
                passRatePercent: passRate, consecutiveFailures: consecutive,
                p50DurationSeconds: percentile(0.5), p95DurationSeconds: percentile(0.95),
                flaky: ordered.count >= 3 && passRate >= policy.flakyPassRateFloorPercent && passRate < 100,
                quarantined: consecutive >= policy.quarantineFailureCount, performanceRegression: regressed
            )
        }.sorted { $0.id < $1.id }
        return RunTrendReport(generatedAt: .now, trends: trends)
    }
}

// MARK: - 6. Multi-Mac fleet scheduling

enum FleetHostState: String, Codable, CaseIterable, Sendable { case online, offline, degraded }

struct FleetHostRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var endpoint: String?
    var state: FleetHostState
    var drained: Bool
    var capabilities: [String]
    var maximumConcurrentVMs: Int
    var runningVMs: Int
    var memoryMB: Int
    var lastSeen: Date
}

struct FleetJobRequest: Codable, Hashable, Sendable {
    var name: String
    var requiredCapabilities: [String]
    var requiredMemoryMB: Int
}

struct FleetPlacementDecision: Codable, Hashable, Sendable {
    let generatedAt: Date
    let request: FleetJobRequest
    let hostID: UUID?
    let hostName: String?
    let blockers: [String]
    var placed: Bool { hostID != nil && blockers.isEmpty }
    static let empty = FleetPlacementDecision(
        generatedAt: .distantPast,
        request: FleetJobRequest(name: "No job", requiredCapabilities: [], requiredMemoryMB: 0),
        hostID: nil, hostName: nil, blockers: ["No placement has been requested."]
    )
}

enum FleetScheduler {
    static func localHost(capabilities: [String], maximumConcurrentVMs: Int) -> FleetHostRecord {
        FleetHostRecord(
            id: stableLocalHostID(), name: Host.current().localizedName ?? "This Mac", endpoint: nil,
            state: .online, drained: false, capabilities: capabilities.sorted(),
            maximumConcurrentVMs: max(1, maximumConcurrentVMs), runningVMs: 0,
            memoryMB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576), lastSeen: .now
        )
    }

    static func place(_ request: FleetJobRequest, on hosts: [FleetHostRecord]) -> FleetPlacementDecision {
        let required = Set(request.requiredCapabilities)
        let eligible = hosts.filter { host in
            host.state == .online && !host.drained && host.runningVMs < host.maximumConcurrentVMs
                && host.memoryMB >= request.requiredMemoryMB && required.isSubset(of: Set(host.capabilities))
        }.sorted {
            let left = $0.maximumConcurrentVMs - $0.runningVMs
            let right = $1.maximumConcurrentVMs - $1.runningVMs
            return left == right ? $0.memoryMB > $1.memoryMB : left > right
        }
        guard let host = eligible.first else {
            return FleetPlacementDecision(
                generatedAt: .now, request: request, hostID: nil, hostName: nil,
                blockers: ["No online, non-drained host satisfies capability, memory, and concurrency requirements."]
            )
        }
        return FleetPlacementDecision(generatedAt: .now, request: request, hostID: host.id, hostName: host.name, blockers: [])
    }

    private static func stableLocalHostID() -> UUID {
        let source = ProcessInfo.processInfo.hostName
        let bytes = Array(SHA256.hash(data: Data(source.utf8)).prefix(16))
        var tuple: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &tuple) { buffer in buffer.copyBytes(from: bytes) }
        return UUID(uuid: tuple)
    }
}

// MARK: - 7. Unified timeline

enum TimelineEventKind: String, Codable, Sendable { case run, assertion, log, screenshot, diagnostics, performance, video }

struct UnifiedTimelineEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let kind: TimelineEventKind
    let deviceName: String?
    let summary: String
    let artifactPath: String?
}

struct UnifiedTimelineRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let generatedAt: Date
    let runID: UUID
    let events: [UnifiedTimelineEvent]
    let unavailableSources: [String]
    let path: String?
}

enum UnifiedTimelineBuilder {
    static func build(run: TestRunRecord, logs: [LogEntry], performance: [String: PerformanceSample], videoSupported: Bool) -> UnifiedTimelineRecord {
        var events = [UnifiedTimelineEvent(
            id: UUID(), timestamp: run.createdAt, kind: .run, deviceName: nil,
            summary: "Run \(run.name) entered \(run.state.rawValue).", artifactPath: run.reportPath
        )]
        for result in run.results {
            events.append(.init(id: UUID(), timestamp: result.startedAt, kind: .run, deviceName: result.deviceName,
                                summary: "Device execution started.", artifactPath: nil))
            for assertion in result.assertionResults ?? [] {
                events.append(.init(id: UUID(), timestamp: result.completedAt ?? result.startedAt, kind: .assertion,
                                    deviceName: result.deviceName, summary: "\(assertion.assertion.kind.displayName): \(assertion.passed ? "passed" : "failed") — \(assertion.message)", artifactPath: nil))
            }
            if let screenshot = result.screenshotPath {
                events.append(.init(id: UUID(), timestamp: result.completedAt ?? result.startedAt, kind: .screenshot,
                                    deviceName: result.deviceName, summary: "Screenshot captured.", artifactPath: screenshot))
            }
            if let diagnostics = result.diagnosticBundlePath {
                events.append(.init(id: UUID(), timestamp: result.completedAt ?? result.startedAt, kind: .diagnostics,
                                    deviceName: result.deviceName, summary: "Diagnostic bundle captured.", artifactPath: diagnostics))
            }
        }
        let end = run.completedAt ?? .now
        events += logs.filter { $0.timestamp >= run.createdAt && $0.timestamp <= end }.map {
            .init(id: UUID(), timestamp: $0.timestamp, kind: .log, deviceName: $0.scope,
                  summary: "[\($0.level.rawValue)] \($0.message)", artifactPath: nil)
        }
        events += performance.values.filter { $0.timestamp >= run.createdAt && $0.timestamp <= end }.map {
            .init(id: UUID(), timestamp: $0.timestamp, kind: .performance, deviceName: $0.deviceName,
                  summary: "CPU \($0.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"), memory \($0.residentMemoryBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) } ?? "—").", artifactPath: nil)
        }
        return UnifiedTimelineRecord(
            id: UUID(), generatedAt: .now, runID: run.id, events: events.sorted { $0.timestamp < $1.timestamp },
            unavailableSources: videoSupported ? [] : ["Synchronized guest video requires a backend timelineVideo capability."], path: nil
        )
    }

    static func save(_ timeline: UnifiedTimelineRecord, paths: LabPaths) throws -> UnifiedTimelineRecord {
        let directory = paths.stateRoot.appendingPathComponent("Unified Timelines", isDirectory: true)
        try SecureFilesystem.prepareDirectory(directory)
        let url = directory.appendingPathComponent("\(timeline.runID.uuidString)-\(Int(timeline.generatedAt.timeIntervalSince1970)).json")
        var persisted = timeline
        persisted = UnifiedTimelineRecord(id: timeline.id, generatedAt: timeline.generatedAt, runID: timeline.runID,
                                          events: timeline.events, unavailableSources: timeline.unavailableSources, path: url.path)
        try HardeningJSON.save(persisted, to: url)
        return persisted
    }
}

// MARK: - 8. Threat model and secret inventory

enum SecurityControlState: String, Codable, Sendable { case passed, actionRequired, unavailable }

struct ThreatModelItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let boundary: String
    let threat: String
    let control: String
    let state: SecurityControlState
    let evidence: String
}

struct SecretInventoryItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let purpose: String
    let storage: String
    let rotation: String
    let revocation: String
    let exportAllowed: Bool
    let present: Bool
}

struct SecurityPostureReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let threats: [ThreatModelItem]
    let secrets: [SecretInventoryItem]
    var passed: Bool { !threats.isEmpty && threats.allSatisfy { $0.state != .actionRequired } }
    static let empty = SecurityPostureReport(generatedAt: .distantPast, threats: [], secrets: [])
}

enum SecurityPostureEvaluator {
    static func evaluate(paths: LabPaths, devices: [VirtualDevice], remoteAgentConfigured: Bool) -> SecurityPostureReport {
        let statePermissions = (try? FileManager.default.attributesOfItem(atPath: paths.stateRoot.path)[.posixPermissions] as? NSNumber)?.intValue
        let protected = statePermissions.map { $0 & 0o077 == 0 } == true
        let guestCredentials = devices.map { device in
            device.bundleURL.appendingPathComponent(".vdl-guest-credential", isDirectory: false)
        }
        let presentCredentials = guestCredentials.filter { FileManager.default.fileExists(atPath: $0.path) }.count
        let threats = [
            ThreatModelItem(id: "host-filesystem", boundary: "SwiftUI app → host filesystem", threat: "Path traversal or over-broad file access", control: "Canonical roots, bounded imports, restrictive permissions", state: protected ? .passed : .actionRequired, evidence: protected ? "State root excludes group/other access." : "State root permissions require repair."),
            ThreatModelItem(id: "frontend-backend", boundary: "Frontend → backend adapter", threat: "Capability spoofing or command injection", control: "Versioned manifest, argument arrays, conformance gate", state: .passed, evidence: "Adapter protocol v3 is validated before use."),
            ThreatModelItem(id: "host-guest", boundary: "Host → virtual guest", threat: "Replay or unauthenticated guest commands", control: "Per-device HMAC credentials, clock-skew and replay protection", state: devices.isEmpty || presentCredentials == devices.count ? .passed : .actionRequired, evidence: "\(presentCredentials)/\(devices.count) device credential file(s) present."),
            ThreatModelItem(id: "network", boundary: "Guest → network", threat: "Unintended host/LAN reachability", control: "Explicit offline/NAT/bridged policy", state: .passed, evidence: "Network mode is explicit per virtual device."),
            ThreatModelItem(id: "fleet", boundary: "Controller → remote agents", threat: "Unauthorized remote jobs or evidence access", control: "Authenticated agent configuration and drain state", state: remoteAgentConfigured ? .passed : .unavailable, evidence: remoteAgentConfigured ? "Remote agent configuration is present." : "Remote fleet execution is not enabled."),
        ]
        let secrets = [
            SecretInventoryItem(id: "guest-hmac", purpose: "Authenticate per-device guest control", storage: "Per-VM credential file (0600)", rotation: "On restore and manual rotation", revocation: "Delete or rotate the device credential", exportAllowed: false, present: devices.isEmpty || presentCredentials > 0),
            SecretInventoryItem(id: "evidence-signing", purpose: "Seal qualification evidence", storage: "macOS Keychain", rotation: "Operator-managed", revocation: "Remove Keychain item and invalidate seals", exportAllowed: false, present: false),
            SecretInventoryItem(id: "agent-auth", purpose: "Authenticate remote lab agents", storage: "Protected agent configuration / Keychain", rotation: "Before expiry or incident", revocation: "Disable agent and rotate token", exportAllowed: false, present: remoteAgentConfigured),
            SecretInventoryItem(id: "developer-id", purpose: "Sign and notarize app releases", storage: "macOS Keychain / CI secret store", rotation: "Apple certificate lifecycle", revocation: "Revoke in Apple Developer account", exportAllowed: false, present: false),
        ]
        return SecurityPostureReport(generatedAt: .now, threats: threats, secrets: secrets)
    }
}

// MARK: - 9. Deterministic fuzzing and coverage gates

struct FuzzAndCoveragePolicy: Codable, Hashable, Sendable {
    var seed: UInt64
    var caseCount: Int
    var minimumPassPercent: Double
    var minimumSourceCoveragePercent: Double
    var measuredSourceCoveragePercent: Double?
    static let standard = FuzzAndCoveragePolicy(seed: 0x56444C, caseCount: 500, minimumPassPercent: 100, minimumSourceCoveragePercent: 75, measuredSourceCoveragePercent: nil)
}

struct FuzzCaseSummary: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let cases: Int
    let failures: Int
    let behaviorClasses: [String]
}

struct EngineeringQualityReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let seed: UInt64
    let totalCases: Int
    let failedCases: Int
    let suites: [FuzzCaseSummary]
    let fuzzGatePassed: Bool
    let coverageGatePassed: Bool
    let coverageEvidence: String
    var passed: Bool { fuzzGatePassed && coverageGatePassed }
    static let empty = EngineeringQualityReport(generatedAt: .distantPast, seed: 0, totalCases: 0, failedCases: 0, suites: [], fuzzGatePassed: false, coverageGatePassed: false, coverageEvidence: "Coverage has not been measured.")
}

enum EngineeringQualityEvaluator {
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    static func run(policy: FuzzAndCoveragePolicy) -> EngineeringQualityReport {
        let count = min(10_000, max(1, policy.caseCount))
        var generator = Generator(state: policy.seed)
        var archiveFailures = 0
        var jsonFailures = 0
        var behaviors = Set<String>()
        let dangerous = ["../secret", "/etc/passwd", "a/../../b", "~/.ssh/id_ed25519", "a\\0b", "./safe", "safe/file.json"]
        for index in 0..<count {
            let selector = Int(generator.next() % UInt64(dangerous.count))
            let suffix = String(generator.next(), radix: 36)
            let path = dangerous[selector] + (index.isMultiple(of: 4) ? suffix : "")
            let expectedSafe = !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
                && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
                && !path.split(separator: "/", omittingEmptySubsequences: false).contains("")
            let actualSafe = HostileInputValidator.isSafeArchivePath(path)
            behaviors.insert(actualSafe ? "accepted-relative" : "rejected-unsafe")
            if actualSafe != expectedSafe { archiveFailures += 1 }

            let json: Data
            let jsonKind = generator.next() % 4
            switch jsonKind {
            case 0: json = Data("{\"schemaVersion\":1,\"name\":\"\(suffix)\",\"backendID\":\"com.virtualdevicelab.vphone\",\"devices\":[]}".utf8)
            case 1: json = Data("{\"schemaVersion\":999,\"devices\":[]}".utf8)
            case 2: json = Data(repeating: UInt8(generator.next() & 0xff), count: Int(generator.next() % 512))
            default: json = Data("[\"\(suffix)\"]".utf8)
            }
            let accepted: Bool
            do {
                let decoded = try JSONDecoder().decode(LabfileDocument.self, from: json)
                accepted = decoded.schemaVersion == 1
                behaviors.insert(accepted ? "decoded-supported-schema" : "decoded-unsupported-schema")
            } catch {
                accepted = false
                behaviors.insert("rejected-malformed-json")
            }
            if accepted != (jsonKind == 0) { jsonFailures += 1 }
        }
        let total = count * 2
        let failures = archiveFailures + jsonFailures
        let passPercent = Double(total - failures) / Double(total) * 100
        let coveragePassed = policy.measuredSourceCoveragePercent.map { $0 >= policy.minimumSourceCoveragePercent } == true
        let coverageEvidence = policy.measuredSourceCoveragePercent.map {
            String(format: "Measured source coverage %.1f%%; required %.1f%%.", $0, policy.minimumSourceCoveragePercent)
        } ?? "Source coverage was not imported; required \(String(format: "%.1f", policy.minimumSourceCoveragePercent))%."
        return EngineeringQualityReport(
            generatedAt: .now, seed: policy.seed, totalCases: total, failedCases: failures,
            suites: [
                FuzzCaseSummary(id: "archive-paths", cases: count, failures: archiveFailures, behaviorClasses: behaviors.filter { $0.contains("unsafe") || $0.contains("relative") }.sorted()),
                FuzzCaseSummary(id: "labfile-json", cases: count, failures: jsonFailures, behaviorClasses: behaviors.filter { $0.contains("schema") || $0.contains("json") }.sorted()),
            ],
            fuzzGatePassed: passPercent >= policy.minimumPassPercent,
            coverageGatePassed: coveragePassed, coverageEvidence: coverageEvidence
        )
    }
}

// MARK: - 10. Beta operations and feedback loop

enum BetaReleaseChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case internalTesting, alpha, beta, stable
    var id: String { rawValue }
    var title: String {
        switch self { case .internalTesting: "Internal"; case .alpha: "Alpha"; case .beta: "Beta"; case .stable: "Stable" }
    }
}

struct BetaOperationsPolicy: Codable, Hashable, Sendable {
    var channel: BetaReleaseChannel
    var rolloutPercent: Int
    var minimumHealthyLaunches: Int
    var maximumCrashRatePercent: Double
    var supportResponseHours: Int
    var feedbackURL: String?
    var allowSanitizedDiagnostics: Bool
    static let standard = BetaOperationsPolicy(
        channel: .internalTesting, rolloutPercent: 10, minimumHealthyLaunches: 10,
        maximumCrashRatePercent: 2, supportResponseHours: 48, feedbackURL: nil,
        allowSanitizedDiagnostics: false
    )
}

struct BetaOperationsGate: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let passed: Bool
    let evidence: String
}

struct BetaOperationsReport: Codable, Hashable, Sendable {
    let generatedAt: Date
    let channel: BetaReleaseChannel
    let rolloutPercent: Int
    let gates: [BetaOperationsGate]
    var canPromote: Bool { !gates.isEmpty && gates.allSatisfy(\.passed) }
    static let empty = BetaOperationsReport(generatedAt: .distantPast, channel: .internalTesting, rolloutPercent: 0, gates: [])
}

enum BetaOperationsEvaluator {
    static func evaluate(
        policy: BetaOperationsPolicy, runs: [TestRunRecord], publicBeta: PublicBetaReadinessReport,
        quality: EngineeringQualityReport, security: SecurityPostureReport
    ) -> BetaOperationsReport {
        let completed = runs.filter { $0.state == .passed || $0.state == .failed }
        let healthy = completed.filter { $0.state == .passed }.count
        let crashLike = completed.filter { run in run.results.contains { $0.message.localizedCaseInsensitiveContains("crash") } }.count
        let crashRate = completed.isEmpty ? 100 : Double(crashLike) / Double(completed.count) * 100
        let feedbackConfigured = policy.feedbackURL.flatMap(URL.init(string:))?.scheme == "https"
        let rolloutValid = (1...100).contains(policy.rolloutPercent)
        return BetaOperationsReport(generatedAt: .now, channel: policy.channel, rolloutPercent: policy.rolloutPercent, gates: [
            .init(id: "rollout", passed: rolloutValid, evidence: rolloutValid ? "Staged rollout is \(policy.rolloutPercent)%." : "Rollout must be 1–100%."),
            .init(id: "launch-health", passed: healthy >= policy.minimumHealthyLaunches, evidence: "\(healthy) passing completed run(s); required \(policy.minimumHealthyLaunches)."),
            .init(id: "crash-rate", passed: !completed.isEmpty && crashRate <= policy.maximumCrashRatePercent, evidence: String(format: "Crash-like run rate %.1f%%; maximum %.1f%%.", crashRate, policy.maximumCrashRatePercent)),
            .init(id: "quality", passed: quality.passed, evidence: quality.passed ? "Fuzz and coverage gates passed." : "Fuzz and/or coverage evidence is incomplete."),
            .init(id: "security", passed: security.passed, evidence: security.passed ? "Threat-boundary controls have no action-required findings." : "Threat-model review has action-required findings or no evidence."),
            .init(id: "public-beta", passed: policy.channel == .internalTesting || policy.channel == .alpha || publicBeta.passed, evidence: publicBeta.passed ? "Public beta checklist passed." : "Public beta checklist is incomplete."),
            .init(id: "feedback", passed: feedbackConfigured, evidence: feedbackConfigured ? "HTTPS feedback endpoint configured." : "Configure an HTTPS feedback endpoint."),
            .init(id: "support", passed: policy.supportResponseHours > 0 && policy.supportResponseHours <= 168, evidence: "Support response objective: \(policy.supportResponseHours) hour(s)."),
        ])
    }

    static func createFeedbackPackage(
        report: BetaOperationsReport, quality: EngineeringQualityReport, security: SecurityPostureReport,
        paths: LabPaths
    ) throws -> URL {
        let directory = paths.stateRoot.appendingPathComponent("Feedback Packages", isDirectory: true)
        try SecureFilesystem.prepareDirectory(directory)
        let url = directory.appendingPathComponent("feedback-\(Int(Date().timeIntervalSince1970)).json")
        let package = FeedbackPackage(
            schemaVersion: 1, generatedAt: .now, betaOperations: report, quality: quality,
            securityControls: security.threats.map { .init(id: $0.id, state: $0.state.rawValue, evidence: $0.evidence) },
            privacyStatement: "Contains readiness summaries only. Secret values, firmware, VM disks, guest content, and raw logs are excluded."
        )
        try HardeningJSON.save(package, to: url)
        return url
    }
}

struct FeedbackSecuritySummary: Codable, Hashable, Sendable { let id: String; let state: String; let evidence: String }
struct FeedbackPackage: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let betaOperations: BetaOperationsReport
    let quality: EngineeringQualityReport
    let securityControls: [FeedbackSecuritySummary]
    let privacyStatement: String
}

// MARK: - Persisted platform state

struct PlatformEngineeringState: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var adapterManifests: [BackendAdapterManifest]
    var adapterConformance: AdapterConformanceReport
    var resetPolicy: DeterministicResetPolicy
    var resetPlan: DeterministicResetPlan
    var builds: [BuildIdentityRecord]
    var replayBundles: [FailureReplayBundleRecord]
    var retryPolicy: RetryAndRegressionPolicy
    var trends: RunTrendReport
    var fleetHosts: [FleetHostRecord]
    var placement: FleetPlacementDecision
    var timelines: [UnifiedTimelineRecord]
    var security: SecurityPostureReport
    var qualityPolicy: FuzzAndCoveragePolicy
    var quality: EngineeringQualityReport
    var betaPolicy: BetaOperationsPolicy
    var betaOperations: BetaOperationsReport
    var latestFeedbackPackagePath: String?

    static let empty = PlatformEngineeringState(
        schemaVersion: 1, adapterManifests: [], adapterConformance: .empty,
        resetPolicy: .standard, resetPlan: .empty, builds: [], replayBundles: [],
        retryPolicy: .standard, trends: .empty, fleetHosts: [], placement: .empty,
        timelines: [], security: .empty, qualityPolicy: .standard, quality: .empty,
        betaPolicy: .standard, betaOperations: .empty, latestFeedbackPackagePath: nil
    )
}

enum PlatformEngineeringStore {
    static func url(paths: LabPaths) -> URL { paths.stateRoot.appendingPathComponent("platform-engineering.json") }
    static func load(paths: LabPaths) -> PlatformEngineeringState {
        let source = url(paths: paths)
        let fileSize = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize <= 16 * 1_024 * 1_024,
              var state = try? HardeningJSON.load(PlatformEngineeringState.self, from: source),
              state.schemaVersion == 1 else { return .empty }
        state.adapterManifests = Array(state.adapterManifests.prefix(100))
        state.builds = Array(state.builds.prefix(250))
        state.replayBundles = Array(state.replayBundles.prefix(100))
        state.fleetHosts = Array(state.fleetHosts.prefix(100))
        state.timelines = state.timelines.prefix(100).map { timeline in
            UnifiedTimelineRecord(
                id: timeline.id, generatedAt: timeline.generatedAt, runID: timeline.runID,
                events: Array(timeline.events.prefix(5_000)),
                unavailableSources: Array(timeline.unavailableSources.prefix(20)), path: timeline.path
            )
        }
        return state
    }
    static func save(_ state: PlatformEngineeringState, paths: LabPaths) throws {
        guard state.schemaVersion == 1 else { throw CocoaError(.coderInvalidValue) }
        try HardeningJSON.save(state, to: url(paths: paths))
    }
}
