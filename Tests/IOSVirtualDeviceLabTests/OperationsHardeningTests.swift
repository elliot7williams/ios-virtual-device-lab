import CryptoKit
import Foundation
import XCTest
@testable import IOSVirtualDeviceLab

final class OperationsHardeningTests: XCTestCase {
    func testDiscoversOnlyAPFSSystemVolumes() throws {
        let plist: [String: Any] = ["Containers": [["Volumes": [
            ["APFSVolumeUUID": "SYSTEM-1", "Name": "Macintosh HD", "MountPoint": "/", "Roles": ["System"]],
            ["APFSVolumeUUID": "DATA-1", "Name": "Macintosh HD - Data", "Roles": ["Data"]],
        ]]]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let installations = HostSetupCoordinator.installations(fromAPFSPlist: data)
        XCTAssertEqual(installations.map(\.volumeUUID), ["SYSTEM-1"])
    }

    func testHostSetupPersistsRestartBoundary() {
        let target = MacOSInstallation(volumeUUID: "ABC", name: "Test macOS", mountPoint: "/")
        let started = HostSetupCoordinator.begin(for: target, bootSessionID: "boot-one")
        XCTAssertEqual(started.phase, .recoveryRequired)
        XCTAssertTrue(started.note.contains("Test macOS"))
        XCTAssertTrue(started.recoveryCommand?.contains("allow-research-guests") == true)
        let applied = HostSetupCoordinator.markRecoveryApplied(started)
        XCTAssertEqual(applied.phase, .restartRequired)
        XCTAssertEqual(HostSetupCoordinator.reconcile(applied, currentBootSessionID: "boot-one").phase, .restartRequired)
        XCTAssertEqual(HostSetupCoordinator.reconcile(applied, currentBootSessionID: "boot-two").phase, .verificationRequired)
    }

    func testHostSetupOnlyCompletesAfterReadyVerification() {
        var record = HostSetupCoordinator.begin(
            for: MacOSInstallation(volumeUUID: "ABC", name: "Test", mountPoint: "/"),
            bootSessionID: "one"
        )
        record = HostSetupCoordinator.markRecoveryApplied(record)
        record = HostSetupCoordinator.reconcile(record, currentBootSessionID: "two")
        XCTAssertEqual(HostSetupCoordinator.verify(record, hostReady: false).phase, .verificationRequired)
        XCTAssertEqual(HostSetupCoordinator.verify(record, hostReady: true).phase, .complete)
    }

    func testFleetProtocolRequiresEveryLifecycleOperation() {
        var capabilities = Set(FleetWorkerCapability.allCases)
        capabilities.remove(.result)
        let evidence = FleetWorkerProtocolEvidence(
            schemaVersion: 1, generatedAt: .now, serverVersion: "1.1.0",
            controllerHostID: "controller", workerHostIDs: ["worker"], capabilities: capabilities,
            mutuallyAuthenticated: true, idempotencyVerified: true,
            cancellationVerified: true, boundedPayloadsVerified: true, passed: true,
            sourceSHA256: String(repeating: "a", count: 64)
        )
        XCTAssertTrue(FleetWorkerProtocolEvaluator.validate(evidence).contains {
            $0.contains("lifecycle")
        })
    }

    func testFleetProtocolAcceptsCompleteTwoHostEvidence() {
        let evidence = passingFleetEvidence()
        XCTAssertEqual(FleetWorkerProtocolEvaluator.validate(evidence), [])
    }

    func testAuditHashChainDetectsTampering() throws {
        let first = auditEnvelope(sequence: 1, previous: String(repeating: "0", count: 64), record: "{\"event\":1}")
        let second = auditEnvelope(sequence: 2, previous: first.recordHash, record: "{\"event\":2}")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let validLines = try [first, second].map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        XCTAssertTrue(FleetAuditVerifier.verify(lines: validLines) { _ in true }.passed)

        var tampered = validLines
        tampered[1] = tampered[1].replacingOccurrences(of: "event\\\":2", with: "event\\\":9")
        XCTAssertFalse(FleetAuditVerifier.verify(lines: tampered) { _ in true }.passed)
    }

    func testAuditRequiresSignatures() throws {
        let unsigned = auditEnvelope(
            sequence: 1, previous: String(repeating: "0", count: 64),
            record: "{}", includeSignature: false
        )
        let line = String(decoding: try JSONEncoder().encode(unsigned), as: UTF8.self)
        XCTAssertFalse(FleetAuditVerifier.verify(lines: [line]) { _ in false }.passed)
    }

    func testEvidenceInvalidationPropagatesTransitively() throws {
        let baseline = EvidenceDependencySnapshot(capturedAt: .now, values: [.backendBuild: "one"])
        let current = EvidenceDependencySnapshot(capturedAt: .now, values: [.backendBuild: "two"])
        let record = try XCTUnwrap(EvidenceInvalidationEngine.compare(baseline, current))
        XCTAssertTrue(record.changedRoots.contains(.backendBuild))
        XCTAssertTrue(record.invalidatedEvidence.contains(.acceptance))
        XCTAssertTrue(record.invalidatedEvidence.contains(.qualification))
        XCTAssertTrue(record.invalidatedEvidence.contains(.releaseDecision))
    }

    func testUnchangedEvidenceDoesNotInvalidate() {
        let snapshot = EvidenceDependencySnapshot(capturedAt: .now, values: [.backendBuild: "same"])
        XCTAssertNil(EvidenceInvalidationEngine.compare(snapshot, snapshot))
    }

    func testStorageEncryptionParsesDiskutilPlist() throws {
        let plist: [String: Any] = [
            "APFSVolumeFileVault": true, "Writable": true,
            "VolumeName": "Encrypted Lab", "APFSVolumeUUID": "VOLUME-1",
            "FilesystemType": "apfs", "Removable": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let report = StorageEncryptionInspector.parse(plist: data, path: "/Volumes/Lab")
        XCTAssertEqual(report.state, .encrypted)
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.volumeUUID, "VOLUME-1")
    }

    func testStorageEncryptionFailsClosedWhenFieldMissing() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["VolumeName": "Mystery"], format: .xml, options: 0
        )
        XCTAssertEqual(StorageEncryptionInspector.parse(plist: data, path: "/tmp").state, .unknown)
    }

    func testStorageEncryptionResolvesLongestContainingMount() {
        let selected = StorageEncryptionInspector.mountedVolume(
            containing: URL(fileURLWithPath: "/Volumes/Lab/VMs/Phone"),
            candidates: [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/Volumes/Lab")]
        )
        XCTAssertEqual(selected?.path, "/Volumes/Lab")
    }

    func testStartupReconciliationFindsInterruptedJournal() {
        let root = temporaryDirectory()
        let entry = OperationJournalEntry(
            id: UUID(), kind: .create, target: "Phone", startedAt: .now,
            updatedAt: .now, state: .interrupted, phase: .preparing,
            recoveryInstruction: "Review disk state.", message: "interrupted"
        )
        let report = StartupReconciler.inspect(paths: paths(root), journal: [entry], stagedUpdate: nil)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.findings.first?.severity, .blocking)
    }

    func testSafeStartupRepairRemovesOnlyNamedStaleSocket() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: paths(root).stateRoot, withIntermediateDirectories: true)
        let socket = paths(root).stateRoot.appendingPathComponent("worker.sock")
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100_000)], ofItemAtPath: socket.path)
        let report = StartupReconciler.inspect(paths: paths(root), journal: [], stagedUpdate: nil)
        XCTAssertEqual(report.findings.count, 1)
        let repaired = StartupReconciler.repairSafeFindings(report, paths: paths(root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertTrue(repaired.passed)
    }

    func testAtomicComponentUpgradeStagesAndCommitsVerifiedSet() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: paths(root).stateRoot, withIntermediateDirectories: true)
        let artifact = root.appendingPathComponent("backend")
        try Data("version-two".utf8).write(to: artifact)
        let versions = ComponentVersionSet(
            manager: "0.14.0", backend: "0.9.0", guestCompanion: "3.1.0",
            protocolVersion: BackendAdapterConformance.protocolVersion,
            schemaVersion: LabMigrationManager.currentSchemaVersion
        )
        let staged = try ComponentUpgradeCoordinator.stage(
            sources: [("backend", artifact)], from: versions, to: versions, paths: paths(root)
        )
        XCTAssertEqual(staged.phase, .staged)
        let approved = ComponentUpgradeCoordinator.approve(staged)
        XCTAssertEqual(approved.phase, .approved)
        let committed = try ComponentUpgradeCoordinator.commit(
            approved, healthChecks: ["launch": true], paths: paths(root)
        )
        XCTAssertEqual(committed.phase, .committed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths(root).stateRoot.appendingPathComponent("active-component-set.json").path))
    }

    func testAtomicComponentUpgradeRejectsIncompatibleProtocol() {
        let versions = ComponentVersionSet(
            manager: "0.14.0", backend: "0.9.0", guestCompanion: "4",
            protocolVersion: 99, schemaVersion: LabMigrationManager.currentSchemaVersion
        )
        let artifact = ComponentArtifact(
            component: "backend", sourcePath: "/tmp/a", stagedPath: "/tmp/b",
            sha256: String(repeating: "a", count: 64), sizeBytes: 1
        )
        let transaction = ComponentUpgradeTransaction(
            id: UUID(), createdAt: .now, updatedAt: .now, from: versions, to: versions,
            artifacts: [artifact], rollbackRoot: "/tmp/r", phase: .staged,
            healthChecks: [:], message: ""
        )
        XCTAssertTrue(ComponentUpgradeCoordinator.validate(transaction).contains { $0.contains("protocol") })
    }

    func testSupplyChainPolicyBlocksDeniedLicenseAndCriticalVulnerability() {
        let component = SoftwareComponentRecord(
            id: "pkg:swift/bad@1", name: "bad", version: "1",
            licenses: ["AGPL-3.0-only"], maximumSeverity: .critical,
            vulnerabilityIDs: ["CVE-TEST"]
        )
        let result = SupplyChainPolicyEvaluator.evaluate(
            policy: .standard, components: [component], sbomSHA256: String(repeating: "a", count: 64),
            sourceRevision: "abcdef1", provenanceVerified: true
        )
        XCTAssertFalse(result.passed)
        XCTAssertGreaterThanOrEqual(result.issues.count, 2)
    }

    func testSupplyChainPolicyAcceptsCompliantEvidence() {
        let component = SoftwareComponentRecord(
            id: "pkg:swift/good@1", name: "good", version: "1",
            licenses: ["MIT"], maximumSeverity: .low, vulnerabilityIDs: []
        )
        XCTAssertTrue(SupplyChainPolicyEvaluator.evaluate(
            policy: .standard, components: [component], sbomSHA256: String(repeating: "a", count: 64),
            sourceRevision: "abcdef1", provenanceVerified: true
        ).passed)
    }

    func testLifecycleRequiresNoticeWindowAndMigrationTarget() {
        let entry = SupportLifecycleEntry(
            id: "old", component: "Old backend", versionRange: "1.x", status: .deprecated,
            deprecatedAt: .now, endOfLifeAt: Date(timeIntervalSinceNow: 10 * 86_400),
            migrationTarget: nil, rationale: "Old"
        )
        let result = SupportLifecycleEvaluator.evaluate(
            SupportLifecyclePolicy(minimumDeprecationNoticeDays: 90, entries: [entry], updatedAt: .now)
        )
        XCTAssertFalse(result.passed)
        XCTAssertGreaterThanOrEqual(result.issues.count, 2)
    }

    func testDefaultLifecyclePolicyPasses() {
        XCTAssertTrue(SupportLifecycleEvaluator.evaluate(.standard).passed)
    }

    func testOperationsEvaluatorAlwaysReportsTenFailClosedGates() {
        let report = OperationsHardeningEvaluator.evaluate(.empty)
        XCTAssertEqual(report.gates.count, 10)
        XCTAssertFalse(report.releaseReady)
        XCTAssertEqual(Set(report.gates.map(\.kind)), Set(OperationsGateKind.allCases))
    }

    func testOperationsStateRoundTripsAtomically() throws {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: paths(root).stateRoot, withIntermediateDirectories: true)
        var state = OperationsHardeningState.empty
        state.fleetProtocol = passingFleetEvidence()
        state.lifecycleAssessment = SupportLifecycleEvaluator.evaluate(state.lifecyclePolicy)
        state.report = OperationsHardeningEvaluator.evaluate(state)
        try OperationsHardeningStore.save(state, paths: paths(root))
        let loaded = OperationsHardeningStore.load(paths: paths(root))
        XCTAssertEqual(loaded.fleetProtocol.serverVersion, state.fleetProtocol.serverVersion)
        XCTAssertEqual(loaded.report.gates, state.report.gates)
        XCTAssertEqual(loaded.supplyChainPolicy, state.supplyChainPolicy)
    }

    private func passingFleetEvidence() -> FleetWorkerProtocolEvidence {
        FleetWorkerProtocolEvidence(
            schemaVersion: 1, generatedAt: .now, serverVersion: "1.1.0",
            controllerHostID: "controller", workerHostIDs: ["worker"],
            capabilities: Set(FleetWorkerCapability.allCases), mutuallyAuthenticated: true,
            idempotencyVerified: true, cancellationVerified: true,
            boundedPayloadsVerified: true, passed: true,
            sourceSHA256: String(repeating: "a", count: 64)
        )
    }

    private func auditEnvelope(
        sequence: UInt64, previous: String, record: String, includeSignature: Bool = true
    ) -> FleetAuditEnvelope {
        let hash = SHA256.hash(data: Data("\(sequence)\n\(previous)\n\(record)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return FleetAuditEnvelope(
            sequence: sequence, previousHash: previous, recordHash: hash,
            signature: includeSignature ? Data("signature".utf8).base64EncodedString() : nil,
            signingCertificateSHA256: includeSignature ? String(repeating: "a", count: 64) : nil,
            canonicalRecord: record
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vdl-hardening-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func paths(_ root: URL) -> LabPaths {
        LabPaths(
            dataRoot: root, libraryRoot: root.appendingPathComponent("VMs"),
            firmwareRoot: root.appendingPathComponent("ipsws"),
            snapshotsRoot: root.appendingPathComponent("Snapshots"),
            stateRoot: root.appendingPathComponent("State")
        )
    }
}
