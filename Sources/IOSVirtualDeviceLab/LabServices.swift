import CryptoKit
import Foundation

enum HardwareProfilesCatalog {
    static func load(paths: LabPaths) -> HardwareProfileCatalog {
        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("hardware-profiles.json"),
            URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent("Resources/hardware-profiles.json"),
            paths.stateRoot.appendingPathComponent("hardware-profiles.json"),
        ]
        for case let candidate? in candidates where fm.fileExists(atPath: candidate.path) {
            if let data = try? Data(contentsOf: candidate),
               let catalog = try? JSONDecoder().decode(HardwareProfileCatalog.self, from: data) {
                return catalog
            }
        }
        return .empty
    }
}

enum CompatibilityEvaluator {
    static func recommend(
        iphone: FirmwareImage,
        catalog: CompatibilityManifest,
        profiles: HardwareProfileCatalog,
        availableFirmware: [FirmwareImage]
    ) -> FirmwareRecommendation {
        let entry = catalog.entry(for: iphone)
        let status = entry?.status ?? .unverified
        let profile = profiles.recommended(for: iphone, entry: entry)
        let cloud = entry.flatMap { candidate in
            availableFirmware.first { image in
                guard image.kind == .cloudOS,
                      let expectedVersion = candidate.cloudOSVersion,
                      let version = image.version else { return false }
                let versionMatches = version == expectedVersion || version.hasPrefix(expectedVersion + ".")
                let buildMatches = candidate.cloudOSBuild == nil || candidate.cloudOSBuild == image.build
                return versionMatches && buildMatches
            }
        }

        var messages: [String] = []
        var decision: CompatibilityDecision = .allowed
        switch status {
        case .supported:
            messages.append("This firmware appears in the validated compatibility database.")
        case .experimental:
            decision = .warning
            messages.append("This firmware is experimental and may require unstable patches.")
        case .researching:
            decision = .warning
            messages.append("This firmware is a research target, not a supported configuration.")
        case .unverified:
            decision = .warning
            messages.append("No boot evidence exists for this firmware pairing.")
        case .incompatible:
            decision = .blocked
            messages.append("This firmware is marked incompatible by recorded evidence.")
        }
        if profile == nil {
            decision = .blocked
            messages.append("No hardware profile supports the detected device and iOS version.")
        } else if profile?.supports(version: iphone.version) == false {
            decision = .blocked
            messages.append("The recommended hardware profile does not support this iOS major version.")
        }
        if let expectedCloud = entry?.cloudOSVersion, cloud == nil {
            messages.append("Recommended cloudOS \(expectedCloud) is not imported; the backend may download it automatically.")
        }
        if let issues = entry?.knownIssues, !issues.isEmpty {
            messages.append(contentsOf: issues.map { "Known issue: \($0)" })
        }
        if let patches = entry?.requiredPatches, !patches.isEmpty {
            messages.append("Required patches: \(patches.joined(separator: ", "))")
        }
        return FirmwareRecommendation(
            decision: decision,
            status: status,
            hardwareProfile: profile,
            cloudOSFirmware: cloud,
            messages: messages
        )
    }

