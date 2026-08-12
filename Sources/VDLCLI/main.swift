import CryptoKit
import Foundation

private let cliVersion = "0.7.0"

struct CLIWorkflow: Codable, Sendable {
    let id: UUID
    var name: String
    var steps: [CLIStep]
    var isBuiltIn: Bool
    var schedule: String?
    var headless: Bool?
}

struct CLIStep: Codable, Sendable {
    let id: UUID
    var action: String
    var value: String?
    var delaySeconds: Double?
    var retryCount: Int?
    var continueOnFailure: Bool?
    var condition: String?
}

struct ResourcePolicy: Codable, Sendable {
    var maximumConcurrentVMs: Int
    var maximumAggregateMemoryMB: Int
    var reservedHostMemoryMB: Int
    var maximumHostCPUPercent: Double

    static let standard = ResourcePolicy(
        maximumConcurrentVMs: 2,
        maximumAggregateMemoryMB: 12_288,
        reservedHostMemoryMB: 4_096,
        maximumHostCPUPercent: 85
    )
}

struct StepResult: Codable, Sendable {
    let action: String
    let passed: Bool
    let message: String
    let durationSeconds: Double
}

struct DeviceResult: Codable, Sendable {
    let device: String
    let passed: Bool
    let startedAt: Date
    let completedAt: Date
    let steps: [StepResult]
    let artifacts: [String]
}

struct HeadlessReport: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let workflow: String
    let startedAt: Date
    let completedAt: Date
    let passed: Bool
    let dryRun: Bool
    let resourcePolicy: ResourcePolicy
    let devices: [DeviceResult]
}

struct DoctorReport: Codable {
    let schemaVersion: Int
    let checkedAt: Date
    let architecture: String
    let sipStatus: String
    let researchGuestsStatus: String
    let backendPath: String?
    let backendExitCode: Int32?
    let developerIDIdentityAvailable: Bool
    let availableStorageBytes: Int64
    let ready: Bool
    let blockers: [String]
}

struct CommandOutcome: Sendable {
    let output: String
    let exitCode: Int32
    let timedOut: Bool
    var passed: Bool { exitCode == 0 && !timedOut }
}

final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

