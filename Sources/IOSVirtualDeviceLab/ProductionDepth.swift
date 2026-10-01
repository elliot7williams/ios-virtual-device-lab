import AppKit
import CryptoKit
import Foundation
import Security
import SQLite3

// MARK: - Shared production-depth contracts

enum ProductionDepthError: LocalizedError {
    case invalid(String)
    case command(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message), let .command(message), let .sqlite(message): message
        }
    }
}

struct ProductionGateCheck: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let passed: Bool
    let evidence: String
}

private enum ProductionDepthCoding {
    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct SemanticVersion: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let core = value.split(separator: "-").first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

// MARK: - 1. Guest companion package lifecycle

struct GuestCompanionManifest: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let identifier: String
    let version: String
    let protocolMinimum: Int
    let protocolMaximum: Int
    let payloadPath: String
    let payloadSHA256: String
    let supportedBackendIDs: [String]
}

struct ManagedGuestCompanion: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let identifier: String
    let version: String
    let protocolMinimum: Int
    let protocolMaximum: Int
    let payloadPath: String
    let payloadSHA256: String
    let installedAt: Date
    var active: Bool
    var replacedVersion: String?
}

enum GuestCompanionLifecycleAction: String, Codable, CaseIterable, Sendable {
    case imported
    case activated
    case deployed
    case verified
    case rolledBack
    case rejected
}

struct GuestCompanionLifecycleRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let occurredAt: Date
    let action: GuestCompanionLifecycleAction
    let identifier: String
    let version: String
    let deviceName: String?
    let succeeded: Bool
    let message: String
}

struct GuestCompanionDeploymentRequest: Codable, Hashable, Sendable {
    let id: UUID
    let identifier: String
    let version: String
    let payloadPath: String
    let payloadSHA256: String
}

struct GuestCompanionDeploymentResult: Codable, Hashable, Sendable {
    let requestID: UUID
    let deviceName: String
    let succeeded: Bool
    let installedVersion: String?
    let message: String
}

enum GuestCompanionLifecycleManager {
    static let supportedSchema = 1
    static let requiredProtocol = 3

    static func buildPackage(
        payload: URL,
        identifier: String,
        version: String,
        supportedBackendIDs: [String],
        outputRoot: URL
    ) throws -> URL {
        guard NameSanitizer.fileComponent(identifier) == identifier, !identifier.isEmpty,
              SemanticVersion(version) != nil, !supportedBackendIDs.isEmpty else {
            throw ProductionDepthError.invalid("A companion build needs a safe identifier, semantic version, and at least one backend ID.")
        }
        let values = try payload.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 64 * 1_024 * 1_024 else {
            throw ProductionDepthError.invalid("The companion payload must be a regular non-empty file no larger than 64 MiB.")
        }
        try SecureFilesystem.prepareDirectory(outputRoot, enforceExistingPermissions: false)
        let package = outputRoot.appendingPathComponent("\(identifier)-\(version).vdlcompanion", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: package.path) else {
            throw ProductionDepthError.invalid("A companion package already exists at \(package.path); choose another destination or version.")
        }
        try SecureFilesystem.prepareDirectory(package)
        do {
            let destination = package.appendingPathComponent("guest-agent.bin")
            try FileManager.default.copyItem(at: payload, to: destination)
            try SecureFilesystem.protectFile(destination)
            let manifest = GuestCompanionManifest(
                schemaVersion: supportedSchema, identifier: identifier, version: version,
                protocolMinimum: requiredProtocol, protocolMaximum: requiredProtocol,
                payloadPath: destination.lastPathComponent, payloadSHA256: try fileSHA256(destination),
                supportedBackendIDs: Array(Set(supportedBackendIDs)).sorted()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let manifestURL = package.appendingPathComponent("companion-manifest.json")
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
            try SecureFilesystem.protectFile(manifestURL)
            return package
        } catch {
            try? FileManager.default.removeItem(at: package)
            throw error
        }
    }

    static func validatePackage(at bundle: URL, backendID: String) throws -> (GuestCompanionManifest, URL) {
        let values = try bundle.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ProductionDepthError.invalid("A guest companion package must be a real directory, not a file or symbolic link.")
        }
        let manifestURL = bundle.appendingPathComponent("companion-manifest.json")
        let manifestSize = (try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard manifestSize > 0, manifestSize <= 1_048_576 else {
            throw ProductionDepthError.invalid("The companion manifest is missing, empty, or larger than 1 MiB.")
        }
        let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: GuestCompanionManifest
        do {
            manifest = try decoder.decode(GuestCompanionManifest.self, from: manifestData)
        } catch {
            throw ProductionDepthError.invalid("The companion manifest is not valid schema-v1 JSON: \(error.localizedDescription)")
        }
        guard manifest.schemaVersion == supportedSchema else {
            throw ProductionDepthError.invalid("Unsupported companion manifest schema \(manifest.schemaVersion).")
        }
        guard NameSanitizer.fileComponent(manifest.identifier) == manifest.identifier,
              !manifest.identifier.isEmpty,
              SemanticVersion(manifest.version) != nil else {
            throw ProductionDepthError.invalid("The companion identifier or semantic version is invalid.")
        }
        guard manifest.protocolMinimum <= requiredProtocol, manifest.protocolMaximum >= requiredProtocol else {
            throw ProductionDepthError.invalid("The companion does not support authenticated guest protocol v\(requiredProtocol).")
        }
        guard manifest.supportedBackendIDs.contains(backendID) else {
            throw ProductionDepthError.invalid("The companion does not declare support for backend \(backendID).")
        }
        guard !manifest.payloadPath.hasPrefix("/"),
              !manifest.payloadPath.split(separator: "/").contains("..") else {
            throw ProductionDepthError.invalid("The companion payload path escapes its package.")
        }
        let payload = bundle.appendingPathComponent(manifest.payloadPath).standardizedFileURL
        let root = bundle.standardizedFileURL.path + "/"
        guard payload.path.hasPrefix(root) else {
            throw ProductionDepthError.invalid("The companion payload resolves outside its package.")
        }
        let payloadValues = try payload.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard payloadValues.isRegularFile == true,
              payloadValues.isSymbolicLink != true,
              let payloadSize = payloadValues.fileSize,
              payloadSize > 0,
              payloadSize <= 64 * 1_024 * 1_024 else {
            throw ProductionDepthError.invalid("The companion payload must be a regular non-empty file no larger than 64 MiB.")
        }
        let digest = try fileSHA256(payload)
        guard digest.caseInsensitiveCompare(manifest.payloadSHA256) == .orderedSame else {
            throw ProductionDepthError.invalid("The companion payload SHA-256 does not match its manifest.")
        }
        return (manifest, payload)
    }

    static func install(
        package bundle: URL,
        backendID: String,
        existing: [ManagedGuestCompanion],
        paths: LabPaths
    ) throws -> ManagedGuestCompanion {
        let (manifest, payload) = try validatePackage(at: bundle, backendID: backendID)
        let root = paths.stateRoot
            .appendingPathComponent("Guest Companions", isDirectory: true)
            .appendingPathComponent(manifest.identifier, isDirectory: true)
            .appendingPathComponent(manifest.version, isDirectory: true)
        try SecureFilesystem.prepareDirectory(root)
        let destination = root.appendingPathComponent("payload")
        let normalizedDigest = manifest.payloadSHA256.lowercased()
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try fileSHA256(destination).caseInsensitiveCompare(normalizedDigest) == .orderedSame else {
                throw ProductionDepthError.invalid("An installed companion version exists with a different payload hash.")
            }
        } else {
            try FileManager.default.copyItem(at: payload, to: destination)
        }
        try SecureFilesystem.protectFile(destination)
        let previous = existing.first { $0.identifier == manifest.identifier && $0.active }
        return ManagedGuestCompanion(
            id: UUID(), identifier: manifest.identifier, version: manifest.version,
            protocolMinimum: manifest.protocolMinimum, protocolMaximum: manifest.protocolMaximum,
            payloadPath: destination.path, payloadSHA256: normalizedDigest,
            installedAt: .now, active: true, replacedVersion: previous?.version
        )
    }

