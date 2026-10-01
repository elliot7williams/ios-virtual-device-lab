import AppKit
import Foundation
import ServiceManagement
import VDLEvolutionCore

enum ManagedLabService: String, CaseIterable, Identifiable {
    case coordinator = "Fleet Coordinator"
    case worker = "Fleet Worker"
    var id: String { rawValue }
    var plist: String { self == .coordinator ? "dev.vdl.fleetd.plist" : "dev.vdl.fleetworker.plist" }
    var configName: String { self == .coordinator ? "fleet-server-policy.json" : "fleet-worker.json" }
    var service: SMAppService { SMAppService.agent(plistName: plist) }
    var configurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/iOS Virtual Device Lab/Services/\(configName)")
    }
    var status: String {
        switch service.status {
        case .enabled: "Enabled"
        case .requiresApproval: "Approval required in Login Items"
        case .notRegistered: "Not registered"
        case .notFound: "Packaged helper not found"
        @unknown default: "Unknown"
        }
    }
}

struct LabEvolutionState: Codable, Sendable {
    var schemaVersion = 1
    var hostChecks: [HostPolicyCheck] = []
    var upstream: UpstreamSnapshot?
    var matrixResults: [MatrixRowResult] = []
    var artifacts: [RegistryArtifact] = []
    var fixtureScenario = NetworkFixtureScenario()
    var xctestReports: [XCTestImportReport] = []
    var schedulerPolicy = FleetSchedulingPolicy()
    var savedStateIssues: [String] = []
}

extension LabAppModel {
    var evolutionStateURL: URL { paths.stateRoot.appendingPathComponent("lab-evolution.json") }
    var artifactRegistry: ArtifactRegistry { ArtifactRegistry(root: paths.dataRoot.appendingPathComponent("ArtifactRegistry")) }