enum Shell {
    static func run(
        _ executable: String,
        _ arguments: [String] = [],
        input: Data? = nil,
        timeout: TimeInterval = 300,
        environment: [String: String] = [:]
    ) -> CommandOutcome {
        let process = Process()
        let pipe = Pipe()
        let inputPipe = Pipe()
        let box = OutputBox()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = inputPipe
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { box.append(chunk) }
        }
        do {
            try process.run()
            if let input { inputPipe.fileHandleForWriting.write(input) }
            try? inputPipe.fileHandleForWriting.close()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return CommandOutcome(output: error.localizedDescription, exitCode: 127, timedOut: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let timedOut = process.isRunning
        if process.isRunning { process.terminate() }
        if process.isRunning {
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        box.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return CommandOutcome(
            output: box.string(),
            exitCode: timedOut ? 124 : process.terminationStatus,
            timedOut: timedOut
        )
    }

    static func launch(_ executable: String, _ arguments: [String], logURL: URL) throws -> Process {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process
    }
}

enum HostDoctor {
    static func inspect() -> DoctorReport {
        let architecture = Shell.run("/usr/bin/uname", ["-m"], timeout: 10).output.trimmed
        let sip = Shell.run("/usr/bin/csrutil", ["status"], timeout: 10).output.trimmed
        let research = Shell.run(
            "/usr/bin/csrutil",
            ["allow-research-guests", "status"],
            input: Data(),
            timeout: 10
        ).output.trimmed
        let backend = resolveVPhone()
        let backendCheck = backend.map { Shell.run($0, ["--help"], timeout: 20) }
        let identities = Shell.run(
            "/usr/bin/security",
            ["find-identity", "-v", "-p", "codesigning"],
            timeout: 20
        ).output
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vphone")
        let available = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        var blockers: [String] = []
        if architecture != "arm64" { blockers.append("Apple silicon is required") }
        if !research.localizedCaseInsensitiveContains("enabled") {
            blockers.append("Allow Research Guests is not enabled from Recovery")
        }
        if backend == nil { blockers.append("vphone-cli is not installed") }
        else if backendCheck?.passed != true { blockers.append("vphone-cli preflight did not complete successfully") }
        let hasDeveloperID = identities.contains("Developer ID Application")
        if !hasDeveloperID { blockers.append("Developer ID Application identity is unavailable for production releases") }
        return DoctorReport(
            schemaVersion: 1,
            checkedAt: .now,
            architecture: architecture,
            sipStatus: sip,
            researchGuestsStatus: research,
            backendPath: backend,
            backendExitCode: backendCheck?.exitCode,
            developerIDIdentityAvailable: hasDeveloperID,
            availableStorageBytes: available,
            ready: blockers.filter { !$0.contains("production releases") }.isEmpty,
            blockers: blockers
        )
    }
}

struct RunOptions: Sendable {
    var workflowReference: String
    var devices: [String]
    var appPath: String?
    var outputDirectory: URL
    var dryRun: Bool
    var policy: ResourcePolicy
}

enum WorkflowLoader {
    static func load(_ reference: String) throws -> CLIWorkflow {
        if FileManager.default.fileExists(atPath: reference) {
            let data = try Data(contentsOf: URL(fileURLWithPath: reference))
            if let single = try? JSONDecoder.lab.decode(CLIWorkflow.self, from: data) { return single }
            if let list = try? JSONDecoder.lab.decode([CLIWorkflow].self, from: data), let first = list.first { return first }
        }
        if let builtIn = builtIn(reference) { return builtIn }
        let catalog = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vphone/VirtualDeviceLab/automation-workflows.json")
        let records = (try? JSONDecoder.lab.decode([CLIWorkflow].self, from: Data(contentsOf: catalog))) ?? []
        if let workflow = records.first(where: {
            $0.id.uuidString.caseInsensitiveCompare(reference) == .orderedSame
                || $0.name.caseInsensitiveCompare(reference) == .orderedSame
        }) { return workflow }
        throw CLIError.message("Workflow not found: \(reference)")
    }

    static func builtIn(_ name: String) -> CLIWorkflow? {
        let steps: [CLIStep]
        switch name.lowercased() {
        case "boot-smoke", "boot smoke test":
            steps = [step("boot"), step("waitForGuest", value: "120"), step("screenshot"), step("stop"), step("diagnostics")]
        case "deployment":
            steps = [step("installApp"), step("waitForGuest", value: "180"), step("screenshot"), step("stop"), step("diagnostics")]
        default:
            return nil
        }
        return CLIWorkflow(id: UUID(), name: name, steps: steps, isBuiltIn: true, schedule: nil, headless: true)
    }

    private static func step(_ action: String, value: String? = nil) -> CLIStep {
        CLIStep(
            id: UUID(), action: action, value: value, delaySeconds: 0,
            retryCount: 0, continueOnFailure: false, condition: nil
        )
    }
}

enum ResourcePlanner {
    static func batches(devices: [String], policy: ResourcePolicy) -> [[String]] {
        let concurrentLimit = max(1, policy.maximumConcurrentVMs)
        let physicalMB = Int(ProcessInfo.processInfo.physicalMemory / 1_048_576)
        let availableBudget = max(1_024, physicalMB - max(0, policy.reservedHostMemoryMB))
        let memoryLimit = min(max(1_024, policy.maximumAggregateMemoryMB), availableBudget)
        var batches: [[String]] = []
        var current: [String] = []
        var currentMemory = 0
        for device in devices {
            let memory = max(1_024, deviceMemoryMB(device))
            if !current.isEmpty && (current.count >= concurrentLimit || currentMemory + memory > memoryLimit) {
                batches.append(current)
                current = []
                currentMemory = 0
            }
            current.append(device)
            currentMemory += memory
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    static func waitForHostCPU(below limit: Double, timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if hostCPUPercent() <= limit { return true }
            Thread.sleep(forTimeInterval: 2)
        } while Date() < deadline
        return false
    }

    private static func hostCPUPercent() -> Double {
        let output = Shell.run("/bin/ps", ["-A", "-o", "%cpu="], timeout: 10).output
        let total = output.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }.reduce(0, +)
        return total / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    private static func deviceMemoryMB(_ name: String) -> Int {
        let config = vmRoot(name).appendingPathComponent("config.plist")
        guard let data = try? Data(contentsOf: config),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let memory = plist["memorySize"] as? NSNumber
        else { return 4_096 }
        return Int(memory.int64Value / 1_048_576)
    }
}

enum HeadlessRunner {
    static func run(options: RunOptions) async throws -> HeadlessReport {
        let workflow = try WorkflowLoader.load(options.workflowReference)
        let started = Date()
        var deviceResults: [DeviceResult] = []
        for batch in ResourcePlanner.batches(devices: options.devices, policy: options.policy) {
            guard options.dryRun || ResourcePlanner.waitForHostCPU(below: options.policy.maximumHostCPUPercent) else {
                throw CLIError.message("Host CPU stayed above the configured threshold")
            }
            let results = await withTaskGroup(of: DeviceResult.self, returning: [DeviceResult].self) { group in
                for device in batch {
                    group.addTask {
                        await runDevice(device, workflow: workflow, options: options)
                    }
                }
                var collected: [DeviceResult] = []
                for await result in group { collected.append(result) }
                return collected
            }
            deviceResults += results
        }
        deviceResults.sort { $0.device.localizedStandardCompare($1.device) == .orderedAscending }
        let report = HeadlessReport(
            schemaVersion: 1,
            id: UUID(),
            workflow: workflow.name,
            startedAt: started,
            completedAt: .now,
            passed: deviceResults.allSatisfy(\.passed),
            dryRun: options.dryRun,
            resourcePolicy: options.policy,
            devices: deviceResults
        )
        try ReportWriter.write(report, to: options.outputDirectory)
        return report
    }

    private static func runDevice(
        _ device: String,
        workflow: CLIWorkflow,
        options: RunOptions
    ) async -> DeviceResult {
        let started = Date()
        var results: [StepResult] = []
        var artifacts: [String] = []
        var shouldContinue = true
        for step in workflow.steps where shouldContinue {
            if !conditionAllows(step.condition, device: device) { continue }
            if let delay = step.delaySeconds, delay > 0, !options.dryRun {
                try? await Task.sleep(for: .seconds(delay))
            }
            let attempts = max(1, (step.retryCount ?? 0) + 1)
            var final = StepResult(action: step.action, passed: false, message: "Not run", durationSeconds: 0)
            for _ in 0..<attempts {
                final = execute(step, device: device, options: options, artifacts: &artifacts)
                if final.passed { break }
                if !options.dryRun { try? await Task.sleep(for: .seconds(1)) }
            }
            results.append(final)
            if !final.passed && step.continueOnFailure != true { shouldContinue = false }
        }
        return DeviceResult(
            device: device,
            passed: results.allSatisfy(\.passed),
            startedAt: started,
            completedAt: .now,
            steps: results,
            artifacts: artifacts
        )
    }

    private static func execute(
        _ step: CLIStep,
        device: String,
        options: RunOptions,
        artifacts: inout [String]
    ) -> StepResult {
        let started = Date()
        if options.dryRun {
            return StepResult(
                action: step.action,
                passed: supportedActions.contains(step.action),
                message: supportedActions.contains(step.action) ? "Validated without execution" : "Unsupported action",
                durationSeconds: Date().timeIntervalSince(started)
            )
        }
        let backend = resolveVPhone() ?? "vphone-cli"
        let bundle = vmRoot(device)
        let outcome: CommandOutcome
        switch step.action {
        case "boot":
            return launchBackend(
                action: step.action,
                executable: backend,
                arguments: ["vm", "launch", device, "--library-root", libraryRoot.path],
                device: device,
                options: options,
                artifacts: &artifacts,
                started: started
            )
        case "installApp":
            guard let app = step.value ?? options.appPath else {
                return result(step.action, false, "An app path is required", started)
            }
            return launchBackend(
                action: step.action,
                executable: backend,
                arguments: ["boot", "--config", bundle.appendingPathComponent("config.plist").path, "--install-ipa", app],
                device: device,
                options: options,
                artifacts: &artifacts,
                started: started
            )
        case "waitForGuest":
            let seconds = TimeInterval(step.value ?? "120") ?? 120
            let deadline = Date().addingTimeInterval(seconds)
            var connected = false
            repeat {
                connected = guestRequest(device, ["t": "key", "name": "home", "screen": false]).passed
                if !connected { Thread.sleep(forTimeInterval: 2) }
            } while !connected && Date() < deadline
            return result(step.action, connected, connected ? "Guest control connected" : "Guest control timed out", started)
        case "delay":
            Thread.sleep(forTimeInterval: TimeInterval(step.value ?? "1") ?? 1)
            return result(step.action, true, "Delay completed", started)
        case "screenshot":
            let url = options.outputDirectory.appendingPathComponent("\(safe(device))-screen.png")
            outcome = guestRequest(device, ["t": "screenshot", "path": url.path, "screen": false])
            if outcome.passed { artifacts.append(url.path) }
        case "pressHome", "assertGuestReady":
            outcome = guestRequest(device, ["t": "key", "name": "home", "screen": false])
        case "setNetworkMode":
            outcome = Shell.run(
                backend,
                ["vm", "config", device, "--network", step.value ?? "nat", "--library-root", libraryRoot.path]
            )
        case "samplePerformance":
            outcome = Shell.run("/usr/sbin/lsof", ["-t", "--", bundle.appendingPathComponent("Disk.img").path], timeout: 10)
        case "stop":
            outcome = Shell.run(backend, ["vm", "stop", device, "--library-root", libraryRoot.path], timeout: 180)
        case "snapshot":
            let url = options.outputDirectory.appendingPathComponent("\(safe(device))-\(safe(step.value ?? "snapshot")).tgz")
            outcome = Shell.run(
                backend,
                ["vm", "export", device, "--out", url.path, "--library-root", libraryRoot.path],
                timeout: 3_600
            )
            if outcome.passed { artifacts.append(url.path) }
        case "diagnostics":
            let destination = options.outputDirectory.appendingPathComponent("\(safe(device))-diagnostics")
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                for file in ["config.plist", "restore-info.json", "lab-metadata.json"] {
                    let source = bundle.appendingPathComponent(file)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try? FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(file))
                    }
                }
                artifacts.append(destination.path)
                return result(step.action, true, "Diagnostic evidence collected", started)
            } catch {
                return result(step.action, false, error.localizedDescription, started)
            }
        default:
            return result(step.action, false, "Unsupported action: \(step.action)", started)
        }
        return result(step.action, outcome.passed, outcome.output.trimmed.nilIfEmpty ?? "exit \(outcome.exitCode)", started)
    }