    static func activate(
        _ package: ManagedGuestCompanion,
        in packages: [ManagedGuestCompanion]
    ) -> [ManagedGuestCompanion] {
        packages.map { item in
            var copy = item
            if item.identifier == package.identifier { copy.active = item.id == package.id }
            return copy
        }
    }

    static func rollback(
        _ package: ManagedGuestCompanion,
        in packages: [ManagedGuestCompanion]
    ) throws -> [ManagedGuestCompanion] {
        guard let replaced = package.replacedVersion,
              let target = packages.first(where: { $0.identifier == package.identifier && $0.version == replaced }),
              FileManager.default.fileExists(atPath: target.payloadPath),
              try fileSHA256(URL(fileURLWithPath: target.payloadPath)).caseInsensitiveCompare(target.payloadSHA256) == .orderedSame else {
            throw ProductionDepthError.invalid("No checksum-valid prior companion version is available for rollback.")
        }
        return activate(target, in: packages)
    }
}

// MARK: - 2. Signing and provisioning management

struct CodeSigningIdentityRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let commonName: String
    let valid: Bool
}

struct SigningProvisioningAssessment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let inspectedAt: Date
    let appPath: String
    let bundleIdentifier: String?
    let teamIdentifier: String?
    let signingAuthority: String?
    let profileName: String?
    let profileUUID: String?
    let profileExpiresAt: Date?
    let entitlements: [String: String]
    let signatureValid: Bool
    let provisioningValid: Bool
    let checks: [ProductionGateCheck]
    let stagedSignedAppPath: String?

    var passed: Bool { signatureValid && provisioningValid && checks.allSatisfy(\.passed) }
}

enum SigningProvisioningManager {
    static func identities() -> [CodeSigningIdentityRecord] {
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["find-identity", "-v", "-p", "codesigning"],
            timeout: 20, maximumOutputBytes: 1_048_576
        )
        return result.output.split(separator: "\n").compactMap { line in
            let text = String(line)
            guard let hashRange = text.range(of: #"[0-9A-Fa-f]{40}"#, options: .regularExpression),
                  let quoteStart = text.firstIndex(of: "\"") else { return nil }
            let after = text.index(after: quoteStart)
            guard let quoteEnd = text[after...].firstIndex(of: "\"") else { return nil }
            return CodeSigningIdentityRecord(
                id: String(text[hashRange]), commonName: String(text[after..<quoteEnd]),
                valid: !text.localizedCaseInsensitiveContains("REVOKED")
            )
        }
    }

    static func inspect(app: URL, stagedPath: String? = nil) -> SigningProvisioningAssessment {
        var checks: [ProductionGateCheck] = []
        let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isApp = app.pathExtension.lowercased() == "app" && values?.isDirectory == true && values?.isSymbolicLink != true
        checks.append(.init(id: "expanded-app", passed: isApp, evidence: isApp ? "Expanded .app bundle is a real directory." : "Select a non-symlink expanded .app bundle."))

        let infoURL = app.appendingPathComponent("Info.plist")
        let info = NSDictionary(contentsOf: infoURL) as? [String: Any]
        let bundleID = info?["CFBundleIdentifier"] as? String
        checks.append(.init(id: "bundle-id", passed: !(bundleID ?? "").isEmpty, evidence: bundleID.map { "Bundle identifier \($0)." } ?? "CFBundleIdentifier is missing."))

        let verify = isApp ? ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "--verbose=2", app.path],
            timeout: 60, maximumOutputBytes: 2_097_152
        ) : CommandResult(executable: "/usr/bin/codesign", arguments: [], output: "Not an app bundle.", exitCode: 1)
        checks.append(.init(id: "signature", passed: verify.succeeded, evidence: verify.succeeded ? "The code signature passes deep strict verification." : verify.output.trimmingCharacters(in: .whitespacesAndNewlines)))

        let details = isApp ? ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-d", "--verbose=4", app.path],
            timeout: 20, maximumOutputBytes: 1_048_576
        ).output : ""
        let team = value(after: "TeamIdentifier=", in: details)
        let authority = details.split(separator: "\n").map(String.init).first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst("Authority=".count)) }

        let entitlementResult = isApp ? ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-d", "--entitlements", ":-", app.path],
            timeout: 20, maximumOutputBytes: 2_097_152
        ) : CommandResult(executable: "/usr/bin/codesign", arguments: [], output: "", exitCode: 1)
        let entitlementPlist = plistDictionary(from: entitlementResult.output)
        let entitlements = entitlementPlist.reduce(into: [String: String]()) { result, pair in
            result[pair.key] = String(describing: pair.value)
        }

        let profileURL = app.appendingPathComponent("embedded.mobileprovision")
        var profile: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: profileURL.path) {
            let decoded = ProcessExecutor.run(
                executable: URL(fileURLWithPath: "/usr/bin/security"),
                arguments: ["cms", "-D", "-i", profileURL.path],
                timeout: 20, maximumOutputBytes: 4_194_304
            )
            if decoded.succeeded { profile = plistDictionary(from: decoded.output) }
        }
        let profileName = profile["Name"] as? String
        let profileUUID = profile["UUID"] as? String
        let expires = profile["ExpirationDate"] as? Date
        let profileEntitlements = profile["Entitlements"] as? [String: Any] ?? [:]
        let applicationIdentifier = profileEntitlements["application-identifier"] as? String
        let profileTeam = (profile["TeamIdentifier"] as? [String])?.first
        let hasProfile = !profile.isEmpty
        let profileNotExpired = expires.map { $0 > .now } ?? false
        let bundleMatches = if let bundleID, let applicationIdentifier {
            applicationIdentifier == "\(profileTeam ?? team ?? "").\(bundleID)"
                || applicationIdentifier.hasSuffix(".*")
                || applicationIdentifier.hasSuffix(".\(bundleID)")
        } else { false }
        let teamMatches = profileTeam != nil && team != nil && profileTeam == team
        checks.append(.init(id: "provisioning-profile", passed: hasProfile, evidence: hasProfile ? "Embedded profile \(profileName ?? profileUUID ?? "unnamed") was decoded." : "No decodable embedded.mobileprovision is present."))
        checks.append(.init(id: "profile-expiration", passed: profileNotExpired, evidence: expires.map { "Profile expires \($0.formatted())." } ?? "Profile expiration is unavailable."))
        checks.append(.init(id: "profile-bundle", passed: bundleMatches, evidence: bundleMatches ? "Provisioned application identifier matches the bundle." : "Provisioned application identifier does not match the bundle."))
        checks.append(.init(id: "profile-team", passed: teamMatches, evidence: teamMatches ? "Profile and signature team identifiers match." : "Profile and signature team identifiers do not match."))

        return SigningProvisioningAssessment(
            id: UUID(), inspectedAt: .now, appPath: app.path, bundleIdentifier: bundleID,
            teamIdentifier: team, signingAuthority: authority, profileName: profileName,
            profileUUID: profileUUID, profileExpiresAt: expires, entitlements: entitlements,
            signatureValid: verify.succeeded,
            provisioningValid: hasProfile && profileNotExpired && bundleMatches && teamMatches,
            checks: checks, stagedSignedAppPath: stagedPath
        )
    }

    static func stageAndSign(app: URL, identity: CodeSigningIdentityRecord, paths: LabPaths) throws -> SigningProvisioningAssessment {
        guard identity.valid, identities().contains(where: { $0.id == identity.id && $0.valid }) else {
            throw ProductionDepthError.invalid("The selected signing identity is unavailable or invalid.")
        }
        let sourceValues = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard app.pathExtension.lowercased() == "app", sourceValues.isDirectory == true, sourceValues.isSymbolicLink != true else {
            throw ProductionDepthError.invalid("Only a non-symlink expanded .app bundle can be staged for signing.")
        }
        let root = paths.stateRoot.appendingPathComponent("Signed Builds", isDirectory: true)
        try SecureFilesystem.prepareDirectory(root)
        let destination = root.appendingPathComponent("\(NameSanitizer.fileComponent(app.deletingPathExtension().lastPathComponent))-\(UUID().uuidString).app")
        let copy = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: [app.path, destination.path],
            timeout: 300, maximumOutputBytes: 2_097_152
        )
        guard copy.succeeded else { throw ProductionDepthError.command(copy.output) }
        let sign = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--deep", "--preserve-metadata=identifier,entitlements,requirements", "--sign", identity.id, destination.path],
            timeout: 300, maximumOutputBytes: 4_194_304
        )
        guard sign.succeeded else { throw ProductionDepthError.command(sign.output) }
        return inspect(app: destination, stagedPath: destination.path)
    }

    private static func value(after prefix: String, in text: String) -> String? {
        text.split(separator: "\n").map(String.init).first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    private static func plistDictionary(from text: String) -> [String: Any] {
        guard let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>") else { return [:] }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let data = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else { return [:] }
        return dictionary
    }
}

