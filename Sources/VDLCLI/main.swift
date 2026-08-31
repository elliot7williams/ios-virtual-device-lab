import CryptoKit
import Darwin
import Foundation

private let cliVersion = "0.12.0"

enum CLIFileLock {
    static func withLock<T>(_ url: URL, _ body: () throws -> T) throws -> T {
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

func protectCLIFile(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

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
    private static func versionAtLeast08(_ value: String?) -> Bool {
        guard let value else { return false }
        let parts = value.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        return major > 0 || minor >= 8
    }

    private static func hasRequiredBackendContract(backend: String, result: CommandOutcome?) -> Bool {
        let liveData = result?.passed == true ? result?.output.data(using: .utf8) : nil
        let binary = URL(fileURLWithPath: backend)
        let bundledURL = binary
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/vdl-backend-contract.json")
        let bundledData = try? Data(contentsOf: bundledURL)
        guard let data = liveData ?? bundledData,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["schemaVersion"] as? Int == 1
            && object["backendID"] as? String == "vphone-cli"
            && object["hostControlProtocol"] as? Int == 3
            && object["exportExcludesCredentials"] as? Bool == true
            && versionAtLeast08(object["backendVersion"] as? String)
    }

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
        let backendCheck = backend.map { Shell.run($0, ["--vdl-contract"], timeout: 5) }
        let identities = Shell.run(
            "/usr/bin/security",
            ["find-identity", "-v", "-p", "codesigning"],
            timeout: 20
        ).output
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vphone")
            .resolvingSymlinksInPath()
        let available = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        var blockers: [String] = []
        if architecture != "arm64" { blockers.append("Apple silicon is required") }
        if !research.localizedCaseInsensitiveContains("enabled") {
            blockers.append("Allow Research Guests is not enabled from Recovery")
        }
        if backend == nil { blockers.append("vphone-cli is not installed") }
        else if !hasRequiredBackendContract(backend: backend!, result: backendCheck) {
            blockers.append("vphone-cli does not satisfy the required 0.8 backend contract")
        }
        let criticalStorageReserve = Int64(25) * 1_073_741_824
        if available < criticalStorageReserve {
            blockers.append("Free storage is below the 25 GiB critical reserve for the VM library")
        }
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
        try FileManager.default.createDirectory(
            at: tokenFile.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tokenFile.deletingLastPathComponent().path)
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
        let jobURL = directory(queue, "Inbox").appendingPathComponent("\(jobID.uuidString).json")
        try JSONEncoder.lab.encode(envelope).write(
            to: jobURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        try protectCLIFile(jobURL)
        return payload
    }

    static func runOnce(queue: URL, tokenFile: URL) async throws -> AgentJobReceipt? {
        try prepare(queue)
        let running: URL? = try CLIFileLock.withLock(queue.appendingPathComponent(".queue.lock")) {
            let inbox = directory(queue, "Inbox")
            let candidates = try FileManager.default.contentsOfDirectory(
                at: inbox,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard let source = candidates.first else { return nil }
            let claimed = directory(queue, "Running").appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: claimed)
            try protectCLIFile(claimed)
            return claimed
        }
        guard let running else { return nil }

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
        try protectCLIFile(marker)
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
        try FileManager.default.createDirectory(
            at: queue,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: queue.path)
        for name in ["Inbox", "Running", "Results", "Rejected", "Cancelled"] {
            let url = directory(queue, name)
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
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
        try CLIFileLock.withLock(queue.appendingPathComponent(".nonce.lock")) {
            var ledger = try loadReplayLedger(queue: queue)
            let key = nonce.uuidString
            guard ledger[key] == nil else { return false }
            ledger[key] = jobID.uuidString
            if ledger.count > 10_000 {
                ledger = Dictionary(uniqueKeysWithValues: ledger.sorted { $0.key > $1.key }.prefix(10_000).map { ($0.key, $0.value) })
            }
            let url = replayLedgerURL(queue: queue)
            try JSONEncoder.lab.encode(ledger).write(to: url, options: .atomic)
            try protectCLIFile(url)
            return true
        }
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
        let url = directory(queue, state == .cancelled ? "Cancelled" : "Rejected")
            .appendingPathComponent("\(jobID.uuidString).json")
        try JSONEncoder.lab.encode(receipt).write(
            to: url,
            options: .atomic
        )
        try protectCLIFile(url)
        try? FileManager.default.removeItem(at: running)
        return receipt
    }

    private static func write(_ receipt: AgentJobReceipt, queue: URL) throws {
        let url = directory(queue, "Results").appendingPathComponent("\(receipt.jobID.uuidString).json")
        try JSONEncoder.lab.encode(receipt).write(
            to: url,
            options: .atomic
        )
        try protectCLIFile(url)
    }
}

// MARK: - Declarative Labfile plan, diff, and non-destructive apply

struct CLILabfileDevice: Codable, Sendable {
    let name: String
    let hardwareProfileID: String
    let firmwareSHA256: String
    let cloudOSFirmwareSHA256: String?
    let cpuCount: Int
    let memoryMB: Int
    let diskSizeGB: Int
    let networkMode: String
    let environmentProfileID: UUID?
    let workflowNames: [String]
}

struct CLILabfile: Codable, Sendable {
    let schemaVersion: Int
    let name: String
    let backendID: String
    let devices: [CLILabfileDevice]
}

struct CLILabfileChange: Codable, Sendable {
    let deviceName: String
    let kind: String
    let summary: String
}

struct CLILabfilePlan: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let labName: String
    let changes: [CLILabfileChange]
    let blockers: [String]
    var canApply: Bool { blockers.isEmpty && !changes.contains { $0.kind == "blocked" } }
}

private struct CLIFirmwareRecord: Decodable {
    let kind: String
    let path: String
    let sha256: String?
}

enum CLILabfileEngine {
    static func load(_ url: URL) throws -> CLILabfile {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= 2 * 1_024 * 1_024 else {
            throw CLIError.message("Labfile must be between 1 byte and 2 MiB")
        }
        let document = try JSONDecoder.lab.decode(CLILabfile.self, from: data)
        guard document.schemaVersion == 1 else { throw CLIError.message("Only Labfile schema version 1 is supported") }
        guard document.backendID == "com.virtualdevicelab.vphone" else {
            throw CLIError.message("The Labfile backend does not match vphone-cli")
        }
        return document
    }

    static func plan(_ document: CLILabfile) -> CLILabfilePlan {
        let firmware = firmwareCatalog()
        var blockers: [String] = []
        var changes: [CLILabfileChange] = []
        var seen = Set<String>()
        for desired in document.devices {
            let key = desired.name.lowercased()
            guard !desired.name.isEmpty, safe(desired.name) == desired.name else {
                changes.append(.init(deviceName: desired.name, kind: "blocked", summary: "Device name contains unsafe path characters."))
                continue
            }
            guard seen.insert(key).inserted else {
                changes.append(.init(deviceName: desired.name, kind: "blocked", summary: "Duplicate device name."))
                continue
            }
            guard desired.cpuCount >= 1, desired.memoryMB >= 1_024, desired.diskSizeGB >= 8 else {
                changes.append(.init(deviceName: desired.name, kind: "blocked", summary: "CPU, memory, or disk value is below the safe minimum."))
                continue
            }
            guard ["nat", "bridged", "isolated", "offline"].contains(desired.networkMode) else {
                changes.append(.init(deviceName: desired.name, kind: "blocked", summary: "Unsupported network mode."))
                continue
            }
            guard firmware.contains(where: {
                $0.kind == "iPhone" && $0.sha256?.caseInsensitiveCompare(desired.firmwareSHA256) == .orderedSame
            }) else {
                changes.append(.init(deviceName: desired.name, kind: "blocked", summary: "Pinned iPhone firmware is absent from the authorized local catalog."))
                continue
            }
            let bundle = vmRoot(desired.name)
            guard FileManager.default.fileExists(atPath: bundle.path) else {
                changes.append(.init(deviceName: desired.name, kind: "create", summary: "Create from pinned local firmware, then apply hardware configuration."))
                continue
            }
            guard let current = readConfiguration(bundle) else {
                changes.append(.init(deviceName: desired.name, kind: "blocked", summary: "Existing VM configuration cannot be parsed."))
                continue
            }
            let desiredNetwork = backendNetwork(desired.networkMode)
            var fields: [String] = []
            if current.cpu != desired.cpuCount { fields.append("CPU") }
            if current.memoryMB != desired.memoryMB { fields.append("memory") }
            if current.network != desiredNetwork { fields.append("network") }
            changes.append(.init(
                deviceName: desired.name,
                kind: fields.isEmpty ? "unchanged" : "update",
                summary: fields.isEmpty ? "Configuration already matches." : "Update \(fields.joined(separator: ", "))."
            ))
        }
        if document.devices.isEmpty { blockers.append("The Labfile contains no devices.") }
        return CLILabfilePlan(
            schemaVersion: 1, generatedAt: .now, labName: document.name,
            changes: changes, blockers: blockers
        )
    }

    static func apply(_ document: CLILabfile) throws -> CLILabfilePlan {
        let initial = plan(document)
        guard initial.canApply else {
            throw CLIError.message("Labfile apply is blocked; run `vdlctl labfile plan --file …` for details")
        }
        guard let backend = resolveVPhone() else { throw CLIError.message("vphone-cli is not installed") }
        let firmware = firmwareCatalog()
        for desired in document.devices {
            let change = initial.changes.first { $0.deviceName == desired.name }
            if change?.kind == "create" {
                guard let iphone = firmware.first(where: {
                    $0.kind == "iPhone" && $0.sha256?.caseInsensitiveCompare(desired.firmwareSHA256) == .orderedSame
                }) else { throw CLIError.message("Pinned firmware disappeared before apply") }
                var arguments = [
                    "vm", "create", desired.name, "--variant", "regular",
                    "--disk-size", String(desired.diskSizeGB), "--root-popup",
                    "--library-root", libraryRoot.path, "--iphone-source", iphone.path,
                ]
                if let cloudHash = desired.cloudOSFirmwareSHA256,
                   let cloud = firmware.first(where: {
                       $0.kind == "cloudOS" && $0.sha256?.caseInsensitiveCompare(cloudHash) == .orderedSame
                   }) {
                    arguments += ["--cloudos-source", cloud.path]
                }
                let create = Shell.run(backend, arguments, timeout: 24 * 60 * 60)
                guard create.passed else { throw CLIError.message("Create \(desired.name) failed: \(create.output.trimmed)") }
            }
            if change?.kind == "create" || change?.kind == "update" {
                let configure = Shell.run(backend, [
                    "vm", "config", desired.name,
                    "--cpu", String(desired.cpuCount), "--memory", String(desired.memoryMB),
                    "--network", backendNetwork(desired.networkMode),
                    "--library-root", libraryRoot.path,
                ], timeout: 300)
                guard configure.passed else {
                    throw CLIError.message("Configure \(desired.name) failed: \(configure.output.trimmed)")
                }
                try writeMetadata(desired)
            }
        }
        return plan(document)
    }

    private static func firmwareCatalog() -> [CLIFirmwareRecord] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vphone/VirtualDeviceLab/firmware-catalog.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.lab.decode([CLIFirmwareRecord].self, from: data)) ?? []
    }