    private static let supportedActions: Set<String> = [
        "boot", "installApp", "waitForGuest", "delay", "screenshot", "pressHome",
        "setNetworkMode", "samplePerformance", "assertGuestReady", "stop", "snapshot", "diagnostics",
    ]

    private static func conditionAllows(_ condition: String?, device: String) -> Bool {
        guard let condition = condition?.lowercased(), !condition.isEmpty, condition != "always" else { return true }
        let running = FileManager.default.fileExists(atPath: vmRoot(device).appendingPathComponent("vphone.sock").path)
        if condition == "running" { return running }
        if condition == "stopped" { return !running }
        return false
    }

    private static func guestRequest(_ device: String, _ payload: [String: Any]) -> CommandOutcome {
        guard let input = try? JSONSerialization.data(withJSONObject: payload) else {
            return CommandOutcome(output: "Could not encode guest request", exitCode: 65, timedOut: false)
        }
        var line = input
        line.append(0x0A)
        let outcome = Shell.run(
            "/usr/bin/nc",
            ["-U", vmRoot(device).appendingPathComponent("vphone.sock").path],
            input: line,
            timeout: 20
        )
        guard outcome.passed else { return outcome }
        let responseLine = outcome.output.components(separatedBy: .newlines)
            .last { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        guard let responseLine,
              let data = responseLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true else {
            return CommandOutcome(output: outcome.output.nilIfEmpty ?? "Guest control rejected the request", exitCode: 1, timedOut: false)
        }
        return outcome
    }

    private static func launchBackend(
        action: String,
        executable: String,
        arguments: [String],
        device: String,
        options: RunOptions,
        artifacts: inout [String],
        started: Date
    ) -> StepResult {
        let log = options.outputDirectory.appendingPathComponent("\(safe(device))-backend.log")
        do {
            let process = try Shell.launch(executable, arguments, logURL: log)
            Thread.sleep(forTimeInterval: 1)
            artifacts.append(log.path)
            if process.isRunning {
                return result(action, true, "Backend launched (pid \(process.processIdentifier))", started)
            }
            process.waitUntilExit()
            return result(action, false, "Backend exited early with \(process.terminationStatus)", started)
        } catch {
            return result(action, false, error.localizedDescription, started)
        }
    }

    private static func result(_ action: String, _ passed: Bool, _ message: String, _ started: Date) -> StepResult {
        StepResult(action: action, passed: passed, message: message, durationSeconds: Date().timeIntervalSince(started))
    }
}

enum ReportWriter {
    static func write(_ report: HeadlessReport, to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder.lab.encode(report).write(to: root.appendingPathComponent("result.json"), options: .atomic)
        var junit = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        let tests = report.devices.reduce(0) { $0 + $1.steps.count }
        let failures = report.devices.flatMap(\.steps).filter { !$0.passed }.count
        junit += "<testsuite name=\"\(xml(report.workflow))\" tests=\"\(tests)\" failures=\"\(failures)\">\n"
        for device in report.devices {
            for step in device.steps {
                junit += "  <testcase classname=\"\(xml(device.device))\" name=\"\(xml(step.action))\" time=\"\(step.durationSeconds)\">"
                if !step.passed { junit += "<failure message=\"\(xml(step.message))\"/>" }
                junit += "</testcase>\n"
            }
        }
        junit += "</testsuite>\n"
        try junit.write(to: root.appendingPathComponent("junit.xml"), atomically: true, encoding: .utf8)

        var rows = ""
        for device in report.devices {
            for step in device.steps {
                rows += "<tr><td>\(html(device.device))</td><td>\(html(step.action))</td><td>\(step.passed ? "PASS" : "FAIL")</td><td>\(html(step.message))</td></tr>"
            }
        }
        let page = """
        <!doctype html><meta charset="utf-8"><title>\(html(report.workflow))</title>
        <style>body{font:15px -apple-system;margin:2rem;max-width:1100px}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:.5rem;text-align:left}</style>
        <h1>\(html(report.workflow))</h1><p>Result: <strong>\(report.passed ? "PASS" : "FAIL")</strong></p>
        <table><thead><tr><th>Device</th><th>Step</th><th>Result</th><th>Evidence</th></tr></thead><tbody>\(rows)</tbody></table>
        """
        try page.write(to: root.appendingPathComponent("report.html"), atomically: true, encoding: .utf8)
    }