    static func evaluate(_ request: VMCreationRequest, compatibility: CompatibilityManifest) -> FirmwareRecommendation {
        guard let iphone = request.iphoneFirmware else {
            return FirmwareRecommendation(
                decision: request.hardwareProfile.status == .supported ? .allowed : .warning,
                status: .unverified,
                hardwareProfile: request.hardwareProfile,
                cloudOSFirmware: request.cloudOSFirmware,
                messages: ["The backend will select automatic firmware for \(request.hardwareProfile.name)."]
            )
        }

        let entry = compatibility.entry(for: iphone)
        var messages: [String] = []
        var decision: CompatibilityDecision = .allowed
        let status = entry?.status ?? iphone.compatibilityStatus ?? .unverified

        if iphone.validation?.state == .invalid {
            decision = .blocked
            messages.append("The selected IPSW failed archive validation.")
        }
        if iphone.device != nil && iphone.device != request.hardwareProfile.productType {
            decision = .blocked
            messages.append("IPSW device \(iphone.device ?? "unknown") does not match \(request.hardwareProfile.productType).")
        }
        if !request.hardwareProfile.supports(version: iphone.version) {
            decision = .blocked
            messages.append("\(request.hardwareProfile.name) does not cover iOS \(iphone.version ?? "unknown").")
        }
        if status == .incompatible {
            decision = .blocked
            messages.append("The compatibility database marks this pairing incompatible.")
        } else if status != .supported, decision != .blocked {
            decision = .warning
            messages.append("Compatibility status is \(status.displayName.lowercased()); explicit acknowledgement is required.")
        }

        if let expected = entry?.cloudOSVersion, let cloud = request.cloudOSFirmware {
            let versionMatches = cloud.version == expected || cloud.version?.hasPrefix(expected + ".") == true
            let buildMatches = entry?.cloudOSBuild == nil || entry?.cloudOSBuild == cloud.build
            if !versionMatches || !buildMatches {
                decision = .blocked
                messages.append("cloudOS does not match the required \(expected) pairing.")
            }
        }

        return FirmwareRecommendation(
            decision: decision,
            status: status,
            hardwareProfile: request.hardwareProfile,
            cloudOSFirmware: request.cloudOSFirmware,
            messages: messages
        )
    }
}

enum AppArtifactStore {
    static func root(paths: LabPaths) -> URL {
        paths.stateRoot.appendingPathComponent("App Artifacts", isDirectory: true)
    }

    static func load(paths: LabPaths) -> [AppArtifact] {
        decodeLabFile([AppArtifact].self, from: root(paths: paths).appendingPathComponent("catalog.json")) ?? []
    }

    static func importArtifact(_ source: URL, paths: LabPaths) throws -> [AppArtifact] {
        let fm = FileManager.default
        let root = root(paths: paths)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var records = load(paths: paths).filter { fm.fileExists(atPath: $0.path) }
        if records.contains(where: { $0.path == source.path }) { return records }

        let id = UUID()
        let destination = root.appendingPathComponent("\(id.uuidString)-\(source.lastPathComponent)")
        try fm.copyItem(at: source, to: destination)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let record = AppArtifact(
            id: id,
            name: source.deletingPathExtension().lastPathComponent,
            path: destination.path,
            importedAt: .now,
            sizeBytes: size,
            sha256: try sha256(of: destination)
        )
        records.insert(record, at: 0)
        try encodeLabFile(records, to: root.appendingPathComponent("catalog.json"))
        return records
    }