// MARK: - 3. Physical-device lifecycle and exclusive leases

struct PhysicalDeviceDetailRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let targetID: String
    let name: String
    let inspectedAt: Date
    let connected: Bool
    let paired: Bool
    let developerModeEnabled: Bool
    let ddiServicesReady: Bool
    let batteryPercent: Double?
    let thermalState: String?
    let productType: String?
    let osVersion: String?
    let checks: [ProductionGateCheck]

    var ready: Bool { connected && paired && developerModeEnabled && ddiServicesReady }
}

enum PhysicalDeviceLeaseState: String, Codable, Sendable { case active, released, expired, cancelled }

struct PhysicalDeviceLease: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let targetID: String
    let owner: String
    let acquiredAt: Date
    let expiresAt: Date
    var state: PhysicalDeviceLeaseState
}

enum PhysicalDeviceLifecycleService {
    static func acquireLease(
        targetID: String,
        owner: String,
        duration: TimeInterval,
        existing: [PhysicalDeviceLease],
        now: Date = .now
    ) throws -> PhysicalDeviceLease {
        guard !targetID.isEmpty, !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              duration >= 60, duration <= 24 * 60 * 60 else {
            throw ProductionDepthError.invalid("A physical-device lease needs a target, owner, and duration between 1 minute and 24 hours.")
        }
        let conflict = existing.contains { $0.targetID == targetID && $0.state == .active && $0.expiresAt > now }
        guard !conflict else { throw ProductionDepthError.invalid("This physical device already has an active exclusive lease.") }
        return PhysicalDeviceLease(
            id: UUID(), targetID: targetID, owner: owner, acquiredAt: now,
            expiresAt: now.addingTimeInterval(duration), state: .active
        )
    }

    static func normalize(_ leases: [PhysicalDeviceLease], now: Date = .now) -> [PhysicalDeviceLease] {
        leases.map { lease in
            var copy = lease
            if copy.state == .active && copy.expiresAt <= now { copy.state = .expired }
            return copy
        }
    }

    static func inspect(target: ExecutionTargetRecord, autoMountDDI: Bool = true) -> PhysicalDeviceDetailRecord {
        let targetID = target.id
        guard target.kind == .physical, !targetID.isEmpty, !targetID.hasPrefix("-") else {
            return unavailable(targetID: target.id, name: target.name, message: "A valid physical CoreDevice target is required.")
        }
        let details = runDeviceInfo(subcommand: "details", targetID: targetID, extra: [])
        let ddi = runDeviceInfo(subcommand: "ddiServices", targetID: targetID, extra: [autoMountDDI ? "--auto-mount-ddis" : "--no-auto-mount-ddis"])
        let flattened = flatten(details.object)
        let ddiFlattened = flatten(ddi.object)
        let connected = details.succeeded && truth(flattened, matching: ["connected", "available", "connectionstate"])
        let paired = truth(flattened, matching: ["paired", "pairingstate"]) || target.authorized
        let developer = truth(flattened, matching: ["developermode", "developermodestatus", "developermodeenabled"])
        let ddiReady = ddi.succeeded && (truth(ddiFlattened, matching: ["enabled", "mounted", "available", "ready"]) || !ddiFlattened.isEmpty)
        let battery = number(flattened, matching: ["battery", "batterypercent", "batterylevel"])
        let thermal = string(flattened, matching: ["thermalstate", "thermal"])
        let checks = [
            ProductionGateCheck(id: "connected", passed: connected, evidence: connected ? "CoreDevice can connect to the device." : details.message),
            .init(id: "paired", passed: paired, evidence: paired ? "CoreDevice pairing evidence is present." : "The Mac and device are not paired."),
            .init(id: "developer-mode", passed: developer, evidence: developer ? "Developer Mode is enabled." : "Developer Mode is not reported as enabled."),
            .init(id: "ddi", passed: ddiReady, evidence: ddiReady ? "Developer disk image services are available." : ddi.message),
        ]
        return PhysicalDeviceDetailRecord(
            id: UUID(), targetID: targetID, name: target.name, inspectedAt: .now,
            connected: connected, paired: paired, developerModeEnabled: developer,
            ddiServicesReady: ddiReady, batteryPercent: battery, thermalState: thermal,
            productType: target.productType, osVersion: target.osVersion, checks: checks
        )
    }

