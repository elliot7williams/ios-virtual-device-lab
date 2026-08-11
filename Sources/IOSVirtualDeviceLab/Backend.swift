@preconcurrency import Foundation
import CryptoKit
import Darwin

final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancellationRequested = false

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel, process.isRunning { process.interrupt() }
    }

    func detach() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = process
        lock.unlock()
        if let process, process.isRunning { process.interrupt() }
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }
}

final class StreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var completeOutput = ""
    private var pendingLine = ""
    private let onLine: @Sendable (String) -> Void
    private let maximumOutputBytes: Int?
    private let onLimitExceeded: @Sendable () -> Void
    private var exceededLimit = false

    init(
        maximumOutputBytes: Int? = nil,
        onLine: @escaping @Sendable (String) -> Void,
        onLimitExceeded: @escaping @Sendable () -> Void = {}
    ) {
        self.maximumOutputBytes = maximumOutputBytes
        self.onLine = onLine
        self.onLimitExceeded = onLimitExceeded
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        consume(String(decoding: data, as: UTF8.self))
    }

    func consume(_ text: String) {
        var completed: [String] = []
        var reachedLimit = false
        lock.lock()
        guard !exceededLimit else { lock.unlock(); return }
        var accepted = text
        if let maximumOutputBytes {
            let currentBytes = completeOutput.lengthOfBytes(using: .utf8)
            let remaining = max(0, maximumOutputBytes - currentBytes)
            let incoming = Data(text.utf8)
            if incoming.count > remaining {
                accepted = String(decoding: incoming.prefix(remaining), as: UTF8.self)
                exceededLimit = true
                reachedLimit = true
            }
        }
        completeOutput += accepted
        pendingLine += accepted
        let pieces = pendingLine.components(separatedBy: .newlines)
        if pieces.count > 1 {
            completed = Array(pieces.dropLast())
            pendingLine = pieces.last ?? ""
        }
        lock.unlock()
        for line in completed where !line.isEmpty { onLine(line) }
        if reachedLimit { onLimitExceeded() }
    }

    func finish() -> String {
        var tail = ""
        lock.lock()
        if !pendingLine.isEmpty {
            tail = pendingLine
            pendingLine = ""
        }
        let output = completeOutput
        lock.unlock()
        if !tail.isEmpty { onLine(tail) }
        return output
    }

    var outputLimitExceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exceededLimit
    }
}

enum ProcessExecutor {
    static func run(
        executable: URL,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment additions: [String: String] = [:],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil,
        maximumOutputBytes: Int? = nil,
        control: ProcessControl? = nil,
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) -> CommandResult {
        let startedAt = Date()
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        let processControl = control ?? ProcessControl()
        let accumulator = StreamAccumulator(
            maximumOutputBytes: maximumOutputBytes,
            onLine: onLine,
            onLimitExceeded: { processControl.cancel() }
        )

        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe
        process.environment = ProcessInfo.processInfo.environment.merging(additions) { _, new in new }
        processControl.attach(process)
        defer { processControl.detach() }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            accumulator.consume(handle.availableData)
        }

        do {
            try process.run()
            if let standardInput {
                inputPipe.fileHandleForWriting.write(standardInput)
            }
            try? inputPipe.fileHandleForWriting.close()
            if processControl.isCancellationRequested, process.isRunning {
                process.interrupt()
            }
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            accumulator.consume("error: \(error.localizedDescription)\n")
            return CommandResult(
                executable: executable.path,
                arguments: arguments,
                output: accumulator.finish(),
                exitCode: 127,
                duration: Date().timeIntervalSince(startedAt)
            )
        }

