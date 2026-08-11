import CryptoKit
import CommonCrypto
import Foundation

enum DiagnosticPrivacyStore {
    static func load(paths: LabPaths) -> DiagnosticPrivacyPolicy {
        let url = paths.stateRoot.appendingPathComponent("diagnostic-privacy.json")
        guard let data = try? Data(contentsOf: url),
              let policy = try? JSONDecoder().decode(DiagnosticPrivacyPolicy.self, from: data)
        else { return .standard }
        return policy
    }

    static func save(_ policy: DiagnosticPrivacyPolicy, paths: LabPaths) throws {
        let url = paths.stateRoot.appendingPathComponent("diagnostic-privacy.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(policy).write(to: url, options: .atomic)
    }
}

enum DiagnosticSanitizer {
    static func sanitize(
        source: URL,
        destination: URL,
        policy: DiagnosticPrivacyPolicy
    ) throws -> DiagnosticPrivacyPreview {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return DiagnosticPrivacyPreview(filesIncluded: 0, filesExcluded: 0, redactions: 0, totalBytes: 0, warnings: ["Bundle could not be enumerated"])
        }

        var included = 0
        var excluded = 0
        var redactions = 0
        var totalBytes: Int64 = 0
        var warnings: [String] = []
        let textExtensions = Set(["txt", "log", "json", "plist", "crash", "ips", "panic", "md", "xml"])
        let sourceComponents = source.resolvingSymlinksInPath().pathComponents
        for case let sourceFile as URL in enumerator {
            guard let values = try? sourceFile.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            let fileComponents = sourceFile.resolvingSymlinksInPath().pathComponents
            guard fileComponents.starts(with: sourceComponents) else {
                excluded += 1
                continue
            }
            let relative = fileComponents.dropFirst(sourceComponents.count).joined(separator: "/")
            let lower = relative.lowercased()
            let size = Int64(values.fileSize ?? 0)
            if size > policy.maximumFileBytes
                || (!policy.includeHostProfile && lower.contains("host-system-profile"))
                || (!policy.includeScreenshots && ["png", "jpg", "jpeg"].contains(sourceFile.pathExtension.lowercased())) {
                excluded += 1
                continue
            }
            let target = destination.appendingPathComponent(relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if textExtensions.contains(sourceFile.pathExtension.lowercased()),
               let text = try? String(contentsOf: sourceFile, encoding: .utf8) {
                let sanitized = redact(text, policy: policy)
                redactions += sanitized.count
                try sanitized.text.write(to: target, atomically: true, encoding: .utf8)
            } else {
                try fm.copyItem(at: sourceFile, to: target)
            }
            included += 1
            totalBytes += size
        }
        if redactions > 0 { warnings.append("\(redactions) sensitive value(s) were redacted") }
        if excluded > 0 { warnings.append("\(excluded) file(s) were excluded by the privacy policy") }
        let preview = DiagnosticPrivacyPreview(
            filesIncluded: included,
            filesExcluded: excluded,
            redactions: redactions,
            totalBytes: totalBytes,
            warnings: warnings
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preview).write(to: destination.appendingPathComponent("PRIVACY-PREVIEW.json"), options: .atomic)
        return preview
    }

    static func encryptedArchive(
        of directory: URL,
        destination: URL,
        passphrase: String
    ) throws -> URL {
        guard passphrase.count >= 12 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let temporaryZip = FileManager.default.temporaryDirectory
            .appendingPathComponent("vdl-diagnostic-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: temporaryZip) }
        let archive = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--sequesterRsrc", directory.path, temporaryZip.path],
            timeout: 600
        )
        guard archive.succeeded else { throw CocoaError(.fileWriteUnknown) }
        let plaintext = try Data(contentsOf: temporaryZip)
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let key = try derivedKey(passphrase: passphrase, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        var container = Data("VDLENC1".utf8)
        container.append(salt)
        container.append(combined)
        try container.write(to: destination, options: .atomic)
        return destination
    }

    static func decryptArchive(
        _ source: URL,
        destination: URL,
        passphrase: String
    ) throws -> URL {
        let container = try Data(contentsOf: source)
        let magic = Data("VDLENC1".utf8)
        guard container.count > magic.count + 16,
              container.prefix(magic.count) == magic else { throw CocoaError(.fileReadCorruptFile) }
        let saltRange = magic.count..<(magic.count + 16)
        let salt = container.subdata(in: saltRange)
        let sealedData = container.suffix(from: saltRange.upperBound)
        let box = try AES.GCM.SealedBox(combined: sealedData)
        let plaintext = try AES.GCM.open(box, using: derivedKey(passphrase: passphrase, salt: salt))
        try plaintext.write(to: destination, options: .atomic)
        return destination
    }

    private static func derivedKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = passphrase.withCString { passphrasePointer in
            salt.withUnsafeBytes { saltPointer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passphrasePointer,
                    strlen(passphrasePointer),
                    saltPointer.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    200_000,
                    &bytes,
                    bytes.count
                )
            }
        }
        guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        return SymmetricKey(data: bytes)
    }