    static func pair(targetID: String) -> ProductionGateCheck {
        guard !targetID.isEmpty, !targetID.hasPrefix("-") else {
            return .init(id: "pair", passed: false, evidence: "A valid physical device identifier is required.")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("vdl-pair-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["devicectl", "manage", "pair", "--device", targetID, "--timeout", "60", "--json-output", output.path],
            timeout: 75, maximumOutputBytes: 2_097_152
        )
        return .init(id: "pair", passed: result.succeeded, evidence: result.succeeded ? "CoreDevice pairing completed." : result.output)
    }

    private static func unavailable(targetID: String, name: String, message: String) -> PhysicalDeviceDetailRecord {
        PhysicalDeviceDetailRecord(
            id: UUID(), targetID: targetID, name: name, inspectedAt: .now,
            connected: false, paired: false, developerModeEnabled: false, ddiServicesReady: false,
            batteryPercent: nil, thermalState: nil, productType: nil, osVersion: nil,
            checks: [.init(id: "target", passed: false, evidence: message)]
        )
    }

    private static func runDeviceInfo(subcommand: String, targetID: String, extra: [String]) -> (succeeded: Bool, object: Any?, message: String) {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("vdl-device-info-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["devicectl", "device", "info", subcommand, "--device", targetID] + extra + ["--timeout", "45", "--json-output", output.path],
            timeout: 60, maximumOutputBytes: 2_097_152
        )
        let data = try? Data(contentsOf: output)
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return (result.succeeded && object != nil, object, result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func flatten(_ object: Any?) -> [String: Any] {
        var values: [String: Any] = [:]
        func walk(_ item: Any, path: String) {
            if let dictionary = item as? [String: Any] {
                for (key, value) in dictionary { walk(value, path: path.isEmpty ? key : "\(path).\(key)") }
            } else if let array = item as? [Any] {
                for (index, value) in array.enumerated() { walk(value, path: "\(path).\(index)") }
            } else { values[path.lowercased()] = item }
        }
        if let object { walk(object, path: "") }
        return values
    }

    private static func matchingValue(_ values: [String: Any], keys: [String]) -> Any? {
        values.first { path, _ in keys.contains { path.hasSuffix($0.lowercased()) } }?.value
    }

    private static func truth(_ values: [String: Any], matching keys: [String]) -> Bool {
        guard let value = matchingValue(values, keys: keys) else { return false }
        if let boolean = value as? Bool { return boolean }
        let text = String(describing: value).lowercased()
        return ["true", "yes", "enabled", "paired", "connected", "available", "ready", "mounted"].contains(text)
    }

    private static func number(_ values: [String: Any], matching keys: [String]) -> Double? {
        let value = matchingValue(values, keys: keys)
        return (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    private static func string(_ values: [String: Any], matching keys: [String]) -> String? {
        matchingValue(values, keys: keys).map { String(describing: $0) }
    }
}

// MARK: - 4. Visual and accessibility regression testing

struct VisualMaskRect: Codable, Hashable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    func contains(x pointX: Int, y pointY: Int) -> Bool {
        pointX >= x && pointX < x + width && pointY >= y && pointY < y + height
    }
}

struct VisualRegressionReport: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let comparedAt: Date
    let baselinePath: String
    let candidatePath: String
    let baselineSHA256: String
    let candidateSHA256: String
    let width: Int
    let height: Int
    let comparedPixels: Int
    let changedPixels: Int
    let changedPercent: Double
    let meanAbsoluteError: Double
    let perChannelThreshold: Int
    let maximumChangedPercent: Double
    let passed: Bool
    let diffPath: String?
    let blockers: [String]
}

struct AccessibilityRegressionReport: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let comparedAt: Date
    let addedIdentifiers: [String]
    let removedIdentifiers: [String]
    let changedNodes: Int
    let passed: Bool
}

enum VisualRegressionEngine {
    private struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    static func compare(
        baseline: URL,
        candidate: URL,
        masks: [VisualMaskRect] = [],
        perChannelThreshold: Int = 8,
        maximumChangedPercent: Double = 0.5,
        outputRoot: URL
    ) throws -> VisualRegressionReport {
        guard (0...255).contains(perChannelThreshold), (0...100).contains(maximumChangedPercent) else {
            throw ProductionDepthError.invalid("Visual thresholds are outside their valid ranges.")
        }
        let left = try raster(from: baseline)
        let right = try raster(from: candidate)
        guard left.width == right.width, left.height == right.height else {
            return VisualRegressionReport(
                id: UUID(), comparedAt: .now, baselinePath: baseline.path, candidatePath: candidate.path,
                baselineSHA256: try fileSHA256(baseline), candidateSHA256: try fileSHA256(candidate),
                width: right.width, height: right.height, comparedPixels: 0, changedPixels: 0,
                changedPercent: 100, meanAbsoluteError: 1, perChannelThreshold: perChannelThreshold,
                maximumChangedPercent: maximumChangedPercent, passed: false, diffPath: nil,
                blockers: ["Baseline and candidate dimensions differ: \(left.width)×\(left.height) vs \(right.width)×\(right.height)."]
            )
        }
        var changed = 0
        var compared = 0
        var absoluteTotal = 0
        var diff = [UInt8](repeating: 0, count: left.bytes.count)
        for y in 0..<left.height {
            for x in 0..<left.width {
                let offset = (y * left.width + x) * 4
                if masks.contains(where: { $0.contains(x: x, y: y) }) {
                    diff[offset] = 90; diff[offset + 1] = 90; diff[offset + 2] = 90; diff[offset + 3] = 110
                    continue
                }
                compared += 1
                let deltas = (0..<3).map { abs(Int(left.bytes[offset + $0]) - Int(right.bytes[offset + $0])) }
                absoluteTotal += deltas.reduce(0, +)
                if deltas.max() ?? 0 > perChannelThreshold {
                    changed += 1
                    diff[offset] = 255; diff[offset + 1] = 0; diff[offset + 2] = 40; diff[offset + 3] = 255
                } else {
                    let luminance = UInt8((Int(right.bytes[offset]) + Int(right.bytes[offset + 1]) + Int(right.bytes[offset + 2])) / 6)
                    diff[offset] = luminance; diff[offset + 1] = luminance; diff[offset + 2] = luminance; diff[offset + 3] = 180
                }
            }
        }
        guard compared > 0 else { throw ProductionDepthError.invalid("Every pixel is masked; no visual comparison can be performed.") }
        let changedPercent = Double(changed) / Double(compared) * 100
        let mean = Double(absoluteTotal) / Double(compared * 3 * 255)
        try SecureFilesystem.prepareDirectory(outputRoot)
        let diffURL = outputRoot.appendingPathComponent("visual-diff-\(UUID().uuidString).png")
        try writePNG(width: left.width, height: left.height, bytes: diff, to: diffURL)
        return VisualRegressionReport(
            id: UUID(), comparedAt: .now, baselinePath: baseline.path, candidatePath: candidate.path,
            baselineSHA256: try fileSHA256(baseline), candidateSHA256: try fileSHA256(candidate),
            width: left.width, height: left.height, comparedPixels: compared, changedPixels: changed,
            changedPercent: changedPercent, meanAbsoluteError: mean,
            perChannelThreshold: perChannelThreshold, maximumChangedPercent: maximumChangedPercent,
            passed: changedPercent <= maximumChangedPercent, diffPath: diffURL.path, blockers: []
        )
    }

    static func compareAccessibility(_ baseline: AccessibilityNode?, _ candidate: AccessibilityNode?) -> AccessibilityRegressionReport {
        func flatten(_ node: AccessibilityNode?) -> [String: AccessibilityNode] {
            guard let node else { return [:] }
            var output: [String: AccessibilityNode] = [:]
            func walk(_ item: AccessibilityNode, path: String) {
                let key = item.id.isEmpty ? "\(path)/\(item.role):\(item.label ?? "")" : item.id
                output[key] = item
                for (index, child) in item.children.enumerated() { walk(child, path: "\(path)/\(index)") }
            }
            walk(node, path: "root")
            return output
        }
        let left = flatten(baseline)
        let right = flatten(candidate)
        let added = Array(Set(right.keys).subtracting(left.keys)).sorted()
        let removed = Array(Set(left.keys).subtracting(right.keys)).sorted()
        let changed = Set(left.keys).intersection(right.keys).filter { left[$0] != right[$0] }.count
        return AccessibilityRegressionReport(
            id: UUID(), comparedAt: .now, addedIdentifiers: added,
            removedIdentifiers: removed, changedNodes: changed,
            passed: added.isEmpty && removed.isEmpty && changed == 0
        )
    }

    private static func raster(from url: URL) throws -> Raster {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= 100 * 1_024 * 1_024,
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ProductionDepthError.invalid("The image is missing, too large, or cannot be decoded.")
        }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0, width * height <= 20_000_000 else {
            throw ProductionDepthError.invalid("The image dimensions exceed the 20-megapixel comparison limit.")
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ProductionDepthError.invalid("A normalized image buffer could not be created.") }
        context.interpolationQuality = .none
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Raster(width: width, height: height, bytes: bytes)
    }

    private static func writePNG(width: Int, height: Int, bytes: [UInt8], to url: URL) throws {
        var mutable = bytes
        guard let context = CGContext(
            data: &mutable, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw ProductionDepthError.invalid("The visual diff image could not be encoded.")
        }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw ProductionDepthError.invalid("The visual diff PNG could not be encoded.")
        }
        try png.write(to: url, options: [.atomic])
        try SecureFilesystem.protectFile(url)
    }
}

// MARK: - 5. Typed network and audio fault injection

enum FaultInjectionDomain: String, Codable, CaseIterable, Identifiable, Sendable {
    case network
    case audio
    var id: String { rawValue }
}

enum AudioFaultKind: String, Codable, CaseIterable, Sendable {
    case interruption
    case routeChange
    case mediaServicesReset
}

struct FaultInjectionScenario: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let domain: FaultInjectionDomain
    let durationSeconds: Int
    let latencyMilliseconds: Int?
    let packetLossPercent: Double?
    let offline: Bool
    let proxyURL: String?
    let audioFault: AudioFaultKind?
    let audioRoute: String?
}