    func retryBootstrap() async {
        resetBootstrapForRecovery()
        await bootstrap()
    }
    func loadEvolution() {
        evolution = (try? EvolutionFiles.load(LabEvolutionState.self, evolutionStateURL)) ?? LabEvolutionState()
    }
    func saveEvolution() {
        guard !storageRescueActive else { return }
        do { try EvolutionFiles.save(evolution, evolutionStateURL) }
        catch { alertMessage = error.localizedDescription }
    }
    func inspectHostPolicy() async {
        let binary = readiness.binaryPath.map { URL(fileURLWithPath: $0) }
        evolution.hostChecks = await Task.detached { HostPolicyInspector.inspect(binary: binary) }.value
        saveEvolution()
    }
    func checkUpstream(revision: String) async {
        do { evolution.upstream = try await UpstreamTracker.check(installedRevision: revision); saveEvolution() }
        catch { alertMessage = error.localizedDescription }
    }
    func configureService(_ kind: ManagedLabService, from file: URL) throws {
        let data = try Data(contentsOf: file)
        guard data.count <= 1_048_576, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["schemaVersion"] as? Int == 1 else { throw EvolutionError.invalid("Select a bounded schema-v1 service configuration.") }
        guard kind.service.status != .enabled else { throw EvolutionError.invalid("Stop the service before replacing its configuration.") }
        try EvolutionFiles.directory(kind.configurationURL.deletingLastPathComponent())
        try data.write(to: kind.configurationURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: kind.configurationURL.path)
    }
    func changeService(_ kind: ManagedLabService, action: String) async {
        do {
            if action == "stop" || action == "restart" { try await kind.service.unregister() }
            if action == "start" || action == "restart" {
                guard FileManager.default.fileExists(atPath: kind.configurationURL.path) else { throw EvolutionError.invalid("Import the service configuration first.") }
                try kind.service.register()
            }
            objectWillChange.send()
        } catch { alertMessage = error.localizedDescription }
    }
    func importRegistryArtifact(_ file: URL, kind: RegistryArtifactKind, provenance: String) async {
        let registry = artifactRegistry
        do {
            _ = try await Task.detached { try registry.ingest(file, kind: kind, provenance: provenance) }.value
            evolution.artifacts = try registry.list(); saveEvolution()
        } catch { alertMessage = error.localizedDescription }
    }
    func approveRegistryArtifact(_ artifact: RegistryArtifact) {
        do { _ = try artifactRegistry.approve(artifact.sha256); evolution.artifacts = try artifactRegistry.list(); saveEvolution() }
        catch { alertMessage = error.localizedDescription }
    }
    func runVersionMatrix(_ file: URL, approvedExecutables: [URL] = []) async {
        do {
            let rows = try EvolutionFiles.load([CompatibilityMatrixRow].self, file)
            guard rows.count <= 100 else { throw EvolutionError.invalid("Matrix must contain at most 100 rows.") }
            let componentPaths = [Bundle.main.executableURL?.path,
                Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("vdlctl").path,
                Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("vdl-fleetd").path,
                Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("vdl-fleetworker").path, readiness.binaryPath].compactMap { $0 }
            let allowed = Set(componentPaths + approvedExecutables.map { $0.standardizedFileURL.path })
            evolution.matrixResults = try await Task.detached {
                try rows.map { try CompatibilityMatrixRunner.run($0, allowedExecutables: allowed) }
            }.value
            saveEvolution()
        } catch { alertMessage = error.localizedDescription }
    }
    func importXCTestBundle(_ bundle: URL) async {
        let output = paths.stateRoot.appendingPathComponent("XCTestReports/\(UUID().uuidString)")
        do {
            let report = try await Task.detached { try XCTestBridge.importBundle(bundle, output: output) }.value
            evolution.xctestReports.insert(report, at: 0)
            evolution.xctestReports = Array(evolution.xctestReports.prefix(500)); saveEvolution()
            reveal(output)
        } catch { alertMessage = error.localizedDescription }
    }
    func runXCTest(_ request: XcodeTestRequest) async {
        do {
            let result = try await Task.detached { try XCTestBridge.test(request) }.value
            if FileManager.default.fileExists(atPath: request.resultBundlePath) {
                await importXCTestBundle(URL(fileURLWithPath: request.resultBundlePath))
            }
            if !result.passed { alertMessage = "Xcode test exited \(result.exitCode). \(result.output.suffix(2000))" }
        } catch { alertMessage = error.localizedDescription }
    }
    func startNetworkFixture() -> String {
        if fixtureProcess?.isRunning == true { return "Fixture service is already running." }
        do {
            let executable = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("vdl-fixture")
            let scenario = paths.stateRoot.appendingPathComponent("network-fixture.json")
            try evolution.fixtureScenario.validate()
            try EvolutionFiles.save(evolution.fixtureScenario, scenario)
            let logURL = paths.stateRoot.appendingPathComponent("network-fixture.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = executable; process.arguments = ["--scenario", scenario.path]
            process.standardOutput = output; process.standardError = output
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { _ in try? output.close() }
            try process.run(); fixtureProcess = process
            return "Fixture process started (PID \(process.processIdentifier)). Check the log for listener readiness."
        } catch { return error.localizedDescription }
    }
    func stopNetworkFixture() { if fixtureProcess?.isRunning == true { fixtureProcess?.terminate() }; fixtureProcess = nil }
}

enum LabMatrixProbe {
    @MainActor static func handleCommandLine() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--vdl-version") { print(BackendAdapterConformance.labVersion); exit(0) }
        if arguments.contains("--vdl-companion-probe") {
            guard let index = arguments.firstIndex(of: "--backend-repo"), arguments.indices.contains(index + 1) else { exit(2) }
            let report = GuestCompanionSourceAuditor.inspect(repositoryRoot: URL(fileURLWithPath: arguments[index + 1]))
            print(report.passed ? "companion source conformance PASS" : report.message)
            exit(report.passed ? 0 : 2)
        }
        guard arguments.contains("--vdl-migration-probe") else { return }
        do {
            guard let index = arguments.firstIndex(of: "--from-schema"), arguments.indices.contains(index + 1),
                  let source = Int(arguments[index + 1]), (0..<LabMigrationManager.currentSchemaVersion).contains(source) else {
                throw EvolutionError.invalid("Specify --from-schema below the current schema.")
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("vdl-migration-probe-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = LabPaths(dataRoot: root, libraryRoot: root.appendingPathComponent("VMs"), firmwareRoot: root.appendingPathComponent("ipsws"), snapshotsRoot: root.appendingPathComponent("Snapshots"), stateRoot: root.appendingPathComponent("State"))
            try paths.createDirectories()
            let original = Data("{\"fixture\":true}".utf8), activity = paths.stateRoot.appendingPathComponent("activity.json")
            try original.write(to: activity)
            try HardeningJSON.save(LabMigrationState(schemaVersion: source, history: []), to: paths.stateRoot.appendingPathComponent("lab-schema.json"))
            let report = try LabMigrationManager.migrate(paths: paths)
            guard report.destinationVersion == LabMigrationManager.currentSchemaVersion, try LabMigrationManager.migrate(paths: paths).applied.isEmpty else {
                throw EvolutionError.invalid("Migration or idempotency failed.")
            }
            try Data("modified".utf8).write(to: activity)
            _ = try LabMigrationManager.restoreLatestBackup(paths: paths)
            guard try Data(contentsOf: activity) == original else { throw EvolutionError.invalid("Rollback preservation failed.") }
            print("migration \(source)→\(report.destinationVersion) PASS; idempotency PASS; managed-file rollback PASS")
            exit(0)
        } catch { print(error.localizedDescription); exit(2) }
    }
}
