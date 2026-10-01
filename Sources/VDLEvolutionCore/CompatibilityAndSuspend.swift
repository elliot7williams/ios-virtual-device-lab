import Foundation

public struct VersionProbe: Codable, Sendable {
    public let component: String
    public let executable: String
    public let arguments: [String]
    public let expectedOutput: String
    public init(component: String, executable: String, arguments: [String], expectedOutput: String) {
        self.component = component; self.executable = executable; self.arguments = arguments; self.expectedOutput = expectedOutput
    }
}

public struct CompatibilityMatrixRow: Codable, Sendable, Identifiable {
    public let id: String
    public let manager: String
    public let backend: String
    public let guestProtocol: Int
    public let fleetProtocol: Int
    public let stateSchema: Int
    public let migrationFromSchema: Int
    public let downgradeSupported: Bool
    public let probes: [VersionProbe]
    public init(id: String, manager: String, backend: String, guestProtocol: Int, fleetProtocol: Int, stateSchema: Int,
                migrationFromSchema: Int, downgradeSupported: Bool, probes: [VersionProbe]) {
        self.id = id; self.manager = manager; self.backend = backend; self.guestProtocol = guestProtocol
        self.fleetProtocol = fleetProtocol; self.stateSchema = stateSchema; self.migrationFromSchema = migrationFromSchema
        self.downgradeSupported = downgradeSupported; self.probes = probes
    }
}

public struct MatrixProbeResult: Codable, Sendable {
    public let component: String
    public let passed: Bool
    public let output: String
}
public struct MatrixRowResult: Codable, Sendable, Identifiable {
    public let id: String
    public let checkedAt: Date
    public let passed: Bool
    public let issues: [String]
    public let probes: [MatrixProbeResult]
    public let sourceRowSHA256: String
}

public enum CompatibilityMatrixRunner {
    public static func validate(_ row: CompatibilityMatrixRow) -> [String] {
        var issues = [String]()
        if row.id.isEmpty || row.manager.isEmpty || row.backend.isEmpty { issues.append("Exact component versions and a row ID are required.") }
        if row.guestProtocol != 3 || row.fleetProtocol != 1 { issues.append("Unsupported guest/fleet protocol tuple.") }
        if !(1...11).contains(row.stateSchema) || !(1...row.stateSchema).contains(row.migrationFromSchema) { issues.append("Unsupported state-schema migration.") }
        let components = Set(row.probes.map(\.component))
        if !Set(["manager", "backend", "companion", "fleet-server", "fleet-worker", "migration"]).isSubset(of: components) {
            issues.append("Probes for all five components and migration are required.")
        }
        if row.downgradeSupported && !components.contains("downgrade") { issues.append("Downgrade claims require an executable downgrade probe.") }
        if row.probes.count > 20 || row.probes.contains(where: { $0.expectedOutput.isEmpty || $0.arguments.count > 32 }) {
            issues.append("Probes require bounded arguments and nonempty expected output.")
        }
        return issues
    }
    public static func run(_ row: CompatibilityMatrixRow, allowedExecutables: Set<String>) throws -> MatrixRowResult {
        var issues = validate(row)
        // Imported matrices never grant authority to execute arbitrary programs.
        if row.probes.contains(where: { !allowedExecutables.contains(URL(fileURLWithPath: $0.executable).standardizedFileURL.path) }) {
            issues.append("A probe executable is outside the explicitly approved component paths.")
        }
        var results = [MatrixProbeResult]()
        if issues.isEmpty {
            for probe in row.probes {
                let result = EvolutionProcess.run(probe.executable, probe.arguments, timeout: 60)
                results.append(MatrixProbeResult(component: probe.component, passed: result.passed && result.output.contains(probe.expectedOutput), output: result.output))
            }
        }
        return MatrixRowResult(id: row.id, checkedAt: .now, passed: issues.isEmpty && results.allSatisfy(\.passed), issues: issues,
            probes: results, sourceRowSHA256: EvolutionFiles.digest(try EvolutionFiles.encode(row)))
    }
}

public struct SavedMachineBinding: Codable, Equatable, Sendable {
    public let hostBuild: String
    public let hostArchitecture: String
    public let backendVersion: String
    public let firmwareSHA256: String
    public let hardwareProfileID: String
    public init(hostBuild: String, hostArchitecture: String, backendVersion: String, firmwareSHA256: String, hardwareProfileID: String) {
        self.hostBuild = hostBuild; self.hostArchitecture = hostArchitecture; self.backendVersion = backendVersion
        self.firmwareSHA256 = firmwareSHA256; self.hardwareProfileID = hardwareProfileID
    }
}
public struct SavedMachineManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let deviceID: String
    public let binding: SavedMachineBinding
    public let stateSHA256: String
    public let stateBytes: Int64
    public let createdAt: Date
    public init(deviceID: String, binding: SavedMachineBinding, stateSHA256: String, stateBytes: Int64) {
        schemaVersion = 1; id = UUID(); self.deviceID = deviceID; self.binding = binding
        self.stateSHA256 = stateSHA256; self.stateBytes = stateBytes; createdAt = .now
    }
}
public enum SavedMachineValidator {
    public static func validate(_ manifest: SavedMachineManifest, current: SavedMachineBinding, deviceID: String,
                                stateFile: URL, backendAdvertisesRestore: Bool) -> [String] {
        var issues = [String]()
        if !backendAdvertisesRestore { issues.append("The backend does not advertise qualified machine-state restore.") }
        if manifest.schemaVersion != 1 || manifest.deviceID != deviceID { issues.append("Saved-state schema or device identity differs.") }
        if manifest.binding != current { issues.append("Host build, architecture, backend, firmware, or hardware profile changed; saved state is invalid.") }
        if !EvolutionFiles.validDigest(manifest.stateSHA256) || !EvolutionFiles.validDigest(current.firmwareSHA256) || manifest.stateBytes <= 0 {
            issues.append("Saved state and firmware require valid checksums and a nonempty payload.")
        }
        if let hash = try? EvolutionFiles.hashFile(stateFile) {
            if hash.digest != manifest.stateSHA256 || hash.bytes != manifest.stateBytes { issues.append("Saved machine-state checksum or size mismatch.") }
        } else { issues.append("Saved machine-state payload is unavailable.") }
        return issues
    }
}