    private static func xml(_ value: String) -> String { html(value).replacingOccurrences(of: "'", with: "&apos;") }
    private static func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

enum ScheduleInstaller {
    static func install(workflow: String, device: String, intervalSeconds: Int, appPath: String?) throws -> URL {
        guard intervalSeconds >= 60 else { throw CLIError.message("Schedule interval must be at least 60 seconds") }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let label = "com.virtualdevicelab.workflow.\(safe(workflow)).\(safe(device))"
        let output = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vphone/VirtualDeviceLab/Scheduled Runs/\(safe(workflow))-\(safe(device))")
        var arguments = [executable, "run", "--workflow", workflow, "--device", device, "--output", output.path]
        if let appPath { arguments += ["--app", appPath] }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": arguments,
            "StartInterval": intervalSeconds,
            "RunAtLoad": false,
            "StandardOutPath": output.appendingPathComponent("schedule.log").path,
            "StandardErrorPath": output.appendingPathComponent("schedule.log").path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = launchAgents.appendingPathComponent("\(label).plist")
        try data.write(to: url, options: .atomic)
        let domain = "gui/\(getuid())"
        _ = Shell.run("/bin/launchctl", ["bootout", domain, url.path], timeout: 20)
        let result = Shell.run("/bin/launchctl", ["bootstrap", domain, url.path], timeout: 20)
        guard result.passed else { throw CLIError.message(result.output.trimmed) }
        return url
    }
}

// MARK: - Authenticated file-queue agent

struct AgentJobPayload: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let keyID: String
    let nonce: UUID
    let createdAt: Date
    let expiresAt: Date
    let workflow: String
    let devices: [String]
    let appPath: String?
    let outputDirectory: String
    let dryRun: Bool
    let resourcePolicy: ResourcePolicy
}

struct SignedAgentJob: Codable, Sendable {
    let payload: AgentJobPayload
    let signature: String
}

enum AgentJobState: String, Codable, Sendable {
    case queued
    case running
    case passed
    case failed
    case cancelled
    case rejected
    case missing
}

struct AgentJobReceipt: Codable, Sendable {
    let schemaVersion: Int
    let jobID: UUID
    let state: AgentJobState
    let updatedAt: Date
    let reportPath: String?
    let message: String
}

struct AgentKeyring: Codable, Sendable {
    let schemaVersion: Int
    var activeKeyID: String
    var keys: [String: String]
    var keyCreatedAt: [String: Date]?
    var revokedKeyIDs: [String]
    var rotatedAt: Date
}

struct AgentHealthReport: Codable, Sendable {
    let schemaVersion: Int
    let checkedAt: Date
    let queuePath: String
    let activeKeyID: String?
    let queued: Int
    let running: Int
    let results: Int
    let rejected: Int
    let cancelled: Int
    let replayLedgerEntries: Int
    let healthy: Bool
    let issues: [String]
}

enum AgentQueue {
    static func initialize(queue: URL, tokenFile: URL) throws {
        try prepare(queue)
        guard !FileManager.default.fileExists(atPath: tokenFile.path) else {
            throw CLIError.message("Token file already exists; refusing to overwrite it")
        }
        try FileManager.default.createDirectory(at: tokenFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let keyID = UUID().uuidString
        let token = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let keyring = AgentKeyring(
            schemaVersion: 2, activeKeyID: keyID, keys: [keyID: token], keyCreatedAt: [keyID: .now],
            revokedKeyIDs: [], rotatedAt: .now
        )
        try JSONEncoder.lab.encode(keyring).write(
            to: tokenFile, options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
    }

    static func submit(
        queue: URL,
        tokenFile: URL,
        workflow: String,
        devices: [String],
        appPath: String?,
        dryRun: Bool,
        policy: ResourcePolicy,
        validitySeconds: TimeInterval = 3_600
    ) throws -> AgentJobPayload {
        try prepare(queue)
        let jobID = UUID()
        let output = directory(queue, "Results")
            .appendingPathComponent(jobID.uuidString, isDirectory: true)
            .appendingPathComponent("Artifacts", isDirectory: true)
        let keyring = try loadKeyring(tokenFile: tokenFile)
        let payload = AgentJobPayload(
            schemaVersion: 2,
            id: jobID,
            keyID: keyring.activeKeyID,
            nonce: UUID(),
            createdAt: .now,
            expiresAt: Date().addingTimeInterval(max(60, validitySeconds)),
            workflow: workflow,
            devices: devices,
            appPath: appPath,
            outputDirectory: output.path,
            dryRun: dryRun,
            resourcePolicy: policy
        )
        let envelope = SignedAgentJob(payload: payload, signature: try signature(for: payload, tokenFile: tokenFile))
        try JSONEncoder.lab.encode(envelope).write(
            to: directory(queue, "Inbox").appendingPathComponent("\(jobID.uuidString).json"),
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        return payload
    }

    static func runOnce(queue: URL, tokenFile: URL) async throws -> AgentJobReceipt? {
        try prepare(queue)
        let inbox = directory(queue, "Inbox")
        let candidates = try FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let source = candidates.first else { return nil }
        let running = directory(queue, "Running").appendingPathComponent(source.lastPathComponent)
        try FileManager.default.moveItem(at: source, to: running)

        let envelope: SignedAgentJob
        do {
            envelope = try JSONDecoder.lab.decode(SignedAgentJob.self, from: Data(contentsOf: running))
            guard try verify(envelope, tokenFile: tokenFile) else {
                return try reject(envelope.payload.id, message: "HMAC signature is invalid", running: running, queue: queue)
            }
            guard envelope.payload.schemaVersion == 2 else {
                return try reject(envelope.payload.id, message: "Unsupported job schema", running: running, queue: queue)
            }
            guard envelope.payload.expiresAt > .now else {
                return try reject(envelope.payload.id, message: "Job expired before execution", running: running, queue: queue)
            }
            guard !envelope.payload.devices.isEmpty else {
                return try reject(envelope.payload.id, message: "Job has no target devices", running: running, queue: queue)
            }
            guard !isCancelled(envelope.payload.id, queue: queue) else {
                return try reject(
                    envelope.payload.id, message: "Job was cancelled before execution",
                    running: running, queue: queue, state: .cancelled
                )
            }
            guard try recordNonce(envelope.payload.nonce, jobID: envelope.payload.id, queue: queue) else {
                return try reject(envelope.payload.id, message: "Job nonce was already used; possible replay", running: running, queue: queue)
            }
        } catch {
            let fallbackID = UUID(uuidString: running.deletingPathExtension().lastPathComponent) ?? UUID()
            return try reject(fallbackID, message: "Job envelope could not be decoded: \(error.localizedDescription)", running: running, queue: queue)
        }

        let payload = envelope.payload
        let options = RunOptions(
            workflowReference: payload.workflow,
            devices: payload.devices,
            appPath: payload.appPath,
            outputDirectory: URL(fileURLWithPath: payload.outputDirectory),
            dryRun: payload.dryRun,
            policy: payload.resourcePolicy
        )
        let receipt: AgentJobReceipt
        do {
            let report = try await HeadlessRunner.run(options: options)
            receipt = AgentJobReceipt(
                schemaVersion: 2,
                jobID: payload.id,
                state: report.passed ? .passed : .failed,
                updatedAt: .now,
                reportPath: payload.outputDirectory,
                message: report.passed ? "Headless workflow passed" : "Headless workflow completed with failures"
            )
        } catch {
            receipt = AgentJobReceipt(
                schemaVersion: 2,
                jobID: payload.id,
                state: .failed,
                updatedAt: .now,
                reportPath: payload.outputDirectory,
                message: error.localizedDescription
            )
        }
        try write(receipt, queue: queue)
        try? FileManager.default.removeItem(at: running)
        return receipt
    }

    static func status(queue: URL, jobID: UUID) -> AgentJobReceipt {
        let receiptURL = directory(queue, "Results").appendingPathComponent("\(jobID.uuidString).json")
        if let receipt = try? JSONDecoder.lab.decode(AgentJobReceipt.self, from: Data(contentsOf: receiptURL)) {
            return receipt
        }
        let cancellationURL = directory(queue, "Cancelled").appendingPathComponent("\(jobID.uuidString).json")
        if let receipt = try? JSONDecoder.lab.decode(AgentJobReceipt.self, from: Data(contentsOf: cancellationURL)) {
            return receipt
        }
        if FileManager.default.fileExists(atPath: directory(queue, "Rejected").appendingPathComponent("\(jobID.uuidString).json").path) {
            return AgentJobReceipt(schemaVersion: 2, jobID: jobID, state: .rejected, updatedAt: .now, reportPath: nil, message: "Job was rejected")
        }
        if FileManager.default.fileExists(atPath: directory(queue, "Running").appendingPathComponent("\(jobID.uuidString).json").path) {
            return AgentJobReceipt(schemaVersion: 2, jobID: jobID, state: .running, updatedAt: .now, reportPath: nil, message: "Job is running")
        }
        if FileManager.default.fileExists(atPath: directory(queue, "Inbox").appendingPathComponent("\(jobID.uuidString).json").path) {
            return AgentJobReceipt(schemaVersion: 2, jobID: jobID, state: .queued, updatedAt: .now, reportPath: nil, message: "Job is queued")
        }
        return AgentJobReceipt(schemaVersion: 2, jobID: jobID, state: .missing, updatedAt: .now, reportPath: nil, message: "Job was not found")
    }

    static func rotateKey(tokenFile: URL, revokePrevious: Bool) throws -> String {
        var keyring = try loadKeyring(tokenFile: tokenFile)
        let previous = keyring.activeKeyID
        let keyID = UUID().uuidString
        keyring.keys[keyID] = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        var created = keyring.keyCreatedAt ?? Dictionary(
            uniqueKeysWithValues: keyring.keys.keys.map { ($0, Date.distantPast) }
        )
        created[keyID] = .now
        keyring.activeKeyID = keyID
        keyring.rotatedAt = .now
        if revokePrevious {
            keyring.revokedKeyIDs.append(previous)
            keyring.keys.removeValue(forKey: previous)
            created.removeValue(forKey: previous)
        }
        while keyring.keys.count > 3, let oldest = keyring.keys.keys.filter({ $0 != keyID }).min(by: {
            created[$0, default: .distantPast] < created[$1, default: .distantPast]
        }) {
            keyring.keys.removeValue(forKey: oldest)
            created.removeValue(forKey: oldest)
            keyring.revokedKeyIDs.append(oldest)
        }
        keyring.keyCreatedAt = created
        try JSONEncoder.lab.encode(keyring).write(
            to: tokenFile, options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        return keyID
    }

    static func cancel(queue: URL, jobID: UUID) throws -> AgentJobReceipt {
        try prepare(queue)
        let marker = directory(queue, "Cancelled").appendingPathComponent("\(jobID.uuidString).json")
        let receipt = AgentJobReceipt(
            schemaVersion: 2, jobID: jobID, state: .cancelled, updatedAt: .now,
            reportPath: nil, message: "Cancellation requested"
        )
        try JSONEncoder.lab.encode(receipt).write(to: marker, options: .atomic)
        let inbox = directory(queue, "Inbox").appendingPathComponent("\(jobID.uuidString).json")
        if FileManager.default.fileExists(atPath: inbox.path) {
            try? FileManager.default.removeItem(at: inbox)
        }
        return receipt
    }

    static func cleanup(queue: URL, olderThanDays: Int) throws -> Int {
        try prepare(queue)
        let cutoff = Date().addingTimeInterval(-Double(max(1, olderThanDays)) * 86_400)
        var removed = 0
        for name in ["Results", "Rejected", "Cancelled"] {
            let root = directory(queue, name)
            let items = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            )
            for item in items {
                let date = try item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantFuture
                if date < cutoff {
                    try FileManager.default.removeItem(at: item)
                    removed += 1
                }
            }
        }
        return removed
    }

    static func health(queue: URL, tokenFile: URL) -> AgentHealthReport {
        var issues: [String] = []
        let keyring = try? loadKeyring(tokenFile: tokenFile)
        if keyring == nil { issues.append("Keyring is missing or invalid.") }
        if let keyring,
           keyring.revokedKeyIDs.contains(keyring.activeKeyID) || keyring.keys[keyring.activeKeyID] == nil {
            issues.append("The active key ID is missing or revoked.")
        }
        if let permissions = (try? FileManager.default.attributesOfItem(atPath: tokenFile.path)[.posixPermissions] as? NSNumber)?.intValue,
           permissions & 0o077 != 0 {
            issues.append("Keyring permissions are broader than 0600.")
        }
        func count(_ name: String) -> Int {
            (try? FileManager.default.contentsOfDirectory(atPath: directory(queue, name).path)
                .filter { URL(fileURLWithPath: $0).pathExtension.lowercased() == "json" }.count) ?? 0
        }
        let replay = (try? loadReplayLedger(queue: queue).count) ?? 0
        return AgentHealthReport(
            schemaVersion: 2, checkedAt: .now, queuePath: queue.path,
            activeKeyID: keyring?.activeKeyID, queued: count("Inbox"), running: count("Running"),
            results: count("Results"), rejected: count("Rejected"), cancelled: count("Cancelled"),
            replayLedgerEntries: replay, healthy: issues.isEmpty, issues: issues
        )
    }

    private static func prepare(_ queue: URL) throws {
        for name in ["Inbox", "Running", "Results", "Rejected", "Cancelled"] {
            try FileManager.default.createDirectory(at: directory(queue, name), withIntermediateDirectories: true)
        }
    }

    private static func directory(_ queue: URL, _ name: String) -> URL {
        queue.appendingPathComponent(name, isDirectory: true)
    }

    private static func loadKeyring(tokenFile: URL) throws -> AgentKeyring {
        let data = try Data(contentsOf: tokenFile)
        if let keyring = try? JSONDecoder.lab.decode(AgentKeyring.self, from: data), keyring.schemaVersion == 2 {
            return keyring
        }
        let legacy = String(decoding: data, as: UTF8.self).trimmed
        guard let legacyData = Data(base64Encoded: legacy), legacyData.count >= 32 else {
            throw CLIError.message("Agent token is missing, malformed, or too short")
        }
        return AgentKeyring(
            schemaVersion: 2, activeKeyID: "legacy", keys: ["legacy": legacyData.base64EncodedString()],
            keyCreatedAt: ["legacy": .distantPast],
            revokedKeyIDs: [], rotatedAt: .distantPast
        )
    }

    private static func key(tokenFile: URL, keyID: String) throws -> SymmetricKey {
        let keyring = try loadKeyring(tokenFile: tokenFile)
        guard !keyring.revokedKeyIDs.contains(keyID),
              let encoded = keyring.keys[keyID], let data = Data(base64Encoded: encoded), data.count >= 32 else {
            throw CLIError.message("Agent key ID is unknown, revoked, or malformed")
        }
        return SymmetricKey(data: data)
    }

    private static func signature(for payload: AgentJobPayload, tokenFile: URL) throws -> String {
        let authentication = HMAC<SHA256>.authenticationCode(
            for: try JSONEncoder.lab.encode(payload),
            using: try key(tokenFile: tokenFile, keyID: payload.keyID)
        )
        return Data(authentication).base64EncodedString()
    }

    private static func verify(_ envelope: SignedAgentJob, tokenFile: URL) throws -> Bool {
        guard let signature = Data(base64Encoded: envelope.signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            signature,
            authenticating: try JSONEncoder.lab.encode(envelope.payload),
            using: try key(tokenFile: tokenFile, keyID: envelope.payload.keyID)
        )
    }

    private static func isCancelled(_ jobID: UUID, queue: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory(queue, "Cancelled").appendingPathComponent("\(jobID.uuidString).json").path
        )
    }

    private static func replayLedgerURL(queue: URL) -> URL {
        queue.appendingPathComponent("replay-ledger.json")
    }

    private static func loadReplayLedger(queue: URL) throws -> [String: String] {
        let url = replayLedgerURL(queue: queue)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder.lab.decode([String: String].self, from: Data(contentsOf: url))
    }

    private static func recordNonce(_ nonce: UUID, jobID: UUID, queue: URL) throws -> Bool {
        var ledger = try loadReplayLedger(queue: queue)
        let key = nonce.uuidString
        guard ledger[key] == nil else { return false }
        ledger[key] = jobID.uuidString
        if ledger.count > 10_000 {
            ledger = Dictionary(uniqueKeysWithValues: ledger.sorted { $0.key > $1.key }.prefix(10_000).map { ($0.key, $0.value) })
        }
        try JSONEncoder.lab.encode(ledger).write(to: replayLedgerURL(queue: queue), options: .atomic)
        return true
    }

    private static func reject(
        _ jobID: UUID,
        message: String,
        running: URL,
        queue: URL,
        state: AgentJobState = .rejected
    ) throws -> AgentJobReceipt {
        let receipt = AgentJobReceipt(
            schemaVersion: 2, jobID: jobID, state: state,
            updatedAt: .now, reportPath: nil, message: message
        )
        try JSONEncoder.lab.encode(receipt).write(
            to: directory(queue, state == .cancelled ? "Cancelled" : "Rejected")
                .appendingPathComponent("\(jobID.uuidString).json"),
            options: .atomic
        )
        try? FileManager.default.removeItem(at: running)
        return receipt
    }

    private static func write(_ receipt: AgentJobReceipt, queue: URL) throws {
        try JSONEncoder.lab.encode(receipt).write(
            to: directory(queue, "Results").appendingPathComponent("\(receipt.jobID.uuidString).json"),
            options: .atomic
        )
    }
}

enum CLIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(message) = self { return message }
        return "Unknown error"
    }
}

private let libraryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vphone/VMs")
private let defaultAgentRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".vphone/VirtualDeviceLab/Remote Agent", isDirectory: true)
private let defaultAgentQueue = defaultAgentRoot.appendingPathComponent("Queue", isDirectory: true)
private let defaultAgentToken = defaultAgentRoot.appendingPathComponent("agent-token")
private func vmRoot(_ name: String) -> URL { libraryRoot.appendingPathComponent(name) }
private func resolveVPhone() -> String? {
    let environment = ProcessInfo.processInfo.environment["VPHONE_CLI_BIN"]
    return [environment, "/opt/homebrew/bin/vphone-cli", "/Applications/vphone-cli.app/Contents/MacOS/vphone-cli"]
        .compactMap { $0 }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}