    private static func readConfiguration(_ bundle: URL) -> (cpu: Int, memoryMB: Int, network: String)? {
        let url = bundle.appendingPathComponent("config.plist")
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        let cpu = (object["cpuCount"] as? NSNumber)?.intValue ?? 0
        let memoryBytes = (object["memorySize"] as? NSNumber)?.int64Value ?? 0
        let network = (object["networkConfig"] as? [String: Any])?["mode"] as? String ?? "nat"
        return (cpu, Int(memoryBytes / 1_048_576), network)
    }

    private static func backendNetwork(_ mode: String) -> String {
        ["offline", "isolated"].contains(mode) ? "none" : mode
    }

    private static func writeMetadata(_ device: CLILabfileDevice) throws {
        let network: [String: Any] = [
            "mode": device.networkMode,
            "captureTraffic": false,
            "allowHostAccess": false,
        ]
        let audio: [String: Any] = [
            "outputEnabled": true, "inputEnabled": false, "route": "systemOutput",
            "sampleRateHz": 48_000, "simulateInterruptions": false,
            "backgroundAudioValidation": true,
        ]
        let isolation: [String: Any] = [
            "allowNetwork": device.networkMode != "offline", "allowHostNetwork": false,
            "allowClipboard": false, "allowHostIntegration": false,
        ]
        let metadata: [String: Any] = [
            "schemaVersion": 1, "hardwareProfileID": device.hardwareProfileID,
            "network": network, "audio": audio, "isolation": isolation,
            "updatedAt": ISO8601DateFormatter().string(from: .now),
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        let url = vmRoot(device.name).appendingPathComponent("lab-metadata.json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try protectCLIFile(url)
    }
}

// MARK: - Platform engineering contracts

struct CLIAdapterManifest: Codable {
    let schemaVersion: Int
    let id: String
    let name: String
    let version: String
    let protocolVersion: Int
    let capabilities: [String]
    let minimumLabVersion: String
    let executablePath: String?
    let licenseReference: String
}

struct CLIAdapterCheck: Codable {
    let id: String
    let passed: Bool
    let evidence: String
}

struct CLIAdapterReport: Codable {
    let generatedAt: Date
    let adapterID: String
    let checks: [CLIAdapterCheck]
    var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
}

enum CLIAdapterConformance {
    private static let supportedCapabilities = Set([
        "lifecycle", "pause", "screenshots", "automation", "guestLogs", "networking",
        "audio", "performanceMetrics", "crashExport", "xcodeDeployment", "snapshotRestore",
        "deterministicReset", "timelineVideo",
    ])

    static func check(_ url: URL) throws -> CLIAdapterReport {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw CLIError.message("Adapter manifest exceeds 1 MiB") }
        let manifest = try JSONDecoder.lab.decode(CLIAdapterManifest.self, from: Data(contentsOf: url))
        let identifier = manifest.id.range(of: "^[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+){2,}$", options: .regularExpression) != nil
        let semver = manifest.version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$", options: .regularExpression) != nil
        let unknown = manifest.capabilities.filter { !supportedCapabilities.contains($0) }.sorted()
        let duplicates = Dictionary(grouping: manifest.capabilities, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        let executablePassed = manifest.executablePath.map { FileManager.default.isExecutableFile(atPath: $0) } ?? true
        return CLIAdapterReport(generatedAt: .now, adapterID: manifest.id, checks: [
            .init(id: "schema", passed: manifest.schemaVersion == 1, evidence: "Schema \(manifest.schemaVersion); required 1."),
            .init(id: "identifier", passed: identifier, evidence: "Adapter ID must be a stable reverse-domain identifier."),
            .init(id: "version", passed: semver, evidence: "Adapter version must use semantic versioning."),
            .init(id: "minimum-lab-version", passed: compatibleMinimum(manifest.minimumLabVersion), evidence: "Adapter requires lab \(manifest.minimumLabVersion); this build is \(cliVersion)."),
            .init(id: "protocol", passed: manifest.protocolVersion == 3, evidence: "Protocol \(manifest.protocolVersion); required 3."),
            .init(id: "capabilities", passed: !manifest.capabilities.isEmpty && unknown.isEmpty && duplicates.isEmpty,
                  evidence: unknown.isEmpty && duplicates.isEmpty ? "\(manifest.capabilities.count) recognized capability/capabilities." : "Unknown: \(unknown); duplicates: \(duplicates)."),
            .init(id: "executable", passed: executablePassed, evidence: manifest.executablePath == nil ? "Manifest-only validation." : "Configured executable must be runnable."),
            .init(id: "license", passed: !manifest.licenseReference.trimmed.isEmpty, evidence: "A provenance and license reference is required."),
        ])
    }

    private static func compatibleMinimum(_ required: String) -> Bool {
        func components(_ value: String) -> [Int]? {
            let core = value.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
            let values = core.split(separator: ".").compactMap { Int($0) }
            return values.count == 3 ? values : nil
        }
        guard let required = components(required), let current = components(cliVersion) else { return false }
        return required.lexicographicallyPrecedes(current) || required == current
    }
}

struct CLIPlatformStatus: Codable {
    let schemaVersion: Int?
    let stateFile: String
    let adapters: Int
    let builds: Int
    let replayBundles: Int
    let fleetHosts: Int
    let timelines: Int
    let fuzzCases: Int
    let fuzzPassed: Bool
    let coveragePassed: Bool
    let betaChannel: String?
    let betaPromotionReady: Bool
}

enum CLIPlatformInspector {
    static func inspect() throws -> CLIPlatformStatus {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vphone/VirtualDeviceLab/platform-engineering.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CLIPlatformStatus(
                schemaVersion: nil, stateFile: url.path, adapters: 0, builds: 0, replayBundles: 0,
                fleetHosts: 0, timelines: 0, fuzzCases: 0, fuzzPassed: false,
                coveragePassed: false, betaChannel: nil, betaPromotionReady: false
            )
        }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw CLIError.message("Platform engineering state is not a JSON object")
        }
        let quality = root["quality"] as? [String: Any] ?? [:]
        let beta = root["betaOperations"] as? [String: Any] ?? [:]
        let gates = beta["gates"] as? [[String: Any]] ?? []
        func count(_ key: String) -> Int { (root[key] as? [Any])?.count ?? 0 }
        return CLIPlatformStatus(
            schemaVersion: root["schemaVersion"] as? Int, stateFile: url.path,
            adapters: count("adapterManifests"), builds: count("builds"), replayBundles: count("replayBundles"),
            fleetHosts: count("fleetHosts"), timelines: count("timelines"),
            fuzzCases: quality["totalCases"] as? Int ?? 0,
            fuzzPassed: quality["fuzzGatePassed"] as? Bool ?? false,
            coveragePassed: quality["coverageGatePassed"] as? Bool ?? false,
            betaChannel: beta["channel"] as? String,
            betaPromotionReady: !gates.isEmpty && gates.allSatisfy { $0["passed"] as? Bool == true }
        )
    }
}