    private static func redact(
        _ text: String,
        policy: DiagnosticPrivacyPolicy
    ) -> (text: String, count: Int) {
        var output = text
        var count = 0
        var patterns: [(String, String)] = []
        if policy.redactSecrets {
            patterns += [
                (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#, "Bearer <redacted>"),
                (#"(?i)\b(authorization|token|password|passwd|secret|api[_-]?key)\s*[:=]\s*[^\s,;]+"#, "$1=<redacted>"),
                (#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "<redacted-jwt>"),
            ]
        }
        if policy.redactPersonalData {
            let username = NSUserName()
            if !username.isEmpty {
                patterns.append((NSRegularExpression.escapedPattern(for: "/Users/\(username)"), "<home>"))
            }
            patterns += [
                (#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "<redacted-email>"),
                (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<redacted-ip>"),
            ]
        }
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            count += expression.numberOfMatches(in: output, range: range)
            output = expression.stringByReplacingMatches(in: output, range: range, withTemplate: replacement)
        }
        return (output, count)
    }
}

enum DiagnosticAnalyzer {
    private struct Rule {
        let expression: NSRegularExpression
        let classification: DiagnosticClassification
        let severity: DiagnosticSeverity
        let title: String
        let recommendation: String
    }

    static func analyze(_ bundle: URL) throws -> DiagnosticAnalysisReport {
        let rules = makeRules()
        var findings: [DiagnosticFinding] = []
        let fm = FileManager.default
        let textExtensions = Set(["txt", "log", "json", "crash", "ips", "panic", "md"])
        guard let enumerator = fm.enumerator(
            at: bundle,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { throw CocoaError(.fileReadUnknown) }
        for case let file as URL in enumerator {
            guard textExtensions.contains(file.pathExtension.lowercased()),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 10 * 1_048_576,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for rule in rules where rule.expression.firstMatch(in: text, range: range) != nil {
                guard !findings.contains(where: { $0.classification == rule.classification && $0.sourceFile == file.lastPathComponent }) else { continue }
                let evidence = text.components(separatedBy: .newlines)
                    .first { line in
                        let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
                        return rule.expression.firstMatch(in: line, range: lineRange) != nil
                    } ?? rule.title
                findings.append(DiagnosticFinding(
                    classification: rule.classification,
                    severity: rule.severity,
                    title: rule.title,
                    evidence: String(evidence.prefix(500)),
                    recommendation: rule.recommendation,
                    sourceFile: file.lastPathComponent
                ))
            }
        }
        if findings.isEmpty {
            findings.append(DiagnosticFinding(
                classification: .unknown,
                severity: .information,
                title: "No known failure signature detected",
                evidence: "The local deterministic rules did not match this sanitized bundle.",
                recommendation: "Review the timeline and preserved logs, or opt in to a trusted analyzer plugin."
            ))
        }
        let critical = findings.filter { $0.severity == .critical }.count
        let warning = findings.filter { $0.severity == .warning }.count
        let report = DiagnosticAnalysisReport(
            id: UUID(),
            bundlePath: bundle.path,
            createdAt: .now,
            analyzer: "Local deterministic rules v1",
            findings: findings,
            summary: "\(critical) critical, \(warning) warning, \(findings.count) total finding(s)"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: bundle.appendingPathComponent("ANALYSIS.json"), options: .atomic)
        return report
    }

    private static func makeRules() -> [Rule] {
        func rule(
            _ pattern: String,
            _ classification: DiagnosticClassification,
            _ severity: DiagnosticSeverity,
            _ title: String,
            _ recommendation: String
        ) -> Rule {
            Rule(
                expression: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                classification: classification,
                severity: severity,
                title: title,
                recommendation: recommendation
            )
        }
        return [
            rule("panic\\(|panicString|kernel panic", .kernelPanic, .critical, "Kernel panic signature", "Compare the panic component and boot phase with the compatibility database before changing patches."),
            rule("EXC_BAD_ACCESS|SIGABRT|Termination Reason", .appCrash, .warning, "Application crash signature", "Symbolicate the crash with the exact dSYM and inspect the terminating thread."),
            rule("restore failed|boot failed|failed to boot|no bootable", .bootFailure, .critical, "Boot or restore failure", "Verify IPSW BuildManifest identities, cloudOS pairing, disk capacity, and required patches."),
            rule("vphone.*(crash|terminated)|Virtual machine.*stopped", .vmCrash, .critical, "VM process failure", "Inspect host unified logs and confirm the research-guest policy and vphone signing state."),
            rule("jetsam|memory pressure|out of memory", .resourcePressure, .warning, "Memory pressure", "Lower matrix concurrency or raise the VM memory budget while preserving the host reserve."),
            rule("network.*(unreachable|timeout|failed)|connection refused", .networkFailure, .warning, "Network failure", "Confirm the selected NAT/bridged mode and test without proxy or isolation policies."),
            rule("audio.*(underrun|failed|unavailable)|sample rate", .audioFailure, .warning, "Audio pipeline warning", "Validate the host input/output devices and capture the configured sample rate and route."),
        ]
    }
}