struct FaultInjectionResult: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let scenarioID: UUID
    let deviceName: String
    let startedAt: Date
    let completedAt: Date
    let succeeded: Bool
    let message: String
}

enum FaultInjectionGate {
    static func validate(scenario: FaultInjectionScenario, handshake: GuestProtocolHandshake) -> [String] {
        var blockers: [String] = []
        guard handshake.status == .compatible, handshake.negotiatedVersion == 3,
              handshake.authenticated, handshake.replayProtected else {
            return ["Fault injection requires authenticated, replay-protected guest protocol v3."]
        }
        if !handshake.capabilities.contains(.faultInjection) {
            blockers.append("The guest did not advertise the fault_injection capability.")
        }
        if scenario.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blockers.append("The scenario needs a name.") }
        if !(1...3_600).contains(scenario.durationSeconds) { blockers.append("Fault duration must be between 1 second and 1 hour.") }
        if let latency = scenario.latencyMilliseconds, !(0...60_000).contains(latency) { blockers.append("Network latency is outside 0–60000 ms.") }
        if let loss = scenario.packetLossPercent, !(0...100).contains(loss) { blockers.append("Packet loss is outside 0–100 percent.") }
        if let proxy = scenario.proxyURL {
            guard let url = URL(string: proxy), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                blockers.append("Proxy URL must use HTTP or HTTPS and include a host.")
                return blockers
            }
        }
        if scenario.domain == .audio && scenario.audioFault == nil { blockers.append("An audio fault kind is required.") }
        return blockers
    }
}

// MARK: - 6. Mutually authenticated fleet transport

struct MTLSEnrollmentConfiguration: Codable, Hashable, Sendable {
    var endpoint: String
    var agentID: String
    var clientIdentityLabel: String
    var serverCertificateSHA256Pins: [String]
    var requestTimeoutSeconds: Int
}

struct MTLSEnrollmentRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let enrolledAt: Date
    let agentID: String
    let endpoint: String
    let clientIdentityLabel: String
    let serverCertificateSHA256Pins: [String]
    let certificateExpiresAt: Date?
    var revokedAt: Date?
    var replacedBy: UUID?
}

struct MTLSFleetProbeRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let probedAt: Date
    let endpoint: String
    let authenticated: Bool
    let statusCode: Int?
    let latencyMilliseconds: Int?
    let message: String
}

struct MTLSFleetSubmission: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let workflowID: String
    let deviceName: String
    let submittedAt: Date
}

struct MTLSFleetAcknowledgement: Codable, Hashable, Sendable {
    let requestID: UUID
    let jobID: UUID?
    let accepted: Bool
    let message: String
}

enum MTLSEnrollmentValidator {
    static func validate(_ configuration: MTLSEnrollmentConfiguration) -> [String] {
        var blockers: [String] = []
        guard let url = URL(string: configuration.endpoint),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            blockers.append("Fleet endpoints must be credential-free HTTPS URLs with a host.")
            return blockers
        }
        if NameSanitizer.fileComponent(configuration.agentID) != configuration.agentID || configuration.agentID.isEmpty {
            blockers.append("Agent ID must be a non-empty safe identifier.")
        }
        if configuration.clientIdentityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockers.append("A Keychain client identity label is required.")
        }
        let pins = configuration.serverCertificateSHA256Pins
        if pins.isEmpty || pins.contains(where: { $0.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) == nil }) {
            blockers.append("At least one 64-character server certificate SHA-256 pin is required.")
        }
        if !(5...300).contains(configuration.requestTimeoutSeconds) {
            blockers.append("Transport timeout must be between 5 and 300 seconds.")
        }
        return blockers
    }

    static func keychainIdentity(label: String) -> SecIdentity? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: label,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecIdentity)
    }
}

private final class MTLSURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let identity: SecIdentity
    private let pins: Set<String>

    init(identity: SecIdentity, pins: [String]) {
        self.identity = identity
        self.pins = Set(pins.map { $0.lowercased() })
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodClientCertificate {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(identity: identity, certificates: [certificate], persistence: .forSession)
            )
            return
        }
        if method == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            var error: CFError?
            guard SecTrustEvaluateWithError(trust, &error),
                  let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let certificate = chain.first else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            let digest = ProductionDepthCoding.sha256(SecCertificateCopyData(certificate) as Data)
            guard pins.contains(digest.lowercased()) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

enum MTLSFleetTransport {
    static func probe(_ configuration: MTLSEnrollmentConfiguration) async -> MTLSFleetProbeRecord {
        let started = Date()
        let blockers = MTLSEnrollmentValidator.validate(configuration)
        guard blockers.isEmpty else { return probeFailure(configuration, started, blockers.joined(separator: " ")) }
        guard let identity = MTLSEnrollmentValidator.keychainIdentity(label: configuration.clientIdentityLabel) else {
            return probeFailure(configuration, started, "The configured client identity was not found in the Keychain.")
        }
        do {
            let session = session(configuration, identity: identity)
            defer { session.invalidateAndCancel() }
            let endpoint = try endpointURL(configuration, path: "v1/health")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.setValue(configuration.agentID, forHTTPHeaderField: "X-VDL-Agent-ID")
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            let authenticated = status.map { (200..<300).contains($0) } ?? false
            return MTLSFleetProbeRecord(
                id: UUID(), probedAt: .now, endpoint: configuration.endpoint,
                authenticated: authenticated, statusCode: status,
                latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1_000),
                message: authenticated ? "The remote agent completed an mTLS health exchange." : "The remote agent returned HTTP \(status ?? 0)."
            )
        } catch {
            return probeFailure(configuration, started, error.localizedDescription)
        }
    }

    static func submit(
        _ submission: MTLSFleetSubmission,
        configuration: MTLSEnrollmentConfiguration
    ) async -> MTLSFleetAcknowledgement {
        let blockers = MTLSEnrollmentValidator.validate(configuration)
        guard blockers.isEmpty,
              let identity = MTLSEnrollmentValidator.keychainIdentity(label: configuration.clientIdentityLabel) else {
            return MTLSFleetAcknowledgement(
                requestID: submission.id, jobID: nil, accepted: false,
                message: blockers.first ?? "The configured client identity was not found in the Keychain."
            )
        }
        do {
            let body = try ProductionDepthCoding.canonicalData(submission)
            guard body.count <= 1_048_576 else { throw ProductionDepthError.invalid("Fleet request exceeds 1 MiB.") }
            let session = session(configuration, identity: identity)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: try endpointURL(configuration, path: "v1/jobs"))
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(configuration.agentID, forHTTPHeaderField: "X-VDL-Agent-ID")
            let (data, response) = try await session.data(for: request)
            guard data.count <= 1_048_576 else { throw ProductionDepthError.invalid("Fleet response exceeds 1 MiB.") }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                return .init(requestID: submission.id, jobID: nil, accepted: false, message: "Remote agent returned HTTP \(status).")
            }
            let acknowledgement = try JSONDecoder().decode(MTLSFleetAcknowledgement.self, from: data)
            guard acknowledgement.requestID == submission.id else {
                throw ProductionDepthError.invalid("Fleet response request ID does not match the submitted request.")
            }
            return acknowledgement
        } catch {
            return .init(requestID: submission.id, jobID: nil, accepted: false, message: error.localizedDescription)
        }
    }

    private static func session(_ configuration: MTLSEnrollmentConfiguration, identity: SecIdentity) -> URLSession {
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = TimeInterval(configuration.requestTimeoutSeconds)
        settings.timeoutIntervalForResource = TimeInterval(configuration.requestTimeoutSeconds)
        settings.waitsForConnectivity = false
        settings.urlCache = nil
        return URLSession(
            configuration: settings,
            delegate: MTLSURLSessionDelegate(identity: identity, pins: configuration.serverCertificateSHA256Pins),
            delegateQueue: nil
        )
    }

    private static func endpointURL(_ configuration: MTLSEnrollmentConfiguration, path: String) throws -> URL {
        guard let root = URL(string: configuration.endpoint) else { throw ProductionDepthError.invalid("Fleet endpoint is invalid.") }
        return root.appendingPathComponent(path)
    }

    private static func probeFailure(
        _ configuration: MTLSEnrollmentConfiguration,
        _ started: Date,
        _ message: String
    ) -> MTLSFleetProbeRecord {
        MTLSFleetProbeRecord(
            id: UUID(), probedAt: .now, endpoint: configuration.endpoint,
            authenticated: false, statusCode: nil,
            latencyMilliseconds: Int(Date().timeIntervalSince(started) * 1_000), message: message
        )
    }
}