        var timedOut = false
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline && !processControl.isCancellationRequested {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning && !processControl.isCancellationRequested {
                timedOut = true
                process.interrupt()
            }
        } else {
            while process.isRunning && !processControl.isCancellationRequested {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        if process.isRunning && processControl.isCancellationRequested {
            process.interrupt()
        }
        if process.isRunning {
            let graceDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < graceDeadline { Thread.sleep(forTimeInterval: 0.05) }
        }
        if process.isRunning { process.terminate() }
        if process.isRunning {
            let terminateDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < terminateDeadline { Thread.sleep(forTimeInterval: 0.05) }
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        accumulator.consume(outputPipe.fileHandleForReading.readDataToEndOfFile())
        let status: Int32 = process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus
            : process.terminationStatus
        return CommandResult(
            executable: executable.path,
            arguments: arguments,
            output: accumulator.finish(),
            exitCode: status,
            timedOut: timedOut,
            cancelled: processControl.isCancellationRequested,
            outputLimitExceeded: accumulator.outputLimitExceeded,
            duration: Date().timeIntervalSince(startedAt)
        )
    }

    static func runAsync(
        executable: URL,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment additions: [String: String] = [:],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil,
        maximumOutputBytes: Int? = nil,
        control: ProcessControl? = nil,
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> CommandResult {
        let control = control ?? ProcessControl()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                run(
                    executable: executable,
                    arguments: arguments,
                    currentDirectory: currentDirectory,
                    environment: additions,
                    standardInput: standardInput,
                    timeout: timeout,
                    maximumOutputBytes: maximumOutputBytes,
                    control: control,
                    onLine: onLine
                )
            }.value
        } onCancel: {
            control.cancel()
        }
    }
}

actor VPhoneBackend: LabBackend {
    let paths: LabPaths
    nonisolated let descriptor = BackendDescriptor.vphone
    nonisolated let capabilities = BackendCapabilities.vphone
    private var activeControls: [UUID: ProcessControl] = [:]
    private var previousIOCounters: [String: (read: UInt64, written: UInt64, timestamp: Date)] = [:]

    init(paths: LabPaths = .default) {
        self.paths = paths
    }

    // MARK: - Discovery

    func prepareStorage() throws {
        try paths.createDirectories()
    }

    func resolveBinary() -> URL? {
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["VPHONE_CLI_BIN"], !override.isEmpty {
            candidates.append(override)
        }
        candidates += [
            "/opt/homebrew/bin/vphone-cli",
            "/Applications/vphone-cli.app/Contents/MacOS/vphone-cli",
        ]
        return candidates
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func checkHost() -> HostReadiness {
        let swVers = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/sw_vers"),
            arguments: ["-productVersion"],
            timeout: 5
        )
        let architecture = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/uname"),
            arguments: ["-m"],
            timeout: 5
        )
        let model = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/sbin/sysctl"),
            arguments: ["-n", "hw.model"],
            timeout: 5
        )
        let hypervisor = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/sbin/sysctl"),
            arguments: ["-n", "kern.hv_vmm_present"],
            timeout: 5
        )
        let sip = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/csrutil"),
            arguments: ["status"],
            timeout: 10
        )

        let research = researchGuestStatus()
        let binary = resolveBinary()
        let binaryCheck = binary.map {
            ProcessExecutor.run(executable: $0, arguments: ["--help"], timeout: 20)
        }

        let arch = architecture.output.trimmed
        let nested = hypervisor.output.trimmed == "1"
        let researchEnabled = research.localizedCaseInsensitiveContains("enabled")
        let binaryReady = binaryCheck?.succeeded == true

        let state: ReadinessState
        if arch != "arm64" || nested || binary == nil {
            state = .unavailable
        } else if researchEnabled && binaryReady {
            state = .ready
        } else {
            state = .actionRequired
        }

        return HostReadiness(
            state: state,
            macOSVersion: swVers.output.trimmed,
            model: model.output.trimmed,
            architecture: arch,
            sipStatus: sip.output.trimmed,
            researchGuestsStatus: research,
            binaryPath: binary?.path,
            binaryExitCode: binaryCheck?.exitCode,
            nestedVirtualization: nested,
            checkedAt: .now
        )
    }

    private func researchGuestStatus() -> String {
        let csrutil = URL(fileURLWithPath: "/usr/bin/csrutil")
        let initial = ProcessExecutor.run(
            executable: csrutil,
            arguments: ["allow-research-guests", "status"],
            standardInput: Data(),
            timeout: 10
        )
        if initial.timedOut { return "Research-guest policy check timed out" }
        guard initial.output.contains("Pick a macOS installation") else {
            return initial.output.trimmed.nilIfEmpty ?? "Unavailable"
        }

        let lines = initial.output.components(separatedBy: .newlines)
        guard let selected = lines.first(where: { $0.contains("Macintosh HD") }),
              let number = selected.split(separator: ":").first?.trimmed,
              Int(number) != nil
        else {
            return "Disabled or unavailable (multiple macOS installations)"
        }

        let chosen = ProcessExecutor.run(
            executable: csrutil,
            arguments: ["allow-research-guests", "status"],
            standardInput: Data("\(number)\n".utf8),
            timeout: 10
        )
        if chosen.timedOut { return "Research-guest policy selection timed out" }
        if let statusRange = chosen.output.range(of: "Allow Research Guests status:") {
            return String(chosen.output[statusRange.lowerBound...])
                .components(separatedBy: .newlines)
                .first?.trimmed ?? chosen.output.trimmed
        }
        return chosen.output.trimmed
    }

    // MARK: - VM library

    func listDevices() -> [VirtualDevice] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: paths.libraryRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap(scanBundle).sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning && !$1.isRunning }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func scanBundle(_ bundleURL: URL) -> VirtualDevice? {
        let configURL = bundleURL.appendingPathComponent("config.plist")
        guard let data = try? Data(contentsOf: configURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let config = plist as? [String: Any]
        else { return nil }

        let cpu = (config["cpuCount"] as? NSNumber)?.intValue ?? 0
        let memory = (config["memorySize"] as? NSNumber)?.int64Value ?? 0
        let diskName = config["diskImage"] as? String ?? "Disk.img"
        let diskURL = bundleURL.appendingPathComponent(diskName)
        let attrs = try? FileManager.default.attributesOfItem(atPath: diskURL.path)
        let diskSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        let networkDict = config["networkConfig"] as? [String: Any]
        let network = NetworkReport(
            mode: networkDict?["mode"] as? String ?? "nat",
            macAddress: networkDict?["macAddress"] as? String,
            bridgeInterface: networkDict?["bridgeInterface"] as? String
        )

        let restoreURL = bundleURL.appendingPathComponent("restore-info.json")
        let restoreInfo = try? JSONDecoder().decode(
            RestoreInfoReport.self,
            from: Data(contentsOf: restoreURL)
        )
        let udid = readFirstLine(bundleURL.appendingPathComponent("udid.txt"))
            ?? readFirstLine(bundleURL.appendingPathComponent("udid-prediction.txt"))

        let pids = runningPIDs(for: diskURL)
        let metadata = loadDeviceMetadata(from: bundleURL)
        return VirtualDevice(
            name: bundleURL.lastPathComponent,
            cpuCount: cpu,
            memoryMB: Int(memory / 1_048_576),
            diskSizeBytes: diskSize,
            network: network,
            restoreInfo: restoreInfo,
            udid: udid,
            bundleURL: bundleURL,
            diskURL: diskURL,
            isRunning: !pids.isEmpty,
            isPaused: !pids.isEmpty && pids.allSatisfy(isProcessPaused),
            hardwareProfileID: metadata?.hardwareProfileID,
            networkConfiguration: metadata?.network,
            audioConfiguration: metadata?.audio,
            isolationPolicy: metadata?.isolation
        )
    }

    private func loadDeviceMetadata(from bundleURL: URL) -> LabDeviceMetadata? {
        let url = bundleURL.appendingPathComponent("lab-metadata.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(LabDeviceMetadata.self, from: data)
    }

    private func saveDeviceMetadata(_ metadata: LabDeviceMetadata, to bundleURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(
            to: bundleURL.appendingPathComponent("lab-metadata.json"),
            options: .atomic
        )
    }

    private func readFirstLine(_ url: URL) -> String? {
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return value.components(separatedBy: .newlines).first?.trimmed.nilIfEmpty
    }

    private func runningPIDs(for diskURL: URL) -> [Int32] {
        guard FileManager.default.fileExists(atPath: diskURL.path) else { return [] }
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-t", "--", diskURL.path],
            timeout: 5
        )
        guard result.succeeded else { return [] }
        return result.output
            .components(separatedBy: .newlines)
            .compactMap { Int32($0.trimmed) }
    }

    private func isProcessPaused(_ pid: Int32) -> Bool {
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-o", "state=", "-p", String(pid)],
            timeout: 5
        )
        return result.succeeded && result.output.trimmed.hasPrefix("T")
    }

    // MARK: - Backend operations

    func runCLI(
        _ arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = 3_600,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult {
        guard let binary = resolveBinary() else {
            return CommandResult(
                executable: "vphone-cli",
                arguments: arguments,
                output: "vphone-cli is not installed",
                exitCode: 127
            )
        }
        let operationID = UUID()
        let control = ProcessControl()
        activeControls[operationID] = control
        defer { activeControls.removeValue(forKey: operationID) }
        return await ProcessExecutor.runAsync(
            executable: binary,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: ["VPHONE_LIBRARY_ROOT": paths.libraryRoot.path],
            timeout: timeout,
            control: control,
            onLine: onLine
        )
    }

    func cancelAllOperations() {
        for control in activeControls.values { control.cancel() }
    }

    func storageCheck(requiredBytes: Int64) -> StorageCheck {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        let values = try? paths.dataRoot.resourceValues(forKeys: keys)
        let important = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let fallback = Int64(values?.volumeAvailableCapacity ?? 0)
        return StorageCheck(
            availableBytes: important > 0 ? important : fallback,
            requiredBytes: requiredBytes
        )
    }

    private func insufficientStorageResult(_ check: StorageCheck, arguments: [String]) -> CommandResult {
        CommandResult(
            executable: "vphone-cli",
            arguments: arguments,
            output: "Insufficient storage: \(check.message)",
            exitCode: 75
        )
    }

    func launch(
        _ device: VirtualDevice,
        installPackage: URL? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult {
        if let installPackage {
            do { try stageVphoned(in: device.bundleURL) }
            catch {
                return CommandResult(
                    executable: "vphone-cli",
                    arguments: [],
                    output: "Could not stage vphoned: \(error.localizedDescription)",
                    exitCode: 1
                )
            }
            let variant = device.restoreInfo?.variant ?? "regular"
            return await runCLI(
                [
                    "boot",
                    "--config", device.bundleURL.appendingPathComponent("config.plist").path,
                    "--variant", variant,
                    "--install-ipa", installPackage.path,
                ],
                currentDirectory: device.bundleURL,
                timeout: nil,
                onLine: onLine
            )
        }
        return await runCLI(
            ["vm", "launch", device.name, "--library-root", paths.libraryRoot.path],
            currentDirectory: device.bundleURL,
            timeout: nil,
            onLine: onLine
        )
    }

    func pause(
        _ device: VirtualDevice,
        onLine: @escaping @Sendable (String) -> Void
    ) -> CommandResult {
        signalVM(device, signal: SIGSTOP, action: "pause", onLine: onLine)
    }

    func resume(
        _ device: VirtualDevice,
        onLine: @escaping @Sendable (String) -> Void
    ) -> CommandResult {
        signalVM(device, signal: SIGCONT, action: "resume", onLine: onLine)
    }

    private func signalVM(
        _ device: VirtualDevice,
        signal: Int32,
        action: String,
        onLine: @Sendable (String) -> Void
    ) -> CommandResult {
        let pids = runningPIDs(for: device.diskURL)
        guard !pids.isEmpty else {
            let message = "\(device.name) is not running"
            onLine(message)
            return CommandResult(executable: "/bin/kill", arguments: [], output: message, exitCode: 1)
        }
        var failures: [Int32] = []
        for pid in pids where kill(pid, signal) != 0 { failures.append(pid) }
        let message = failures.isEmpty
            ? "\(action.capitalized)d \(device.name) (\(pids.count) process\(pids.count == 1 ? "" : "es"))"
            : "Could not \(action) process IDs: \(failures.map(String.init).joined(separator: ", "))"
        onLine(message)
        return CommandResult(
            executable: "/bin/kill",
            arguments: ["-\(signal)"] + pids.map(String.init),
            output: message,
            exitCode: failures.isEmpty ? 0 : 1
        )
    }

    private func stageVphoned(in bundleURL: URL) throws {
        let destination = bundleURL.appendingPathComponent(".vphoned.signed")
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["VPHONE_VPHONED_PATH"],
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let binary = resolveBinary() {
            let binaryDirectory = binary.deletingLastPathComponent()
            candidates += [
                binaryDirectory.appendingPathComponent("vphoned.signed"),
                binaryDirectory.deletingLastPathComponent()
                    .appendingPathComponent("Resources/vphoned.signed"),
                binaryDirectory.deletingLastPathComponent()
                    .appendingPathComponent("vphoned.signed"),
            ]
        }
        candidates.append(
            URL(fileURLWithPath: "/Applications/vphone-cli.app/Contents/Resources/vphoned.signed")
        )
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func stop(_ device: VirtualDevice, onLine: @escaping @Sendable (String) -> Void) async -> CommandResult {
        if device.isPaused {
            let resumed = signalVM(device, signal: SIGCONT, action: "resume before stopping", onLine: onLine)
            guard resumed.succeeded else { return resumed }
        }
        return await runCLI(
            ["vm", "stop", device.name, "--library-root", paths.libraryRoot.path],
            onLine: onLine
        )
    }

    func createVM(
        request: VMCreationRequest,
        onProgress: @escaping LabProgressHandler,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult {
        let name = request.name
        let iphoneIPSW = request.iphoneFirmware?.url
        let cloudOSIPSW = request.cloudOSFirmware?.url
        onProgress(LabProgressEvent(
            operationID: request.operationID,
            kind: .create,
            phase: .validating,
            fractionCompleted: 0.05,
            message: "Validating firmware and \(request.hardwareProfile.name)"
        ))
        var arguments = [
            "vm", "create", name,
            "--variant", request.variant.rawValue,
            "--disk-size", String(request.diskSizeGB),
            "--root-popup",
            "--library-root", paths.libraryRoot.path,
        ]
        if let iphoneIPSW { arguments += ["--iphone-source", iphoneIPSW.path] }
        if let cloudOSIPSW { arguments += ["--cloudos-source", cloudOSIPSW.path] }
        let sourceBytes = [iphoneIPSW, cloudOSIPSW]
            .compactMap { $0 }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(Int64(0)) { $0 + Int64($1) }
        let minimumWorkspace = Int64(15) * 1_073_741_824
        let check = storageCheck(requiredBytes: minimumWorkspace + sourceBytes)
        guard check.isSufficient else { return insufficientStorageResult(check, arguments: arguments) }
        onProgress(LabProgressEvent(
            operationID: request.operationID,
            kind: .create,
            phase: .preparing,
            fractionCompleted: 0.1,
            message: "Preparing VM storage"
        ))
        let progressLine: @Sendable (String) -> Void = { line in
            onLine(line)
            let lower = line.lowercased()
            let phase: LabOperationPhase?
            let fraction: Double?
            if lower.contains("download") {
                phase = .downloading; fraction = 0.25
            } else if lower.contains("restore") {
                phase = .restoring; fraction = 0.5
            } else if lower.contains("patch") {
                phase = .patching; fraction = 0.7
            } else if lower.contains("boot") {
                phase = .booting; fraction = 0.85
            } else {
                phase = nil; fraction = nil
            }
            if let phase {
                onProgress(LabProgressEvent(
                    operationID: request.operationID,
                    kind: .create,
                    phase: phase,
                    fractionCompleted: fraction,
                    message: line
                ))
            }
        }
        let result = await runCLI(arguments, onLine: progressLine)
        if result.succeeded {
            let metadata = LabDeviceMetadata(
                schemaVersion: 1,
                hardwareProfileID: request.hardwareProfile.id,
                network: request.network,
                audio: request.audio,
                isolation: request.isolation,
                updatedAt: .now
            )
            try? saveDeviceMetadata(metadata, to: paths.libraryRoot.appendingPathComponent(name))
        }
        onProgress(LabProgressEvent(
            operationID: request.operationID,
            kind: .create,
            phase: result.succeeded ? .completed : (result.cancelled ? .cancelled : .failed),
            fractionCompleted: result.succeeded ? 1 : nil,
            message: result.succeeded ? "Virtual device created" : "Virtual device creation failed"
        ))
        return result
    }

    func clone(
        _ device: VirtualDevice,
        as newName: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult {
        await runCLI(
            ["vm", "clone", device.name, newName, "--library-root", paths.libraryRoot.path],
            onLine: onLine
        )
    }

    func deleteVM(_ device: VirtualDevice, onLine: @escaping @Sendable (String) -> Void) async -> CommandResult {
        await runCLI(
            ["vm", "delete", device.name, "--force", "--library-root", paths.libraryRoot.path],
            onLine: onLine
        )
    }

    func updateConfiguration(
        request: VMConfigurationRequest,
        onProgress: @escaping LabProgressHandler,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult {
        onProgress(LabProgressEvent(
            operationID: request.operationID,
            kind: .configure,
            phase: .preparing,
            fractionCompleted: 0.2,
            message: "Applying backend configuration"
        ))
        let result = await runCLI(
            [
                "vm", "config", request.device.name,
                "--cpu", String(request.cpu),
                "--memory", String(request.memoryMB),
                "--network", request.network.mode.backendValue,
                "--library-root", paths.libraryRoot.path,
            ],
            onLine: onLine
        )
        if result.succeeded {
            let metadata = LabDeviceMetadata(
                schemaVersion: 1,
                hardwareProfileID: request.hardwareProfileID,
                network: request.network,
                audio: request.audio,
                isolation: request.isolation,
                updatedAt: .now
            )
            try? saveDeviceMetadata(metadata, to: request.device.bundleURL)
        }
        onProgress(LabProgressEvent(
            operationID: request.operationID,
            kind: .configure,
            phase: result.succeeded ? .completed : .failed,
            fractionCompleted: result.succeeded ? 1 : nil,
            message: result.succeeded ? "Configuration applied" : "Configuration failed"
        ))
        return result
    }

    // MARK: - Snapshots / backups

    func loadSnapshots() -> [SnapshotRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: paths.snapshotsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded: [SnapshotRecord] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SnapshotRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(SnapshotRecord.self, from: data)
            }
        return decoded
            .map { record in
                var copy = record
                let attrs = try? fm.attributesOfItem(atPath: record.archivePath)
                copy.sizeBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? record.sizeBytes
                return copy
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func createSnapshot(
        of device: VirtualDevice,
        named snapshotName: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> (CommandResult, SnapshotRecord?) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: .now)
        let base = "\(NameSanitizer.fileComponent(device.name))-\(NameSanitizer.fileComponent(snapshotName))-\(stamp)"
        let archive = paths.snapshotsRoot.appendingPathComponent(base).appendingPathExtension("tgz")
        let diskValues = try? device.diskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        let allocatedDisk = Int64(diskValues?.totalFileAllocatedSize ?? 0)
        let required = max(Int64(5) * 1_073_741_824, allocatedDisk)
        let check = storageCheck(requiredBytes: required)
        guard check.isSufficient else {
            return (
                insufficientStorageResult(check, arguments: ["vm", "export", device.name]),
                nil
            )
        }
        let result = await runCLI(
            [
                "vm", "export", device.name,
                "--out", archive.path,
                "--library-root", paths.libraryRoot.path,
            ],
            onLine: onLine
        )
        guard result.succeeded else { return (result, nil) }

        let attrs = try? FileManager.default.attributesOfItem(atPath: archive.path)
        let digest = try? sha256(of: archive)
        let record = SnapshotRecord(
            id: UUID(),
            name: snapshotName,
            sourceVM: device.name,
            createdAt: .now,
            archivePath: archive.path,
            sizeBytes: (attrs?[.size] as? NSNumber)?.int64Value ?? 0,
            sha256: digest,
            lastVerifiedAt: digest == nil ? nil : .now,
            integrityStatus: digest == nil ? .unchecked : .verified
        )
        try? saveSnapshotRecord(record)
        return (result, record)
    }

    func restoreSnapshot(
        _ snapshot: SnapshotRecord,
        as newName: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult {
        let verification = verifySnapshot(snapshot)
        guard verification.status == .verified else {
            return CommandResult(
                executable: "vphone-cli",
                arguments: ["vm", "import", "--in", snapshot.archivePath],
                output: "Snapshot integrity check failed: \(verification.message)",
                exitCode: 74
            )
        }
        return await runCLI(
            [
                "vm", "import",
                "--in", snapshot.archivePath,
                "--name", newName,
                "--library-root", paths.libraryRoot.path,
            ],
            onLine: onLine
        )
    }

    func verifySnapshot(_ snapshot: SnapshotRecord) -> SnapshotVerification {
        var copy = snapshot
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshot.archivePath) else {
            copy.integrityStatus = .missing
            copy.lastVerifiedAt = .now
            try? saveSnapshotRecord(copy)
            return SnapshotVerification(snapshot: copy, status: .missing, message: "Archive is missing")
        }
        do {
            let digest = try sha256(of: snapshot.archiveURL)
            let status: SnapshotIntegrityStatus = snapshot.sha256 == nil || snapshot.sha256 == digest
                ? .verified : .changed
            copy.sha256 = snapshot.sha256 ?? digest
            copy.integrityStatus = status
            copy.lastVerifiedAt = .now
            try saveSnapshotRecord(copy)
            let message = status == .verified
                ? "SHA-256 verified"
                : "Archive checksum does not match its snapshot metadata"
            return SnapshotVerification(snapshot: copy, status: status, message: message)
        } catch {
            copy.integrityStatus = .changed
            copy.lastVerifiedAt = .now
            try? saveSnapshotRecord(copy)
            return SnapshotVerification(
                snapshot: copy,
                status: .changed,
                message: error.localizedDescription
            )
        }
    }

    private func saveSnapshotRecord(_ record: SnapshotRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let metadataURL = record.archiveURL.deletingPathExtension().appendingPathExtension("json")
        try encoder.encode(record).write(to: metadataURL, options: .atomic)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func deleteSnapshot(_ snapshot: SnapshotRecord) throws {
        let archive = snapshot.archiveURL
        let metadata = archive.deletingPathExtension().appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: archive.path) {
            try FileManager.default.removeItem(at: archive)
        }
        if FileManager.default.fileExists(atPath: metadata.path) {
            try FileManager.default.removeItem(at: metadata)
        }
    }

    // MARK: - Host control and diagnostics

    func captureScreenshot(_ device: VirtualDevice, destination: URL) -> ControlResponse {
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return sendControl(
            to: device,
            payload: ["t": "screenshot", "path": destination.path]
        )
    }

    func sendHardwareKey(_ device: VirtualDevice, name: String) -> ControlResponse {
        sendControl(to: device, payload: ["t": "key", "name": name, "screen": false])
    }

    func guestProtocolHandshake(for device: VirtualDevice) -> GuestProtocolHandshake {
        GuestProtocolNegotiator.negotiate(
            json: sendControlJSON(
                to: device,
                payload: [
                    "t": "capabilities",
                    "protocol_min": GuestProtocolNegotiator.supported.lowerBound,
                    "protocol_max": GuestProtocolNegotiator.supported.upperBound,
                    "screen": false,
                ]
            ).json
        )
    }

    private func sendControl(to device: VirtualDevice, payload: [String: Any]) -> ControlResponse {
        let response = sendControlJSON(to: device, payload: payload)
        guard let json = response.json else {
            return ControlResponse(
                succeeded: false,
                path: nil,
                error: response.error ?? "Control request failed",
                imageData: nil
            )
        }
        let imageData = (json["image"] as? String).flatMap { Data(base64Encoded: $0) }
        return ControlResponse(
            succeeded: json["ok"] as? Bool == true,
            path: json["path"] as? String,
            error: json["error"] as? String,
            imageData: imageData
        )
    }

    private func sendControlJSON(
        to device: VirtualDevice,
        payload: [String: Any]
    ) -> (json: [String: Any]?, error: String?) {
        let socket = device.bundleURL.appendingPathComponent("vphone.sock")
        guard FileManager.default.fileExists(atPath: socket.path) else {
            return (nil, "Host control socket is not available; boot the VM with its window visible")
        }
        guard var request = try? JSONSerialization.data(withJSONObject: payload) else {
            return (nil, "Could not encode control request")
        }
        request.append(0x0A)
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/nc"),
            arguments: ["-U", socket.path],
            standardInput: request,
            timeout: 20
        )
        let responseLine = result.output.components(separatedBy: .newlines)
            .last { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }
        guard let responseLine,
              let data = responseLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (nil, result.timedOut ? "Control request timed out" : result.output.trimmed)
        }
        return (json, json["error"] as? String)
    }

    func createDiagnosticBundle(
        for device: VirtualDevice,
        activityLog: String
    ) throws -> DiagnosticBundle {
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let createdAt = Date()
        let name = "\(NameSanitizer.fileComponent(device.name))-\(stampFormatter.string(from: createdAt))"
        let root = paths.stateRoot
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try activityLog.write(
            to: root.appendingPathComponent("activity.log"),
            atomically: true,
            encoding: .utf8
        )
        for fileName in ["config.plist", "restore-info.json", "udid.txt", "udid-prediction.txt"] {
            let source = device.bundleURL.appendingPathComponent(fileName)
            if fm.fileExists(atPath: source.path) {
                try? fm.copyItem(at: source, to: root.appendingPathComponent(fileName))
            }
        }

        let system = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/sbin/system_profiler"),
            arguments: ["SPSoftwareDataType", "SPHardwareDataType"],
            timeout: 60
        )
        try system.output.write(
            to: root.appendingPathComponent("host-system-profile.txt"),
            atomically: true,
            encoding: .utf8
        )

        let unified = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/log"),
            arguments: [
                "show", "--last", "15m", "--style", "compact",
                "--predicate", "process == \"vphone-cli\" OR eventMessage CONTAINS[c] \"vphone\"",
            ],
            timeout: 60
        )
        try unified.output.write(
            to: root.appendingPathComponent("host-unified.log"),
            atomically: true,
            encoding: .utf8
        )

        copyDiagnosticArtifacts(from: device.bundleURL, to: root.appendingPathComponent("guest-artifacts"))
        if device.isRunning {
            _ = captureScreenshot(device, destination: root.appendingPathComponent("screen.png"))
        }
        let limitations = """
        This bundle includes the manager activity stream, host unified logs, VM metadata,
        a screenshot when the host control socket was available, and log/crash artifacts
        already present in the VM bundle. Direct guest syslog/crash export requires a
        guest-agent capability that the current vphone host socket does not expose.
        """
        try limitations.write(
            to: root.appendingPathComponent("LIMITATIONS.txt"),
            atomically: true,
            encoding: .utf8
        )
        return DiagnosticBundle(id: UUID(), deviceName: device.name, url: root, createdAt: createdAt)
    }

    func performanceSample(for device: VirtualDevice) -> PerformanceSample {
        let pids = runningPIDs(for: device.diskURL)
        guard !pids.isEmpty else {
            return PerformanceSample(
                deviceName: device.name,
                cpuPercent: 0,
                residentMemoryBytes: 0,
                audioSampleRateHz: device.audioConfiguration?.sampleRateHz,
                source: "Host process counters (VM stopped)"
            )
        }
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-o", "%cpu=,rss=", "-p", pids.map(String.init).joined(separator: ",")],
            timeout: 10
        )
        var totalCPU = 0.0
        var totalRSSKB: Int64 = 0
        if result.succeeded {
            for line in result.output.components(separatedBy: .newlines) {
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                guard fields.count >= 2 else { continue }
                totalCPU += Double(fields[0]) ?? 0
                totalRSSKB += Int64(fields[1]) ?? 0
            }
        }
        let now = Date()
        let counters = processIOCounters(pids)
        let prior = previousIOCounters[device.id]
        previousIOCounters[device.id] = counters.map { ($0.read, $0.written, now) }
        let elapsed = prior.map { now.timeIntervalSince($0.timestamp) } ?? 0
        let readRate: Int64? = counters.flatMap { current in
            guard let prior, elapsed > 0, current.read >= prior.read else { return nil }
            return Int64(Double(current.read - prior.read) / elapsed)
        }
        let writeRate: Int64? = counters.flatMap { current in
            guard let prior, elapsed > 0, current.written >= prior.written else { return nil }
            return Int64(Double(current.written - prior.written) / elapsed)
        }
        let runtime = sendControlJSON(to: device, payload: ["t": "capabilities", "screen": false]).json
        let audioAvailable = runtime?["audio_output"] as? Bool == true
        return PerformanceSample(
            deviceName: device.name,
            cpuPercent: result.succeeded ? totalCPU : nil,
            residentMemoryBytes: result.succeeded ? totalRSSKB * 1_024 : nil,
            diskReadBytesPerSecond: readRate,
            diskWriteBytesPerSecond: writeRate,
            gpuPercent: nil,
            framesPerSecond: nil,
            audioSampleRateHz: audioAvailable ? device.audioConfiguration?.sampleRateHz : nil,
            source: "Host vphone process CPU, memory, and rusage disk-I/O counters"
        )
    }

    private func processIOCounters(_ pids: [Int32]) -> (read: UInt64, written: UInt64)? {
        var totalRead: UInt64 = 0
        var totalWritten: UInt64 = 0
        var collected = false
        for pid in pids {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                var raw: rusage_info_t? = UnsafeMutableRawPointer(pointer)
                return proc_pid_rusage(pid, RUSAGE_INFO_V4, &raw)
            }
            guard status == 0 else { continue }
            totalRead &+= info.ri_diskio_bytesread
            totalWritten &+= info.ri_diskio_byteswritten
            collected = true
        }
        return collected ? (totalRead, totalWritten) : nil
    }

    func exportGuestDiagnostics(
        for device: VirtualDevice,
        categories: [DiagnosticCategory],
        destination: URL
    ) -> DiagnosticExportResult {
        let requestedRoots = guestDiagnosticRoots(for: categories)
        guard !requestedRoots.isEmpty else {
            return DiagnosticExportResult(
                supported: true,
                categories: categories,
                outputURL: destination,
                message: "No guest diagnostic categories were selected"
            )
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return DiagnosticExportResult(
                supported: true,
                categories: categories,
                outputURL: nil,
                message: "Could not create diagnostic destination: \(error.localizedDescription)"
            )
        }

        var exported = 0
        var skipped = 0
        var errors: [String] = []
        for root in requestedRoots {
            exportGuestTree(
                device: device,
                guestRoot: root,
                guestPath: root,
                destinationRoot: destination.appendingPathComponent(NameSanitizer.fileComponent(root)),
                depth: 0,
                exported: &exported,
                skipped: &skipped,
                errors: &errors
            )
            if exported >= 200 { break }
        }
        let summary = "Exported \(exported) guest diagnostic file(s); skipped \(skipped)."
            + (errors.isEmpty ? "" : " \(errors.prefix(3).joined(separator: " • "))")
        try? summary.write(
            to: destination.appendingPathComponent("SUMMARY.txt"),
            atomically: true,
            encoding: .utf8
        )
        return DiagnosticExportResult(
            supported: !errors.contains(where: { $0.contains("unknown command") }),
            categories: categories,
            outputURL: exported > 0 ? destination : nil,
            message: summary
        )
    }

    private func guestDiagnosticRoots(for categories: [DiagnosticCategory]) -> [String] {
        var roots: [String] = []
        let selected = Set(categories)
        if !selected.isDisjoint(with: [.guestSystemLogs, .applicationLogs, .bootFailures]) {
            roots += ["/var/log", "/var/mobile/Library/Logs"]
        }
        if !selected.isDisjoint(with: [.appCrashes, .vmCrashes, .kernelPanics]) {
            roots += [
                "/var/mobile/Library/Logs/CrashReporter",
                "/Library/Logs/CrashReporter",
            ]
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0).inserted }
    }

    private func exportGuestTree(
        device: VirtualDevice,
        guestRoot: String,
        guestPath: String,
        destinationRoot: URL,
        depth: Int,
        exported: inout Int,
        skipped: inout Int,
        errors: inout [String]
    ) {
        guard depth <= 4, exported < 200 else { skipped += 1; return }
        let listing = sendControlJSON(
            to: device,
            payload: ["t": "guest_file_list", "path": guestPath, "screen": false]
        )
        guard let json = listing.json, json["ok"] as? Bool == true,
              let entries = json["entries"] as? [[String: Any]] else {
            if let error = listing.error, !error.isEmpty { errors.append("\(guestPath): \(error)") }
            return
        }
        let allowedExtensions = Set(["log", "txt", "crash", "ips", "panic", "plist", "json"])
        for entry in entries {
            guard exported < 200,
                  let name = entry["name"] as? String,
                  !name.isEmpty,
                  name != ".",
                  name != "..",
                  !name.contains("/") else { continue }
            let type = entry["type"] as? String ?? "file"
            let childGuest = guestPath + "/" + name
            if type == "dir" {
                exportGuestTree(
                    device: device,
                    guestRoot: guestRoot,
                    guestPath: childGuest,
                    destinationRoot: destinationRoot,
                    depth: depth + 1,
                    exported: &exported,
                    skipped: &skipped,
                    errors: &errors
                )
                continue
            }
            guard type == "file",
                  (entry["size"] as? NSNumber)?.int64Value ?? 0 <= 50 * 1_048_576,
                  allowedExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
            else { skipped += 1; continue }
            let relative = childGuest.replacingOccurrences(of: guestRoot + "/", with: "")
            let destination = destinationRoot.appendingPathComponent(relative)
            let response = sendControlJSON(
                to: device,
                payload: [
                    "t": "guest_file_get",
                    "path": childGuest,
                    "destination": destination.path,
                    "maximum_bytes": 50 * 1_048_576,
                    "screen": false,
                ]
            )
            if response.json?["ok"] as? Bool == true { exported += 1 }
            else {
                skipped += 1
                if let error = response.error { errors.append("\(childGuest): \(error)") }
            }
        }
    }

    private func copyDiagnosticArtifacts(from sourceRoot: URL, to destinationRoot: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let allowed = Set(["log", "crash", "ips"])
        for case let source as URL in enumerator {
            guard allowed.contains(source.pathExtension.lowercased()),
                  let values = try? source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 50 * 1_048_576
            else { continue }
            let relative = source.path.replacingOccurrences(of: sourceRoot.path + "/", with: "")
            let destination = destinationRoot.appendingPathComponent(relative)
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: source, to: destination)
        }
    }

    // MARK: - Firmware catalog

    func loadFirmware() -> [FirmwareImage] {
        var byPath: [String: FirmwareImage] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let catalogURL = paths.stateRoot.appendingPathComponent("firmware-catalog.json")
        if let data = try? Data(contentsOf: catalogURL),
           let records = try? decoder.decode([FirmwareImage].self, from: data) {
            for record in records where FileManager.default.fileExists(atPath: record.path) {
                byPath[record.path] = record
            }
        }

        if let cached = try? FileManager.default.contentsOfDirectory(
            at: paths.firmwareRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in cached where url.pathExtension.lowercased() == "ipsw" {
                if byPath[url.path] == nil { byPath[url.path] = FirmwareImage.inspect(url) }
            }
        }
        return byPath.values.sorted {
            ($0.version ?? $0.fileName).localizedStandardCompare($1.version ?? $1.fileName) == .orderedDescending
        }
    }

    func importFirmware(_ urls: [URL], kind: FirmwareKind) throws -> [FirmwareImage] {
        var records = loadFirmware()
        var known = Set(records.map(\.path))
        for url in urls where !known.contains(url.path) {
            var inspected = FirmwareImage.inspect(url, kind: kind)
            if let metadata = try? IPSWManifestInspector.inspect(url) {
                inspected.manifestMetadata = metadata
                inspected.version = metadata.productVersion ?? inspected.version
                inspected.build = metadata.productBuildVersion ?? inspected.build
                inspected.device = IPSWManifestInspector.preferredProductType(
                    from: metadata,
                    filenameDevice: inspected.device
                )
            }
            records.append(inspected)
            known.insert(url.path)
        }
        try saveFirmwareCatalog(records)
        return loadFirmware()
    }

    func validateFirmware(
        _ firmware: FirmwareImage,
        compatibility: CompatibilityManifest
    ) throws -> [FirmwareImage] {
        var records = loadFirmware()
        guard let index = records.firstIndex(where: { $0.path == firmware.path }) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let fm = FileManager.default
        var issues: [String] = []
        var hasBuildManifest = false
        var parsedBuildManifest = false
        var entryCount = 0
        var digest: String?
        let url = firmware.url

        guard fm.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        if url.pathExtension.lowercased() != "ipsw" {
            issues.append("File extension is not .ipsw")
        }
        if firmware.sizeBytes < 50 * 1_048_576 {
            issues.append("File is unexpectedly small for an IPSW")
        }

        let listing = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", url.path],
            timeout: 120
        )
        var entries: [String] = []
        if listing.succeeded {
            entries = listing.output.components(separatedBy: .newlines).filter { !$0.isEmpty }
            entryCount = entries.count
            hasBuildManifest = entries.contains { $0 == "BuildManifest.plist" || $0.hasSuffix("/BuildManifest.plist") }
            if !hasBuildManifest { issues.append("Archive does not contain BuildManifest.plist") }
        } else {
            issues.append("Archive could not be read as a ZIP/IPSW")
        }

        if hasBuildManifest {
            do {
                let metadata = try IPSWManifestInspector.inspect(url, archiveEntries: entries)
                parsedBuildManifest = true
                let filename = FirmwareFilenameParser.parse(firmware.fileName)
                if let filenameVersion = filename.version,
                   let manifestVersion = metadata.productVersion,
                   filenameVersion != manifestVersion {
                    issues.append("Filename iOS \(filenameVersion) differs from BuildManifest \(manifestVersion)")
                }
                if let filenameBuild = filename.build,
                   let manifestBuild = metadata.productBuildVersion,
                   filenameBuild != manifestBuild {
                    issues.append("Filename build \(filenameBuild) differs from BuildManifest \(manifestBuild)")
                }
                if let filenameDevice = filename.device,
                   !metadata.supportedProductTypes.isEmpty,
                   !metadata.supportedProductTypes.contains(filenameDevice) {
                    issues.append("Filename device \(filenameDevice) is not listed by BuildManifest")
                }
                records[index].manifestMetadata = metadata
                records[index].version = metadata.productVersion ?? records[index].version
                records[index].build = metadata.productBuildVersion ?? records[index].build
                records[index].device = IPSWManifestInspector.preferredProductType(
                    from: metadata,
                    filenameDevice: filename.device ?? records[index].device
                )
            } catch {
                issues.append(error.localizedDescription)
            }
        }

        digest = try sha256(of: url)
        let compatibilityStatus = compatibility.status(for: records[index])
        if compatibilityStatus == .unverified {
            issues.append("No matching entry exists in the compatibility manifest")
        } else if compatibilityStatus == .incompatible {
            issues.append("This firmware is marked incompatible")
        }

        let structurallyInvalid = !listing.succeeded
            || !hasBuildManifest
            || !parsedBuildManifest
            || url.pathExtension.lowercased() != "ipsw"
        let state: FirmwareValidationState = structurallyInvalid
            ? .invalid
            : (issues.isEmpty ? .valid : .warning)

        records[index].sha256 = digest
        if records[index].provenance == nil {
            records[index].provenance = .localImport(
                path: records[index].path,
                importedAt: records[index].importedAt
            )
        }
        records[index].provenance?.checksumSHA256 = digest
        records[index].provenance?.signingStatus = structurallyInvalid ? .invalid : .verifiedMetadata
        records[index].compatibilityStatus = compatibilityStatus
        records[index].validation = FirmwareValidation(
            state: state,
            checkedAt: .now,
            hasBuildManifest: hasBuildManifest,
            archiveEntryCount: entryCount,
            issues: issues
        )
        try saveFirmwareCatalog(records)
        return loadFirmware()
    }

    func updateFirmwareKind(_ firmware: FirmwareImage, kind: FirmwareKind) throws -> [FirmwareImage] {
        var records = loadFirmware()
        if let index = records.firstIndex(where: { $0.path == firmware.path }) {
            records[index].kind = kind
        }
        try saveFirmwareCatalog(records)
        return loadFirmware()
    }

    func forgetFirmware(_ firmware: FirmwareImage) throws -> [FirmwareImage] {
        let records = loadFirmware().filter { $0.path != firmware.path }
        try saveFirmwareCatalog(records)
        return records
    }

    private func saveFirmwareCatalog(_ records: [FirmwareImage]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(
            to: paths.stateRoot.appendingPathComponent("firmware-catalog.json"),
            options: .atomic
        )
    }

}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Substring {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
