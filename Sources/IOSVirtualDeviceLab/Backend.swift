@preconcurrency import Foundation

final class StreamAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var completeOutput = ""
    private var pendingLine = ""
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        consume(String(decoding: data, as: UTF8.self))
    }

    func consume(_ text: String) {
        var completed: [String] = []
        lock.lock()
        completeOutput += text
        pendingLine += text
        let pieces = pendingLine.components(separatedBy: .newlines)
        if pieces.count > 1 {
            completed = Array(pieces.dropLast())
            pendingLine = pieces.last ?? ""
        }
        lock.unlock()
        for line in completed where !line.isEmpty { onLine(line) }
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
}

enum ProcessExecutor {
    static func run(
        executable: URL,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment additions: [String: String] = [:],
        standardInput: Data? = nil,
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let inputPipe = Pipe()
        let accumulator = StreamAccumulator(onLine: onLine)

        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = inputPipe
        process.environment = ProcessInfo.processInfo.environment.merging(additions) { _, new in new }

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            accumulator.consume(handle.availableData)
        }

        do {
            try process.run()
            if let standardInput {
                inputPipe.fileHandleForWriting.write(standardInput)
            }
            try? inputPipe.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            accumulator.consume("error: \(error.localizedDescription)\n")
            return CommandResult(
                executable: executable.path,
                arguments: arguments,
                output: accumulator.finish(),
                exitCode: 127
            )
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        accumulator.consume(outputPipe.fileHandleForReading.readDataToEndOfFile())
        let status: Int32 = process.terminationReason == .uncaughtSignal
            ? 128 + process.terminationStatus
            : process.terminationStatus
        return CommandResult(
            executable: executable.path,
            arguments: arguments,
            output: accumulator.finish(),
            exitCode: status
        )
    }

    static func runAsync(
        executable: URL,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment additions: [String: String] = [:],
        standardInput: Data? = nil,
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> CommandResult {
        await Task.detached(priority: .userInitiated) {
            run(
                executable: executable,
                arguments: arguments,
                currentDirectory: currentDirectory,
                environment: additions,
                standardInput: standardInput,
                onLine: onLine
            )
        }.value
    }
}

actor VPhoneBackend {
    let paths: LabPaths

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
            executable: URL(fileURLWithPath: "/usr/bin/sw_vers"), arguments: ["-productVersion"])
        let architecture = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/uname"), arguments: ["-m"])
        let model = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/sbin/sysctl"), arguments: ["-n", "hw.model"])
        let hypervisor = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/sbin/sysctl"), arguments: ["-n", "kern.hv_vmm_present"])
        let sip = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/csrutil"), arguments: ["status"])

        let research = researchGuestStatus()
        let binary = resolveBinary()
        let binaryCheck = binary.map { ProcessExecutor.run(executable: $0, arguments: ["--help"]) }

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
            standardInput: Data()
        )
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
            standardInput: Data("\(number)\n".utf8)
        )
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
            isRunning: isDiskOpen(diskURL)
        )
    }

    private func readFirstLine(_ url: URL) -> String? {
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return value.components(separatedBy: .newlines).first?.trimmed.nilIfEmpty
    }

    private func isDiskOpen(_ diskURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: diskURL.path) else { return false }
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-t", "--", diskURL.path]
        )
        return result.succeeded && !result.output.trimmed.isEmpty
    }

    // MARK: - Backend operations

    func runCLI(
        _ arguments: [String],
        currentDirectory: URL? = nil,
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
        return await ProcessExecutor.runAsync(
            executable: binary,
            arguments: arguments,
            currentDirectory: currentDirectory,
            environment: ["VPHONE_LIBRARY_ROOT": paths.libraryRoot.path],
            onLine: onLine
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
                onLine: onLine
            )
        }
        return await runCLI(
            ["vm", "launch", device.name, "--library-root", paths.libraryRoot.path],
            currentDirectory: device.bundleURL,
            onLine: onLine
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
        await runCLI(
            ["vm", "stop", device.name, "--library-root", paths.libraryRoot.path],
            onLine: onLine
        )
    }

    func createVM(
        name: String,
        variant: FirmwareVariant,
        diskSizeGB: Int,
        iphoneIPSW: URL?,
        cloudOSIPSW: URL?,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult {
        var arguments = [
            "vm", "create", name,
            "--variant", variant.rawValue,
            "--disk-size", String(diskSizeGB),
            "--root-popup",
            "--library-root", paths.libraryRoot.path,
        ]
        if let iphoneIPSW { arguments += ["--iphone-source", iphoneIPSW.path] }
        if let cloudOSIPSW { arguments += ["--cloudos-source", cloudOSIPSW.path] }
        return await runCLI(arguments, onLine: onLine)
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
        _ device: VirtualDevice,
        cpu: Int,
        memoryMB: Int,
        network: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult {
        await runCLI(
            [
                "vm", "config", device.name,
                "--cpu", String(cpu),
                "--memory", String(memoryMB),
                "--network", network,
                "--library-root", paths.libraryRoot.path,
            ],
            onLine: onLine
        )
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
        let record = SnapshotRecord(
            id: UUID(),
            name: snapshotName,
            sourceVM: device.name,
            createdAt: .now,
            archivePath: archive.path,
            sizeBytes: (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let metadataURL = archive.deletingPathExtension().appendingPathExtension("json")
        if let data = try? encoder.encode(record) { try? data.write(to: metadataURL, options: .atomic) }
        return (result, record)
    }

    func restoreSnapshot(
        _ snapshot: SnapshotRecord,
        as newName: String,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult {
        await runCLI(
            [
                "vm", "import",
                "--in", snapshot.archivePath,
                "--name", newName,
                "--library-root", paths.libraryRoot.path,
            ],
            onLine: onLine
        )
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
        let known = Set(records.map(\.path))
        for url in urls where !known.contains(url.path) {
            records.append(FirmwareImage.inspect(url, kind: kind))
        }
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