struct CLIExpansionStatus: Codable {
    let schemaVersion: Int?
    let stateFile: String
    let maturityRecords: Int
    let approvedQualifications: Int
    let installedAdapters: Int
    let successfulAdapterInvocations: Int
    let guestAutomationResults: Int
    let replayExecutions: Int
    let successfulSymbolications: Int
    let activeFleetLeases: Int
    let highFidelityTimelines: Int
    let coverageReports: Int
    let physicalDevices: Int
    let successfulPhysicalDeployments: Int
    let routedTarget: String?
}

enum CLIExpansionInspector {
    static func inspect() throws -> CLIExpansionStatus {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vphone/VirtualDeviceLab/lab-expansion.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CLIExpansionStatus(
                schemaVersion: nil, stateFile: url.path, maturityRecords: 0,
                approvedQualifications: 0, installedAdapters: 0,
                successfulAdapterInvocations: 0, guestAutomationResults: 0,
                replayExecutions: 0, successfulSymbolications: 0,
                activeFleetLeases: 0, highFidelityTimelines: 0,
                coverageReports: 0, physicalDevices: 0,
                successfulPhysicalDeployments: 0, routedTarget: nil
            )
        }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw CLIError.message("Qualification and scale state is not a JSON object")
        }
        func records(_ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }
        let route = root["hybridRoute"] as? [String: Any]
        let target = route?["target"] as? [String: Any]
        return CLIExpansionStatus(
            schemaVersion: root["schemaVersion"] as? Int,
            stateFile: url.path,
            maturityRecords: records("maturity").count,
            approvedQualifications: records("qualificationMatrix").filter { $0["state"] as? String == "approved" }.count,
            installedAdapters: records("installedAdapters").count,
            successfulAdapterInvocations: records("adapterInvocations").filter { $0["succeeded"] as? Bool == true }.count,
            guestAutomationResults: records("guestAutomationResults").count,
            replayExecutions: records("replayExecutions").count,
            successfulSymbolications: records("symbolicationReports").filter { $0["succeeded"] as? Bool == true }.count,
            activeFleetLeases: records("fleetLeases").filter { $0["state"] as? String == "active" }.count,
            highFidelityTimelines: records("highFidelityTimelines").count,
            coverageReports: records("coverageReports").count,
            physicalDevices: records("physicalDevices").count,
            successfulPhysicalDeployments: records("physicalDeployments").filter { $0["installed"] as? Bool == true && $0["launched"] as? Bool == true }.count,
            routedTarget: target?["name"] as? String
        )
    }
}