// MARK: - 7. SQLite-backed high-volume event storage

struct ScalableEventRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let occurredAt: Date
    let category: String
    let entityID: String
    let payloadSHA256: String
    let payload: Data
}

struct ScalableEventStoreStatus: Codable, Hashable, Sendable {
    let databasePath: String?
    let schemaVersion: Int
    let journalMode: String
    let integrityPassed: Bool
    let rowCount: Int
    let lastMigratedAt: Date?
    let message: String

    static let unavailable = ScalableEventStoreStatus(
        databasePath: nil, schemaVersion: 1, journalMode: "unavailable",
        integrityPassed: false, rowCount: 0, lastMigratedAt: nil,
        message: "The scalable event store has not been opened."
    )
}

final class ScalableEventStore: @unchecked Sendable {
    static let schemaVersion = 1
    private let lock = NSLock()
    private var database: OpaquePointer?
    let url: URL

    init(url: URL) throws {
        self.url = url
        try SecureFilesystem.prepareDirectory(url.deletingLastPathComponent())
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw ProductionDepthError.sqlite("SQLite could not open the lab event store.")
        }
        database = handle
        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=FULL;")
            try execute("PRAGMA foreign_keys=ON;")
            try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
            try execute("CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, occurred_at REAL NOT NULL, category TEXT NOT NULL, entity_id TEXT NOT NULL, payload_sha256 TEXT NOT NULL, payload BLOB NOT NULL);")
            try execute("CREATE INDEX IF NOT EXISTS events_category_time ON events(category, occurred_at DESC);")
            try execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('schema_version','\(Self.schemaVersion)');")
            try SecureFilesystem.protectFile(url)
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    func append<T: Encodable>(category: String, entityID: String, occurredAt: Date = .now, value: T) throws {
        let data = try ProductionDepthCoding.canonicalData(value)
        let record = ScalableEventRecord(
            id: UUID(), occurredAt: occurredAt, category: category, entityID: entityID,
            payloadSHA256: ProductionDepthCoding.sha256(data), payload: data
        )
        try insert(record)
    }

    func migrate(
        logs: [LogEntry],
        testRuns: [TestRunRecord],
        fleetLeases: [FleetLease],
        physicalLeases: [PhysicalDeviceLease]
    ) throws -> ScalableEventStoreStatus {
        var records: [ScalableEventRecord] = []
        func add<T: Encodable>(_ category: String, _ entityID: String, _ date: Date, _ value: T) throws {
            let data = try ProductionDepthCoding.canonicalData(value)
            let stableID = ProductionDepthCoding.sha256(Data("\(category)|\(entityID)|\(date.timeIntervalSince1970)|".utf8) + data)
            let uuid = UUID(uuidString: String(stableID.prefix(8)) + "-" + String(stableID.dropFirst(8).prefix(4)) + "-4" + String(stableID.dropFirst(13).prefix(3)) + "-a" + String(stableID.dropFirst(17).prefix(3)) + "-" + String(stableID.dropFirst(20).prefix(12))) ?? UUID()
            records.append(.init(id: uuid, occurredAt: date, category: category, entityID: entityID, payloadSHA256: ProductionDepthCoding.sha256(data), payload: data))
        }
        for log in logs { try add("activity", log.scope, log.timestamp, log) }
        for run in testRuns { try add("test-run", run.id.uuidString, run.createdAt, run) }
        for lease in fleetLeases { try add("fleet-lease", lease.id.uuidString, lease.createdAt, lease) }
        for lease in physicalLeases { try add("physical-lease", lease.id.uuidString, lease.acquiredAt, lease) }
        lock.lock()
        do {
            try executeUnlocked("BEGIN IMMEDIATE;")
            for record in records { try insertUnlocked(record, replace: false) }
            try executeUnlocked("INSERT OR REPLACE INTO metadata(key,value) VALUES('last_migrated_at','\(Date().timeIntervalSince1970)');")
            try executeUnlocked("COMMIT;")
            lock.unlock()
        } catch {
            try? executeUnlocked("ROLLBACK;")
            lock.unlock()
            throw error
        }
        return try status(lastMigratedAt: .now)
    }