    static func remove(_ artifact: AppArtifact, paths: LabPaths) throws -> [AppArtifact] {
        if FileManager.default.fileExists(atPath: artifact.path) {
            try FileManager.default.removeItem(at: artifact.url)
        }
        let records = load(paths: paths).filter { $0.id != artifact.id }
        try encodeLabFile(records, to: root(paths: paths).appendingPathComponent("catalog.json"))
        return records
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum SnapshotRetentionStore {
    static func load(paths: LabPaths) -> SnapshotRetentionPolicy {
        decodeLabFile(
            SnapshotRetentionPolicy.self,
            from: paths.stateRoot.appendingPathComponent("snapshot-retention.json")
        ) ?? .standard
    }

    static func save(_ policy: SnapshotRetentionPolicy, paths: LabPaths) throws {
        try encodeLabFile(policy, to: paths.stateRoot.appendingPathComponent("snapshot-retention.json"))
    }
}

enum TestAssertionEvaluator {
    static func evaluate(
        _ assertions: [TestAssertion],
        guestReady: Bool,
        launch: CommandResult,
        screenshotPath: String?,
        diagnosticPath: String?,
        duration: TimeInterval
    ) -> [TestAssertionResult] {
        assertions.map { assertion in
            let passed: Bool
            let message: String
            switch assertion.kind {
            case .guestReady:
                passed = guestReady
                message = guestReady ? "Guest control connected" : "Guest control did not connect"
            case .launchSucceeded:
                passed = launch.succeeded
                message = launch.succeeded ? "Deployment command completed" : "Deployment exited with \(launch.exitCode)"
            case .screenshotCaptured:
                passed = screenshotPath != nil
                message = passed ? "Screenshot artifact exists" : "Screenshot was not captured"
            case .exitCodeZero:
                passed = launch.exitCode == 0
                message = "Backend exit code: \(launch.exitCode)"
            case .diagnosticsCollected:
                passed = diagnosticPath != nil
                message = passed ? "Diagnostic bundle collected" : "Diagnostic collection failed"
            case .maximumDuration:
                let limit = TimeInterval(assertion.expectedValue ?? "300") ?? 300
                passed = duration <= limit
                message = String(format: "%.1f seconds (limit %.1f)", duration, limit)
            }
            return TestAssertionResult(assertion: assertion, passed: passed, message: message)
        }
    }
}

enum TestReportStore {
    static func write(_ run: TestRunRecord, paths: LabPaths) throws -> URL {
        let root = paths.stateRoot
            .appendingPathComponent("Test Reports", isDirectory: true)
            .appendingPathComponent(run.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jsonURL = root.appendingPathComponent("result.json")
        try encodeLabFile(run, to: jsonURL)

        var markdown = "# \(run.name)\n\n"
        markdown += "- State: **\(run.state.rawValue.capitalized)**\n"
        markdown += "- Kind: \(run.kind.rawValue)\n"
        markdown += "- Created: \(ISO8601DateFormatter().string(from: run.createdAt))\n"
        if let package = run.packagePath { markdown += "- App: `\(package)`\n" }
        markdown += "\n| Virtual device | Result | Details |\n|---|---|---|\n"
        for result in run.results {
            markdown += "| \(result.deviceName) | \(result.state.rawValue) | \(result.message.replacingOccurrences(of: "|", with: "\\|")) |\n"
            if let assertionResults = result.assertionResults {
                for assertion in assertionResults {
                    markdown += "| ↳ \(assertion.assertion.kind.displayName) | \(assertion.passed ? "pass" : "fail") | \(assertion.message.replacingOccurrences(of: "|", with: "\\|")) |\n"
                }
            }
        }
        let markdownURL = root.appendingPathComponent("report.md")
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        return markdownURL
    }
}

enum DeveloperTools {
    static func inspect(paths: LabPaths) -> XcodeIntegrationStatus {
        let select = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcode-select"),
            arguments: ["-p"],
            timeout: 10
        )
        let version = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: ["-version"],
            timeout: 20
        )
        let helper = paths.stateRoot.appendingPathComponent("Developer Tools/vdl-deploy.sh")
        return XcodeIntegrationStatus(
            xcodePath: select.succeeded ? select.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            xcodebuildVersion: version.succeeded ? version.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            commandLineToolsReady: select.succeeded && version.succeeded,
            helperScriptURL: FileManager.default.fileExists(atPath: helper.path) ? helper : nil
        )
    }

    static func installHelper(paths: LabPaths, backendPath: String?) throws -> URL {
        let root = paths.stateRoot.appendingPathComponent("Developer Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("vdl-deploy.sh")
        let binary = backendPath ?? "/opt/homebrew/bin/vphone-cli"
        let script = """
        #!/bin/zsh
        set -euo pipefail
        if [[ $# -ne 2 ]]; then
          echo "usage: vdl-deploy.sh <virtual-device-name> <app.ipa|app.tipa>" >&2
          exit 64
        fi
        DEVICE_NAME="$1"
        APP_PACKAGE="$2"
        DEVICE_ROOT="\(paths.libraryRoot.path)/$DEVICE_NAME"
        exec "\(binary)" boot --config "$DEVICE_ROOT/config.plist" --install-ipa "$APP_PACKAGE"
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        return helper
    }
}

private func decodeLabFile<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? decoder.decode(type, from: data)
}

private func encodeLabFile<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: .atomic)
}