struct CLIProductionDepthStatus: Codable {
    let schemaVersion: Int?
    let stateFile: String
    let companionPackages: Int
    let activeCompanions: Int
    let passingSigningAssessments: Int
    let readyPhysicalDevices: Int
    let activePhysicalLeases: Int
    let passingVisualRegressions: Int
    let successfulFaultInjections: Int
    let mtlsConfigured: Bool
    let authenticatedMTLSProbes: Int
    let sqliteIntegrityPassed: Bool
    let sqliteEventRows: Int
    let compatibilityCertificates: Int
    let upgradeAllowed: Bool
    let ciMaintenancePassed: Bool
    let passingRunbookDrills: Int
}

enum CLIProductionDepthInspector {
    static func inspect() throws -> CLIProductionDepthStatus {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vphone/VirtualDeviceLab/production-depth.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CLIProductionDepthStatus(
                schemaVersion: nil, stateFile: url.path, companionPackages: 0, activeCompanions: 0,
                passingSigningAssessments: 0, readyPhysicalDevices: 0, activePhysicalLeases: 0,
                passingVisualRegressions: 0, successfulFaultInjections: 0, mtlsConfigured: false,
                authenticatedMTLSProbes: 0, sqliteIntegrityPassed: false, sqliteEventRows: 0,
                compatibilityCertificates: 0, upgradeAllowed: false, ciMaintenancePassed: false,
                passingRunbookDrills: 0
            )
        }
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw CLIError.message("Production-depth state is not a JSON object")
        }
        func records(_ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }
        let eventStore = root["eventStore"] as? [String: Any] ?? [:]
        let upgrade = root["upgradeDecision"] as? [String: Any] ?? [:]
        let ci = root["ciMaintenance"] as? [String: Any] ?? [:]
        return CLIProductionDepthStatus(
            schemaVersion: root["schemaVersion"] as? Int,
            stateFile: url.path,
            companionPackages: records("companions").count,
            activeCompanions: records("companions").filter { $0["active"] as? Bool == true }.count,
            passingSigningAssessments: records("signingAssessments").filter {
                $0["signatureValid"] as? Bool == true && $0["provisioningValid"] as? Bool == true
            }.count,
            readyPhysicalDevices: records("physicalDetails").filter {
                $0["connected"] as? Bool == true && $0["paired"] as? Bool == true
                    && $0["developerModeEnabled"] as? Bool == true && $0["ddiServicesReady"] as? Bool == true
            }.count,
            activePhysicalLeases: records("physicalLeases").filter { $0["state"] as? String == "active" }.count,
            passingVisualRegressions: records("visualRegressions").filter { $0["passed"] as? Bool == true }.count,
            successfulFaultInjections: records("faultResults").filter { $0["succeeded"] as? Bool == true }.count,
            mtlsConfigured: root["mtlsConfiguration"] != nil,
            authenticatedMTLSProbes: records("mtlsProbes").filter { $0["authenticated"] as? Bool == true }.count,
            sqliteIntegrityPassed: eventStore["integrityPassed"] as? Bool ?? false,
            sqliteEventRows: eventStore["rowCount"] as? Int ?? 0,
            compatibilityCertificates: records("compatibilityCertificates").count,
            upgradeAllowed: upgrade["allowed"] as? Bool ?? false,
            ciMaintenancePassed: ci["passed"] as? Bool ?? false,
            passingRunbookDrills: records("runbookDrills").filter { $0["passed"] as? Bool == true }.count
        )
    }
}