private func safe(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    let mapped = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
    return String(mapped)
}

extension JSONDecoder {
    static var lab: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var lab: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

func value(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func values(after option: String, in arguments: [String]) -> [String] {
    arguments.indices.compactMap { index in
        arguments[index] == option && arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
    }
}

func usage() {
    print("""
    vdlctl \(cliVersion) — iOS Virtual Device Lab automation

    Usage:
      vdlctl doctor [--json] [--output <directory>]
      vdlctl run --workflow <file|id|name> --device <name> [--device <name> ...]
                 [--app <ipa>] [--output <directory>] [--max-concurrency <n>]
                 [--memory-budget-mb <n>] [--reserve-memory-mb <n>] [--max-cpu <percent>] [--dry-run]
      vdlctl deploy --device <name> --app <ipa> [--output <directory>]
      vdlctl schedule-install --workflow <file|id|name> --device <name> --interval-seconds <n> [--app <ipa>]
      vdlctl agent-init [--queue <directory>] [--token-file <path>]
      vdlctl agent-submit --workflow <file|id|name> --device <name> [--device <name> ...]
                          [--app <ipa>] [--queue <directory>] [--token-file <path>] [--dry-run]
      vdlctl agent-run-once [--queue <directory>] [--token-file <path>]
      vdlctl agent-status --job <uuid> [--queue <directory>] [--json]
      vdlctl agent-cancel --job <uuid> [--queue <directory>]
      vdlctl agent-key-rotate [--token-file <path>] [--revoke-previous]
      vdlctl agent-cleanup [--queue <directory>] [--older-than-days <n>]
      vdlctl agent-health [--queue <directory>] [--token-file <path>] [--json]
      vdlctl version
    """)
}

@main
enum VDLCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { usage(); exit(64) }
        do {
            switch command {
            case "version", "--version":
                print(cliVersion)
            case "doctor":
                let report = HostDoctor.inspect()
                let data = try JSONEncoder.lab.encode(report)
                if let output = value(after: "--output", in: arguments) {
                    let root = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    try data.write(to: root.appendingPathComponent("host-readiness.json"), options: .atomic)
                }
                if arguments.contains("--json") { print(String(decoding: data, as: UTF8.self)) }
                else {
                    print(report.ready ? "Host readiness: READY" : "Host readiness: ACTION REQUIRED")
                    for blocker in report.blockers { print("- \(blocker)") }
                }
                exit(report.ready ? 0 : 2)
            case "run", "deploy":
                let workflow = command == "deploy" ? "deployment" : value(after: "--workflow", in: arguments)
                let devices = values(after: "--device", in: arguments)
                guard let workflow, !devices.isEmpty else { throw CLIError.message("--workflow and at least one --device are required") }
                var policy = ResourcePolicy.standard
                if let value = value(after: "--max-concurrency", in: arguments).flatMap(Int.init) { policy.maximumConcurrentVMs = value }
                if let value = value(after: "--memory-budget-mb", in: arguments).flatMap(Int.init) { policy.maximumAggregateMemoryMB = value }
                if let value = value(after: "--reserve-memory-mb", in: arguments).flatMap(Int.init) { policy.reservedHostMemoryMB = value }
                if let value = value(after: "--max-cpu", in: arguments).flatMap(Double.init) { policy.maximumHostCPUPercent = value }
                let output = value(after: "--output", in: arguments).map(URL.init(fileURLWithPath:))
                    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent("vdl-results-\(UUID().uuidString)")
                let options = RunOptions(
                    workflowReference: workflow,
                    devices: devices,
                    appPath: value(after: "--app", in: arguments),
                    outputDirectory: output,
                    dryRun: arguments.contains("--dry-run"),
                    policy: policy
                )
                let report = try await HeadlessRunner.run(options: options)
                print("\(report.passed ? "PASS" : "FAIL") — reports: \(output.path)")
                exit(report.passed ? 0 : 1)
            case "schedule-install":
                guard let workflow = value(after: "--workflow", in: arguments),
                      let device = value(after: "--device", in: arguments),
                      let interval = value(after: "--interval-seconds", in: arguments).flatMap(Int.init)
                else { throw CLIError.message("--workflow, --device, and --interval-seconds are required") }
                let url = try ScheduleInstaller.install(
                    workflow: workflow,
                    device: device,
                    intervalSeconds: interval,
                    appPath: value(after: "--app", in: arguments)
                )
                print("Installed schedule: \(url.path)")
            case "agent-init":
                let queue = value(after: "--queue", in: arguments).map(URL.init(fileURLWithPath:)) ?? defaultAgentQueue
                let token = value(after: "--token-file", in: arguments).map(URL.init(fileURLWithPath:)) ?? defaultAgentToken
                try AgentQueue.initialize(queue: queue, tokenFile: token)
                print("Initialized authenticated agent queue: \(queue.path)")
                print("Token file (0600): \(token.path)")
            case "agent-submit":
                guard let workflow = value(after: "--workflow", in: arguments) else {
                    throw CLIError.message("--workflow is required")
                }
                let devices = values(after: "--device", in: arguments)
                guard !devices.isEmpty else { throw CLIError.message("At least one --device is required") }
                let queue = value(after: "--queue", in: arguments).map(URL.init(fileURLWithPath:)) ?? defaultAgentQueue
                let token = value(after: "--token-file", in: arguments).map(URL.init(fileURLWithPath:)) ?? defaultAgentToken
                var policy = ResourcePolicy.standard
                if let value = value(after: "--max-concurrency", in: arguments).flatMap(Int.init) { policy.maximumConcurrentVMs = value }
                if let value = value(after: "--memory-budget-mb", in: arguments).flatMap(Int.init) { policy.maximumAggregateMemoryMB = value }
                let job = try AgentQueue.submit(
                    queue: queue,
                    tokenFile: token,
                    workflow: workflow,
                    devices: devices,
                    appPath: value(after: "--app", in: arguments),
                    dryRun: arguments.contains("--dry-run"),
                    policy: policy
                )
                print("Queued authenticated job: \(job.id.uuidString)")
            case "agent-run-once":
                let queue = value(after: "--queue", in: arguments).map(URL.init(fileURLWithPath:)) ?? defaultAgentQueue
                let token = value(after: "--token-file", in: arguments).map(URL.init(fileURLWithPath:)) ?? defaultAgentToken
                if let receipt = try await AgentQueue.runOnce(queue: queue, tokenFile: token) {
                    print("\(receipt.state.rawValue.uppercased()) — \(receipt.jobID.uuidString) — \(receipt.message)")
                    exit(receipt.state == .passed ? 0 : 1)
                }
                print("No queued jobs")
            case "agent-status":
                guard let rawID = value(after: "--job", in: arguments), let jobID = UUID(uuidString: rawID) else {
                    throw CLIError.message("--job must be a valid UUID")
                }
                let queue = value(after: "--queue", in: arguments).map(URL.init(fileURLWithPath:)) ?? defaultAgentQueue
                let receipt = AgentQueue.status(queue: queue, jobID: jobID)
                if arguments.contains("--json") {
                    print(String(decoding: try JSONEncoder.lab.encode(receipt), as: UTF8.self))
                } else {
                    print("\(receipt.state.rawValue.uppercased()) — \(receipt.message)")
                }
                exit(receipt.state == .missing || receipt.state == .rejected ? 1 : 0)
            case "agent-cancel":
                guard let rawID = value(after: "--job", in: arguments), let jobID = UUID(uuidString: rawID) else {
                    throw CLIError.message("--job must be a valid UUID")
                }
                let queue = value(after: "--queue", in: arguments).map(URL.init(fileURLWithPath:)) ?? defaultAgentQueue
                let receipt = try AgentQueue.cancel(queue: queue, jobID: jobID)
                print("CANCELLED — \(receipt.jobID.uuidString) — \(receipt.message)")
            case "agent-key-rotate":
                let token = value(after: "--token-file", in: arguments).map(URL.init(fileURLWithPath:)) ?? defaultAgentToken
                let keyID = try AgentQueue.rotateKey(tokenFile: token, revokePrevious: arguments.contains("--revoke-previous"))
                print("Rotated agent key: \(keyID)")
            case "agent-cleanup":
                let queue = value(after: "--queue", in: arguments).map(URL.init(fileURLWithPath:)) ?? defaultAgentQueue
                let days = value(after: "--older-than-days", in: arguments).flatMap(Int.init) ?? 30
                let removed = try AgentQueue.cleanup(queue: queue, olderThanDays: days)
                print("Removed \(removed) expired queue artifact(s)")
            case "agent-health":
                let queue = value(after: "--queue", in: arguments).map(URL.init(fileURLWithPath:)) ?? defaultAgentQueue
                let token = value(after: "--token-file", in: arguments).map(URL.init(fileURLWithPath:)) ?? defaultAgentToken
                let report = AgentQueue.health(queue: queue, tokenFile: token)
                if arguments.contains("--json") {
                    print(String(decoding: try JSONEncoder.lab.encode(report), as: UTF8.self))
                } else {
                    print(report.healthy ? "Agent health: HEALTHY" : "Agent health: ACTION REQUIRED")
                    print("Key: \(report.activeKeyID ?? "unavailable") • queued \(report.queued) • running \(report.running) • results \(report.results)")
                    for issue in report.issues { print("- \(issue)") }
                }
                exit(report.healthy ? 0 : 2)
            case "help", "--help", "-h":
                usage()
            default:
                usage()
                exit(64)
            }
        } catch {
            fputs("vdlctl: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