    func latest(category: String, limit: Int = 100) throws -> [ScalableEventRecord] {
        guard (1...1_000).contains(limit) else { throw ProductionDepthError.invalid("Event query limit must be between 1 and 1000.") }
        lock.lock()
        defer { lock.unlock() }
        guard let database else { throw ProductionDepthError.sqlite("Event database is closed.") }
        var statement: OpaquePointer?
        let sql = "SELECT id,occurred_at,category,entity_id,payload_sha256,payload FROM events WHERE category=? ORDER BY occurred_at DESC LIMIT ?;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError(database) }
        defer { sqlite3_finalize(statement) }
        bind(category, to: 1, statement: statement)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var records: [ScalableEventRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = columnText(statement, 0).flatMap(UUID.init(uuidString:)),
                  let category = columnText(statement, 2), let entityID = columnText(statement, 3),
                  let digest = columnText(statement, 4) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 5))
            let payload = sqlite3_column_blob(statement, 5).map { Data(bytes: $0, count: length) } ?? Data()
            records.append(.init(
                id: id, occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                category: category, entityID: entityID, payloadSHA256: digest, payload: payload
            ))
        }
        return records
    }

    func checkpoint() throws {
        lock.lock(); defer { lock.unlock() }
        try executeUnlocked("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    func status(lastMigratedAt: Date? = nil) throws -> ScalableEventStoreStatus {
        lock.lock()
        defer { lock.unlock() }
        guard database != nil else { throw ProductionDepthError.sqlite("Event database is closed.") }
        let integrity = try scalarTextUnlocked("PRAGMA integrity_check;") == "ok"
        let journal = try scalarTextUnlocked("PRAGMA journal_mode;") ?? "unknown"
        let count = Int(try scalarIntUnlocked("SELECT COUNT(*) FROM events;"))
        return ScalableEventStoreStatus(
            databasePath: url.path, schemaVersion: Self.schemaVersion, journalMode: journal,
            integrityPassed: integrity, rowCount: count, lastMigratedAt: lastMigratedAt,
            message: integrity ? "SQLite integrity_check passed with \(count) durable event(s)." : "SQLite integrity_check failed."
        )
    }

    private func insert(_ record: ScalableEventRecord) throws {
        lock.lock(); defer { lock.unlock() }
        try insertUnlocked(record, replace: true)
    }

    private func insertUnlocked(_ record: ScalableEventRecord, replace: Bool) throws {
        guard let database else { throw ProductionDepthError.sqlite("Event database is closed.") }
        var statement: OpaquePointer?
        let verb = replace ? "INSERT OR REPLACE" : "INSERT OR IGNORE"
        let sql = "\(verb) INTO events(id,occurred_at,category,entity_id,payload_sha256,payload) VALUES(?,?,?,?,?,?);"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError(database) }
        defer { sqlite3_finalize(statement) }
        bind(record.id.uuidString, to: 1, statement: statement)
        sqlite3_bind_double(statement, 2, record.occurredAt.timeIntervalSince1970)
        bind(record.category, to: 3, statement: statement)
        bind(record.entityID, to: 4, statement: statement)
        bind(record.payloadSHA256, to: 5, statement: statement)
        _ = record.payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 6, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(database) }
    }

    private func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        try executeUnlocked(sql)
    }

    private func executeUnlocked(_ sql: String) throws {
        guard let database else { throw ProductionDepthError.sqlite("Event database is closed.") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "Unknown SQLite error."
            sqlite3_free(error)
            throw ProductionDepthError.sqlite(message)
        }
    }

    private func scalarTextUnlocked(_ sql: String) throws -> String? {
        guard let database else { throw ProductionDepthError.sqlite("Event database is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError(database) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, 0)
    }

    private func scalarIntUnlocked(_ sql: String) throws -> Int64 {
        guard let database else { throw ProductionDepthError.sqlite("Event database is closed.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError(database) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ value: String, to index: Int32, statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private func sqliteError(_ database: OpaquePointer) -> ProductionDepthError {
        ProductionDepthError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

// MARK: - 8. Exact upgrade compatibility certification

struct RuntimeCompatibilityTuple: Codable, Hashable, Sendable {
    let hostModel: String
    let macOSVersion: String
    let backendID: String
    let backendVersion: String?
    let guestCompanionID: String?
    let guestCompanionVersion: String?
    let adapterID: String?
    let adapterVersion: String?
    let labSchemaVersion: Int
}

struct RuntimeCompatibilityCertificate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let issuedAt: Date
    let expiresAt: Date
    let tuple: RuntimeCompatibilityTuple
    let qualificationCampaignID: UUID
    let evidenceSealID: UUID
    let suiteSHA256: String
}

struct UpgradeCompatibilityDecision: Codable, Hashable, Sendable {
    let evaluatedAt: Date
    let candidate: RuntimeCompatibilityTuple?
    let certificateID: UUID?
    let allowed: Bool
    let blockers: [String]

    static let unavailable = UpgradeCompatibilityDecision(
        evaluatedAt: .distantPast, candidate: nil, certificateID: nil,
        allowed: false, blockers: ["No runtime upgrade candidate has been evaluated."]
    )
}

enum RuntimeCompatibilityCertificationEngine {
    static func issue(
        tuple: RuntimeCompatibilityTuple,
        campaign: QualificationCampaign,
        seal: EvidenceSeal,
        suiteData: Data,
        lifetimeDays: Int = 90,
        now: Date = .now
    ) throws -> RuntimeCompatibilityCertificate {
        guard campaign.state == .passed, campaign.completedAt != nil,
              campaign.evidenceSealID == seal.id, seal.reviewState == .approved,
              seal.backendID == tuple.backendID, seal.backendVersion == tuple.backendVersion else {
            throw ProductionDepthError.invalid("A passing qualification campaign linked to an approved exact-backend evidence seal is required.")
        }
        guard !suiteData.isEmpty, suiteData.count <= 32 * 1_024 * 1_024,
              (1...365).contains(lifetimeDays) else {
            throw ProductionDepthError.invalid("Certification suite evidence or certificate lifetime is invalid.")
        }
        return RuntimeCompatibilityCertificate(
            id: UUID(), issuedAt: now,
            expiresAt: Calendar(identifier: .gregorian).date(byAdding: .day, value: lifetimeDays, to: now)!,
            tuple: tuple, qualificationCampaignID: campaign.id, evidenceSealID: seal.id,
            suiteSHA256: ProductionDepthCoding.sha256(suiteData)
        )
    }

    static func evaluate(
        candidate: RuntimeCompatibilityTuple,
        certificates: [RuntimeCompatibilityCertificate],
        now: Date = .now
    ) -> UpgradeCompatibilityDecision {
        guard let certificate = certificates.first(where: { $0.tuple == candidate && $0.expiresAt > now }) else {
            return UpgradeCompatibilityDecision(
                evaluatedAt: now, candidate: candidate, certificateID: nil, allowed: false,
                blockers: ["No unexpired certificate matches the exact host, backend, companion, adapter, and lab schema tuple."]
            )
        }
        return UpgradeCompatibilityDecision(
            evaluatedAt: now, candidate: candidate, certificateID: certificate.id,
            allowed: true, blockers: []
        )
    }
}

// MARK: - 9. CI and dependency lifecycle enforcement

struct CIMaintenanceAssessment: Codable, Hashable, Sendable {
    let inspectedAt: Date
    let repositoryPath: String?
    let workflowFiles: Int
    let pinnedActionReferences: Int
    let unpinnedActionReferences: [String]
    let deprecatedActionReferences: [String]
    let passed: Bool
    let message: String

    static let unavailable = CIMaintenanceAssessment(
        inspectedAt: .distantPast, repositoryPath: nil, workflowFiles: 0,
        pinnedActionReferences: 0, unpinnedActionReferences: [], deprecatedActionReferences: [],
        passed: false, message: "No repository workflow maintenance audit has run."
    )
}

enum CIMaintenanceAuditor {
    static func inspect(repositoryRoot: URL) -> CIMaintenanceAssessment {
        let workflows = repositoryRoot.appendingPathComponent(".github/workflows", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: workflows, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ))?.filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) } ?? []
        var pinned = 0
        var unpinned: [String] = []
        var deprecated: [String] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard let range = line.range(of: #"uses:\s*([^\s#]+)"#, options: .regularExpression) else { continue }
                let token = line[range].replacingOccurrences(of: #"uses:\s*"#, with: "", options: .regularExpression)
                let location = "\(file.lastPathComponent):\(number + 1) \(token)"
                guard let at = token.lastIndex(of: "@") else { unpinned.append(location); continue }
                let reference = token[token.index(after: at)...]
                if reference.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil { pinned += 1 }
                else { unpinned.append(location) }
                let comment = String(line).lowercased()
                if token.hasPrefix("actions/checkout@") && !comment.contains("# v6") {
                    deprecated.append(location + " requires checkout v6/Node 24")
                }
                if token.hasPrefix("github/codeql-action/") && !comment.contains("# v4") {
                    deprecated.append(location + " requires CodeQL Action v4")
                }
                if token.hasPrefix("actions/upload-artifact@") && !comment.contains("# v7") {
                    deprecated.append(location + " requires upload-artifact v7/Node 24")
                }
            }
        }
        let passed = !files.isEmpty && unpinned.isEmpty && deprecated.isEmpty
        return CIMaintenanceAssessment(
            inspectedAt: .now, repositoryPath: repositoryRoot.path, workflowFiles: files.count,
            pinnedActionReferences: pinned, unpinnedActionReferences: unpinned,
            deprecatedActionReferences: deprecated, passed: passed,
            message: passed ? "All \(pinned) action references are commit-pinned and required action majors are current." : "Workflow maintenance found \(unpinned.count + deprecated.count) issue(s)."
        )
    }
}

// MARK: - 10. Operator runbooks and evidence-producing drills

enum OperatorRunbookRisk: String, Codable, CaseIterable, Sendable { case readOnly, controlledMutation, destructive }

struct OperatorRunbookStep: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let instruction: String
    let verification: String
}

struct OperatorRunbook: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let risk: OperatorRunbookRisk
    let prerequisites: [String]
    let steps: [OperatorRunbookStep]
    let documentationPath: String
}

struct OperatorRunbookContext: Codable, Hashable, Sendable {
    let migrationBackupAvailable: Bool
    let remoteAgentKeyringAvailable: Bool
    let fleetDrainControlAvailable: Bool
    let evidenceLedgerValid: Bool
    let updateRollbackAvailable: Bool
    let physicalLeaseControlAvailable: Bool
}

struct OperatorRunbookDrillRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let runbookID: String
    let executedAt: Date
    let checks: [ProductionGateCheck]
    let passed: Bool
    let message: String
}