struct CLIExecutionTarget: Codable {
    let id: String
    let kind: String
    let name: String
    let osVersion: String?
    let available: Bool
    let capabilities: [String]
}

enum CLITargetDiscovery {
    static func list() -> [CLIExecutionTarget] {
        var targets: [CLIExecutionTarget] = []
        let virtualCapabilities = ["lifecycle", "automation", "networking", "audio", "screenshots"]
        let virtualRoots = ((try? FileManager.default.contentsOfDirectory(
            at: libraryRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        targets += virtualRoots.map {
            CLIExecutionTarget(id: $0.lastPathComponent, kind: "virtual", name: $0.lastPathComponent,
                               osVersion: virtualOSVersion(at: $0), available: true,
                               capabilities: virtualCapabilities)
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("vdl-targets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = Shell.run("/usr/bin/xcrun", ["devicectl", "list", "devices", "--timeout", "10", "--json-output", output.path], timeout: 15)
        if result.passed,
           let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: output)) {
            var seen = Set<String>()
            let physical = dictionaries(in: object).compactMap { dictionary -> CLIExecutionTarget? in
                let properties = dictionary["deviceProperties"] as? [String: Any] ?? [:]
                guard let id = string(dictionary["identifier"] ?? properties["identifier"]),
                      seen.insert(id).inserted else { return nil }
                let name = string(dictionary["name"] ?? properties["name"]) ?? "Physical iOS device"
                let version = string(properties["osVersionNumber"] ?? dictionary["osVersionNumber"])
                let connection = dictionary["connectionProperties"] as? [String: Any] ?? [:]
                let state = (string(connection["tunnelState"] ?? dictionary["connectionState"] ?? properties["connectionState"]) ?? "").lowercased()
                let pairing = (string(connection["pairingState"] ?? dictionary["pairingState"]) ?? "").lowercased()
                let developerMode = (string(properties["developerModeStatus"] ?? dictionary["developerModeStatus"]) ?? "").lowercased()
                return CLIExecutionTarget(
                    id: id, kind: "physical", name: name, osVersion: version,
                    available: (state == "connected" || properties["ddiServicesAvailable"] as? Bool == true)
                        && pairing == "paired" && developerMode == "enabled",
                    capabilities: ["camera", "cellular", "secureEnclave", "biometrics", "bluetooth", "motion", "audio", "networking", "xcodeDeployment"]
                )
            }
            targets += physical
        }
        return targets.sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
    }

    static func route(targets: [CLIExecutionTarget], required: [String], iosMajor: Int?, preferPhysical: Bool) -> CLIExecutionTarget? {
        let required = Set(required)
        return targets.filter { target in
            target.available && required.isSubset(of: Set(target.capabilities))
                && iosMajor.map { target.osVersion.flatMap { Int($0.split(separator: ".").first ?? "") } == $0 } != false
        }.sorted { left, right in
            if left.kind != right.kind { return preferPhysical ? left.kind == "physical" : left.kind == "virtual" }
            return left.name < right.name
        }.first
    }

    private static func virtualOSVersion(at root: URL) -> String? {
        let paths = [root.appendingPathComponent("config.plist"), root.appendingPathComponent("restore-info.plist")]
        for path in paths {
            guard let data = try? Data(contentsOf: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            if let value = plist["ProductVersion"] as? String { return value }
            if let restore = plist["restoreInfo"] as? [String: Any], let ios = restore["iOS"] as? [String: Any], let value = ios["version"] as? String { return value }
        }
        return nil
    }

    private static func dictionaries(in value: Any) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] { return [dictionary] + dictionary.values.flatMap(dictionaries) }
        if let array = value as? [Any] { return array.flatMap(dictionaries) }
        return []
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
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
private struct CLIAppArtifactRecord: Decodable { let id: UUID; let path: String }
private func resolveAppArtifact(_ identifier: String) -> String? {
    guard let id = UUID(uuidString: identifier) else { return nil }
    let catalog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".vphone/VirtualDeviceLab/App Artifacts/catalog.json")
    guard let data = try? Data(contentsOf: catalog),
          let records = try? JSONDecoder.lab.decode([CLIAppArtifactRecord].self, from: data),
          let record = records.first(where: { $0.id == id }),
          FileManager.default.fileExists(atPath: record.path)
    else { return nil }
    return record.path
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
                 [--app <ipa>|--app-artifact <uuid>] [--output <directory>] [--max-concurrency <n>]
                 [--memory-budget-mb <n>] [--reserve-memory-mb <n>] [--max-cpu <percent>] [--dry-run]
      vdlctl deploy --device <name> --app <ipa> [--output <directory>]
      vdlctl schedule-install --workflow <file|id|name> --device <name> --interval-seconds <n> [--app <ipa>]
      vdlctl labfile plan --file <Labfile.json> [--json]
      vdlctl labfile diff --file <Labfile.json> [--json]
      vdlctl labfile apply --file <Labfile.json> [--json]
      vdlctl adapter check --manifest <adapter-manifest.json> [--json]
      vdlctl platform status [--json]
      vdlctl expansion status [--json]
      vdlctl depth status [--json]
      vdlctl targets list [--json]
      vdlctl targets route [--capability <name> ...] [--ios-major <n>] [--prefer-physical] [--json]
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
                    appPath: value(after: "--app", in: arguments)
                        ?? value(after: "--app-artifact", in: arguments).flatMap(resolveAppArtifact),
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
            case "labfile":
                guard arguments.indices.contains(1),
                      ["plan", "diff", "apply"].contains(arguments[1]),
                      let file = value(after: "--file", in: arguments)
                else { throw CLIError.message("Use `vdlctl labfile <plan|diff|apply> --file <Labfile.json>`") }
                let action = arguments[1]
                let document = try CLILabfileEngine.load(URL(fileURLWithPath: file))
                let plan = action == "apply" ? try CLILabfileEngine.apply(document) : CLILabfileEngine.plan(document)
                if arguments.contains("--json") {
                    print(String(decoding: try JSONEncoder.lab.encode(plan), as: UTF8.self))
                } else {
                    print("Labfile \(action): \(plan.labName)")
                    for change in plan.changes {
                        print("- \(change.kind.uppercased()) \(change.deviceName): \(change.summary)")
                    }
                    for blocker in plan.blockers { print("- BLOCKED: \(blocker)") }
                }
                exit(plan.canApply ? 0 : 2)
            case "adapter":
                guard arguments.indices.contains(1), arguments[1] == "check",
                      let manifest = value(after: "--manifest", in: arguments)
                else { throw CLIError.message("Use `vdlctl adapter check --manifest <adapter-manifest.json>`") }
                let report = try CLIAdapterConformance.check(URL(fileURLWithPath: manifest))
                if arguments.contains("--json") {
                    print(String(decoding: try JSONEncoder.lab.encode(report), as: UTF8.self))
                } else {
                    print(report.passed ? "Adapter conformance: PASS" : "Adapter conformance: FAIL")
                    for check in report.checks {
                        print("- \(check.passed ? "PASS" : "FAIL") \(check.id): \(check.evidence)")
                    }
                }
                exit(report.passed ? 0 : 2)
            case "platform":
                guard arguments.indices.contains(1), arguments[1] == "status" else {
                    throw CLIError.message("Use `vdlctl platform status [--json]`")
                }
                let status = try CLIPlatformInspector.inspect()
                if arguments.contains("--json") {
                    print(String(decoding: try JSONEncoder.lab.encode(status), as: UTF8.self))
                } else {
                    print("Platform engineering schema: \(status.schemaVersion.map(String.init) ?? "not initialized")")
                    print("Adapters \(status.adapters) • builds \(status.builds) • replay bundles \(status.replayBundles) • hosts \(status.fleetHosts) • timelines \(status.timelines)")
                    print("Fuzz \(status.fuzzPassed ? "PASS" : "INCOMPLETE") (\(status.fuzzCases) cases) • coverage \(status.coveragePassed ? "PASS" : "INCOMPLETE")")
                    print("Beta \(status.betaChannel ?? "not evaluated") • promotion \(status.betaPromotionReady ? "READY" : "HOLD")")
                }
            case "expansion":
                guard arguments.indices.contains(1), arguments[1] == "status" else {
                    throw CLIError.message("Use `vdlctl expansion status [--json]`")
                }
                let status = try CLIExpansionInspector.inspect()
                if arguments.contains("--json") {
                    print(String(decoding: try JSONEncoder.lab.encode(status), as: UTF8.self))
                } else {
                    print("Qualification & scale schema: \(status.schemaVersion.map(String.init) ?? "not initialized")")
                    print("Maturity \(status.maturityRecords) • approved qualifications \(status.approvedQualifications) • installed adapters \(status.installedAdapters)")
                    print("Adapter calls \(status.successfulAdapterInvocations) • guest automation \(status.guestAutomationResults) • replays \(status.replayExecutions) • symbolications \(status.successfulSymbolications)")
                    print("Active leases \(status.activeFleetLeases) • timelines \(status.highFidelityTimelines) • coverage reports \(status.coverageReports) • physical devices \(status.physicalDevices) • physical deployments \(status.successfulPhysicalDeployments)")
                    print("Hybrid route: \(status.routedTarget ?? "not routed")")
                }
            case "depth":
                guard arguments.indices.contains(1), arguments[1] == "status" else {
                    throw CLIError.message("Use `vdlctl depth status [--json]`")
                }
                let status = try CLIProductionDepthInspector.inspect()
                if arguments.contains("--json") {
                    print(String(decoding: try JSONEncoder.lab.encode(status), as: UTF8.self))
                } else {
                    print("Production depth schema: \(status.schemaVersion.map(String.init) ?? "not initialized")")
                    print("Companions \(status.activeCompanions)/\(status.companionPackages) active • signing \(status.passingSigningAssessments) passing • physical \(status.readyPhysicalDevices) ready / \(status.activePhysicalLeases) leased")
                    print("Visual \(status.passingVisualRegressions) passing • faults \(status.successfulFaultInjections) successful • mTLS probes \(status.authenticatedMTLSProbes)")
                    print("SQLite \(status.sqliteIntegrityPassed ? "PASS" : "NOT READY") (\(status.sqliteEventRows) events) • upgrade \(status.upgradeAllowed ? "ALLOWED" : "HOLD")")
                    print("CI lifecycle \(status.ciMaintenancePassed ? "PASS" : "NOT AUDITED") • runbook drills \(status.passingRunbookDrills) passing")
                }
            case "targets":
                guard arguments.indices.contains(1), ["list", "route"].contains(arguments[1]) else {
                    throw CLIError.message("Use `vdlctl targets <list|route> [options]`")
                }
                let targets = CLITargetDiscovery.list()
                if arguments[1] == "list" {
                    if arguments.contains("--json") {
                        print(String(decoding: try JSONEncoder.lab.encode(targets), as: UTF8.self))
                    } else if targets.isEmpty {
                        print("No virtual or authorized physical targets were discovered")
                    } else {
                        for target in targets {
                            print("\(target.kind.uppercased()) \(target.name) • iOS \(target.osVersion ?? "unknown") • \(target.available ? "available" : "unavailable")")
                        }
                    }
                } else {
                    let required = values(after: "--capability", in: arguments)
                    let iosMajor = value(after: "--ios-major", in: arguments).flatMap(Int.init)
                    guard let target = CLITargetDiscovery.route(
                        targets: targets, required: required, iosMajor: iosMajor,
                        preferPhysical: arguments.contains("--prefer-physical")
                    ) else { throw CLIError.message("No available target satisfies the requested version and capabilities") }
                    if arguments.contains("--json") {
                        print(String(decoding: try JSONEncoder.lab.encode(target), as: UTF8.self))
                    } else {
                        print("Routed to \(target.kind) target \(target.name)")
                    }
                }
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