enum OperatorRunbookCatalog {
    static let builtIns: [OperatorRunbook] = [
        runbook("lab-recovery", "Recover a damaged lab", .controlledMutation, "docs/runbooks/LAB_RECOVERY.md", ["Verified migration or encrypted backup"], [
            ("freeze", "Stop mutation and record the incident.", "No VM or state mutation remains active."),
            ("verify", "Verify the selected backup before staging restore.", "Backup manifest and payload hashes pass."),
            ("stage", "Restore into staging and compare manifests.", "Staging produces an explicit apply command."),
        ]),
        runbook("credential-rotation", "Rotate lab credentials", .controlledMutation, "docs/runbooks/CREDENTIAL_ROTATION.md", ["Remote agent v2 keyring"], [
            ("rotate", "Generate and activate a replacement key.", "New key ID becomes active without exposing key bytes."),
            ("revoke", "Revoke the replaced key after the overlap window.", "Old key ID is rejected by health checks."),
        ]),
        runbook("compromised-host", "Isolate a compromised host", .controlledMutation, "docs/runbooks/COMPROMISED_HOST.md", ["Fleet drain and lease controls"], [
            ("drain", "Drain the host and stop new placement.", "Scheduler excludes the host."),
            ("cancel", "Cancel or expire active leases.", "No active lease remains on the host."),
            ("revoke", "Revoke host and transport credentials.", "Authenticated probes fail for the revoked identity."),
        ]),
        runbook("evidence-revocation", "Revoke invalid evidence", .controlledMutation, "docs/runbooks/EVIDENCE_REVOCATION.md", ["Valid evidence ledger"], [
            ("identify", "Identify every claim derived from the affected seal.", "Dependent qualification rows are enumerated."),
            ("reject", "Record reviewer rejection without rewriting history.", "Ledger chain still verifies and claim becomes unavailable."),
        ]),
        runbook("failed-update", "Roll back a failed update", .controlledMutation, "docs/runbooks/FAILED_UPDATE.md", ["Verified prior app and migration backup"], [
            ("health", "Confirm the staged update health failure.", "Launch marker identifies the failing version."),
            ("rollback", "Use the generated rollback command.", "Prior app signature and state schema are verified."),
        ]),
        runbook("device-loss", "Handle a lost physical device", .controlledMutation, "docs/runbooks/DEVICE_LOSS.md", ["Physical-device lease inventory"], [
            ("cancel", "Cancel the device lease and pending jobs.", "Router cannot select the lost device."),
            ("revoke", "Revoke pairing and development credentials.", "Device no longer appears authorized."),
            ("audit", "Preserve the last device audit record.", "Incident evidence includes target ID without secret material."),
        ]),
    ]

    static func drill(_ runbook: OperatorRunbook, context: OperatorRunbookContext) -> OperatorRunbookDrillRecord {
        let prerequisitePassed: Bool = switch runbook.id {
        case "lab-recovery": context.migrationBackupAvailable
        case "credential-rotation": context.remoteAgentKeyringAvailable
        case "compromised-host": context.fleetDrainControlAvailable
        case "evidence-revocation": context.evidenceLedgerValid
        case "failed-update": context.updateRollbackAvailable && context.migrationBackupAvailable
        case "device-loss": context.physicalLeaseControlAvailable
        default: false
        }
        let documentation = documentationURL(for: runbook)
        var checks: [ProductionGateCheck] = [
            .init(id: "documentation", passed: documentation != nil, evidence: documentation.map { "Runbook documentation exists at \($0.path)." } ?? "Runbook documentation is missing at \(runbook.documentationPath)."),
            .init(id: "prerequisites", passed: prerequisitePassed, evidence: prerequisitePassed ? "Required control-plane evidence is available." : "Required control-plane evidence is unavailable."),
        ]
        checks += runbook.steps.map { .init(id: $0.id, passed: !$0.instruction.isEmpty && !$0.verification.isEmpty, evidence: $0.verification) }
        let passed = checks.allSatisfy(\.passed)
        return OperatorRunbookDrillRecord(
            id: UUID(), runbookID: runbook.id, executedAt: .now, checks: checks,
            passed: passed, message: passed ? "The read-only runbook drill passed." : "The drill exposed missing prerequisites; no mutation was performed."
        )
    }

    static func documentationURL(for runbook: OperatorRunbook) -> URL? {
        let filename = URL(fileURLWithPath: runbook.documentationPath).lastPathComponent
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Runbooks", isDirectory: true).appendingPathComponent(filename),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(runbook.documentationPath),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    private static func runbook(
        _ id: String, _ title: String, _ risk: OperatorRunbookRisk,
        _ documentation: String, _ prerequisites: [String],
        _ steps: [(String, String, String)]
    ) -> OperatorRunbook {
        OperatorRunbook(
            id: id, title: title, risk: risk, prerequisites: prerequisites,
            steps: steps.map { .init(id: $0.0, instruction: $0.1, verification: $0.2) },
            documentationPath: documentation
        )
    }
}

// MARK: - Persisted production-depth state

struct ProductionDepthState: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var companions: [ManagedGuestCompanion]
    var companionLifecycle: [GuestCompanionLifecycleRecord]
    var signingAssessments: [SigningProvisioningAssessment]
    var physicalDetails: [PhysicalDeviceDetailRecord]
    var physicalLeases: [PhysicalDeviceLease]
    var visualRegressions: [VisualRegressionReport]
    var accessibilityRegressions: [AccessibilityRegressionReport]
    var faultResults: [FaultInjectionResult]
    var mtlsConfiguration: MTLSEnrollmentConfiguration?
    var mtlsEnrollments: [MTLSEnrollmentRecord]
    var mtlsProbes: [MTLSFleetProbeRecord]
    var eventStore: ScalableEventStoreStatus
    var compatibilityCertificates: [RuntimeCompatibilityCertificate]
    var upgradeDecision: UpgradeCompatibilityDecision
    var ciMaintenance: CIMaintenanceAssessment
    var runbookDrills: [OperatorRunbookDrillRecord]

    static let empty = ProductionDepthState(
        schemaVersion: 1, companions: [], companionLifecycle: [], signingAssessments: [],
        physicalDetails: [], physicalLeases: [], visualRegressions: [], accessibilityRegressions: [],
        faultResults: [], mtlsConfiguration: nil, mtlsEnrollments: [], mtlsProbes: [],
        eventStore: .unavailable, compatibilityCertificates: [], upgradeDecision: .unavailable,
        ciMaintenance: .unavailable, runbookDrills: []
    )
}

enum ProductionDepthStore {
    static func url(paths: LabPaths) -> URL { paths.stateRoot.appendingPathComponent("production-depth.json") }

    static func load(paths: LabPaths) -> ProductionDepthState {
        let source = url(paths: paths)
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 32 * 1_024 * 1_024,
              var state = try? HardeningJSON.load(ProductionDepthState.self, from: source),
              state.schemaVersion == 1 else { return .empty }
        state.companions = Array(state.companions.prefix(100))
        state.companionLifecycle = Array(state.companionLifecycle.prefix(1_000))
        state.signingAssessments = Array(state.signingAssessments.prefix(250))
        state.physicalDetails = Array(state.physicalDetails.prefix(250))
        state.physicalLeases = Array(PhysicalDeviceLifecycleService.normalize(state.physicalLeases).prefix(1_000))
        state.visualRegressions = Array(state.visualRegressions.prefix(250))
        state.accessibilityRegressions = Array(state.accessibilityRegressions.prefix(250))
        state.faultResults = Array(state.faultResults.prefix(1_000))
        state.mtlsEnrollments = Array(state.mtlsEnrollments.prefix(100))
        state.mtlsProbes = Array(state.mtlsProbes.prefix(250))
        state.compatibilityCertificates = Array(state.compatibilityCertificates.prefix(500))
        state.runbookDrills = Array(state.runbookDrills.prefix(1_000))
        return state
    }

    static func save(_ state: ProductionDepthState, paths: LabPaths) throws {
        try HardeningJSON.save(state, to: url(paths: paths))
    }
}
