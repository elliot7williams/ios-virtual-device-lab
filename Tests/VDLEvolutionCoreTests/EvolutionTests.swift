import Foundation
import XCTest
@testable import VDLEvolutionCore

final class EvolutionTests: XCTestCase {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vdl-evolution-test-\(UUID().uuidString)")
        try EvolutionFiles.directory(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testArtifactQuarantineDedupAndVerifiedExport() throws {
        let root = try temporary(), source = root.appendingPathComponent("app.ipa")
        try Data("payload".utf8).write(to: source)
        let registry = ArtifactRegistry(root: root.appendingPathComponent("registry"))
        let first = try registry.ingest(source, kind: .ipa, provenance: "test-build")
        XCTAssertNil(first.approvedAt)
        XCTAssertEqual(try registry.ingest(source, kind: .ipa, provenance: "another build").id, first.id)
        XCTAssertEqual(try registry.list().count, 1)
        let output = root.appendingPathComponent("export.ipa")
        XCTAssertThrowsError(try registry.export(first.id, to: output))
        _ = try registry.approve(first.id)
        try registry.export(first.id, to: output)
        XCTAssertEqual(try Data(contentsOf: output), Data("payload".utf8))
        XCTAssertThrowsError(try registry.export(first.id, to: output))
    }
    func testArtifactRejectsSymlinkAndCorruption() throws {
        let root = try temporary(), source = root.appendingPathComponent("source")
        try Data("payload".utf8).write(to: source)
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let registry = ArtifactRegistry(root: root.appendingPathComponent("registry"))
        XCTAssertThrowsError(try registry.ingest(link, kind: .testAsset, provenance: "test"))
        let artifact = try registry.ingest(source, kind: .testAsset, provenance: "test")
        let object = registry.root.appendingPathComponent("objects/\(artifact.id.prefix(2))/\(artifact.id)")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: object.path)
        try Data("corrupt".utf8).write(to: object)
        XCTAssertThrowsError(try registry.approve(artifact.id))
    }
    func testResumableTransferChecksExistingPrefix() throws {
        let root = try temporary(), source = root.appendingPathComponent("source"), partial = root.appendingPathComponent("partial")
        let content = Data(repeating: 42, count: 2_000_000)
        try content.write(to: source); try content.prefix(500000).write(to: partial)
        let registry = ArtifactRegistry(root: root.appendingPathComponent("registry")), digest = EvolutionFiles.digest(content)
        XCTAssertEqual(try registry.resumeTransfer(digest, from: source, partial: partial), 2_000_000)
        XCTAssertEqual(try Data(contentsOf: partial), content)
        try Data("wrong".utf8).write(to: partial)
        XCTAssertThrowsError(try registry.resumeTransfer(digest, from: source, partial: partial))
    }
    func testFixtureBoundsAndDeterministicLoss() throws {
        var scenario = NetworkFixtureScenario(); scenario.lossPercent = 47
        try scenario.validate()
        XCTAssertEqual(scenario.drops("GET /health"), scenario.drops("GET /health"))
        scenario.offline = true; XCTAssertTrue(scenario.drops("anything"))
        scenario.latencyMilliseconds = -1; XCTAssertThrowsError(try scenario.validate())
    }
    func testResumeRejectsDanglingSymlinkWithoutCreatingItsTarget() throws {
        let root = try temporary(), source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("must-not-be-created"), partial = root.appendingPathComponent("partial")
        try Data("payload".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: partial, withDestinationURL: target)
        let registry = ArtifactRegistry(root: root.appendingPathComponent("registry"))
        XCTAssertThrowsError(try registry.resumeTransfer(EvolutionFiles.digest(Data("payload".utf8)), from: source, partial: partial))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testFleetRejectsReportsFromAnEarlierAttempt() {
        let claim = Date()
        XCTAssertFalse(FleetScheduler.isCurrentAttempt(reportAt: claim.addingTimeInterval(-1), claimedAt: claim))
        XCTAssertTrue(FleetScheduler.isCurrentAttempt(reportAt: claim, claimedAt: claim))
        XCTAssertTrue(FleetScheduler.isCurrentAttempt(reportAt: claim.addingTimeInterval(1), claimedAt: claim))
    }
    func testFixtureRejectsHeaderInjectionAndDuplicateRoutes() {
        var scenario = NetworkFixtureScenario()
        scenario.responses = [HTTPFixture(path: "/", contentType: "text/plain\r\nX: injected", body: "x")]
        XCTAssertThrowsError(try scenario.validate())
        scenario.responses = [HTTPFixture(path: "/", body: "x"), HTTPFixture(path: "/", body: "y")]
        XCTAssertThrowsError(try scenario.validate())
    }
    func testDNSFixtureAAndNXDomain() {
        let query = Data([0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 5] + Array("radio".utf8) + [4] + Array("test".utf8) + [0, 0, 1, 0, 1])
        let reply = DNSFixture.response(to: query, records: ["radio.test": "127.0.0.1"])
        XCTAssertEqual(reply?.suffix(4), Data([127, 0, 0, 1]))
        XCTAssertEqual(DNSFixture.response(to: query, records: [:])?[3], 0x83)
        XCTAssertNil(DNSFixture.response(to: Data([1]), records: [:]))
    }
    func testSchedulerPriorityAgingQuotaAndMaintenance() {
        let now = Date(), policy = FleetSchedulingPolicy(), host = FleetHostMaintenance(hostID: "host", draining: false)
        let old = FleetScheduleEntry(id: UUID(), subject: "old", submittedAt: now.addingTimeInterval(-3600), priority: 0)
        let urgent = FleetScheduleEntry(id: UUID(), subject: "new", submittedAt: now, priority: 10)
        XCTAssertEqual(FleetScheduler.next(entries: [urgent, old], host: host, capabilities: [], activeCount: 0, policy: policy, now: now)?.id, old.id)
        XCTAssertNil(FleetScheduler.next(entries: [old], host: host, capabilities: [], activeCount: 1, policy: policy))
        XCTAssertNil(FleetScheduler.next(entries: [old], host: FleetHostMaintenance(hostID: "host", draining: true), capabilities: [], activeCount: 0, policy: policy))
        XCTAssertNil(FleetScheduler.next(entries: [old], host: FleetHostMaintenance(hostID: "host", draining: false, unavailableUntil: now.addingTimeInterval(600)), capabilities: [], activeCount: 0, policy: policy))
    }
    func testSchedulerCapabilitiesAndBoundedRetry() throws {
        let now = Date(), policy = FleetSchedulingPolicy(), host = FleetHostMaintenance(hostID: "host", draining: false)
        var entry = FleetScheduleEntry(id: UUID(), subject: "team", submittedAt: now, requiredCapabilities: ["audio"])
        XCTAssertNil(FleetScheduler.next(entries: [entry], host: host, capabilities: [], activeCount: 0, policy: policy))
        entry.attempts = 2; entry.hostID = "host"
        let retried = try FleetScheduler.retry(entry, policy: policy, now: now)
        XCTAssertEqual(retried.eligibleAt.timeIntervalSince(now), 60)
        XCTAssertNil(retried.hostID)
        entry.attempts = 3; XCTAssertThrowsError(try FleetScheduler.retry(entry, policy: policy))
    }
    func testRecoveryArchiveRoundTripAndTamperRejection() throws {
        let root = try temporary(), state = root.appendingPathComponent("state"), backup = root.appendingPathComponent("backup")
        try EvolutionFiles.save(["job": "pending"], state.appendingPathComponent("Inbox/job.json"))
        try FleetRecoveryArchive.snapshot(root: state, destination: backup)
        let restored = root.appendingPathComponent("restored")
        try FleetRecoveryArchive.restore(source: backup, destination: restored)
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("Inbox/job.json")), try Data(contentsOf: restored.appendingPathComponent("Inbox/job.json")))
        try Data("edited".utf8).write(to: backup.appendingPathComponent("Inbox/job.json"))
        XCTAssertThrowsError(try FleetRecoveryArchive.restore(source: backup, destination: root.appendingPathComponent("bad")))
    }
    func testRecoveryRejectsTraversalBeforeCreatingOutput() throws {
        let root = try temporary(), backup = root.appendingPathComponent("backup"), target = root.appendingPathComponent("target")
        try EvolutionFiles.save(["../outside": String(repeating: "a", count: 64)], backup.appendingPathComponent("checksums.json"))
        XCTAssertThrowsError(try FleetRecoveryArchive.restore(source: backup, destination: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testSavedStateRequiresExactBindingAndBackendSupport() throws {
        let root = try temporary(), file = root.appendingPathComponent("state")
        try Data("state".utf8).write(to: file)
        let binding = SavedMachineBinding(hostBuild: "25A", hostArchitecture: "arm64", backendVersion: "0.8", firmwareSHA256: String(repeating: "a", count: 64), hardwareProfileID: "pv3")
        let manifest = SavedMachineManifest(deviceID: "device", binding: binding, stateSHA256: EvolutionFiles.digest(Data("state".utf8)), stateBytes: 5)
        XCTAssertTrue(SavedMachineValidator.validate(manifest, current: binding, deviceID: "device", stateFile: file, backendAdvertisesRestore: true).isEmpty)
        XCTAssertFalse(SavedMachineValidator.validate(manifest, current: binding, deviceID: "device", stateFile: file, backendAdvertisesRestore: false).isEmpty)
        let changed = SavedMachineBinding(hostBuild: "26A", hostArchitecture: "arm64", backendVersion: "0.8", firmwareSHA256: binding.firmwareSHA256, hardwareProfileID: "pv3")
        XCTAssertFalse(SavedMachineValidator.validate(manifest, current: changed, deviceID: "device", stateFile: file, backendAdvertisesRestore: true).isEmpty)
    }
    func testMatrixRejectsUnapprovedExecutablesAndMissingMigration() throws {
        let row = CompatibilityMatrixRow(id: "current", manager: "0.15", backend: "0.8", guestProtocol: 3, fleetProtocol: 1, stateSchema: 11, migrationFromSchema: 10,
            downgradeSupported: true, probes: [VersionProbe(component: "manager", executable: "/bin/echo", arguments: ["0.15"], expectedOutput: "0.15")])
        let result = try CompatibilityMatrixRunner.run(row, allowedExecutables: [])
        XCTAssertFalse(result.passed); XCTAssertTrue(result.probes.isEmpty)
        XCTAssertTrue(result.issues.contains { $0.contains("downgrade") })
        XCTAssertTrue(result.issues.contains { $0.contains("approved") })
    }
    func testMatrixExecutesApprovedProbesAndPinsSourceRow() throws {
        let probes = ["manager", "backend", "companion", "fleet-server", "fleet-worker", "migration"].map {
            VersionProbe(component: $0, executable: "/bin/echo", arguments: ["fixture-pass"], expectedOutput: "fixture-pass")
        }
        let row = CompatibilityMatrixRow(id: "fixture", manager: "0.15", backend: "0.8", guestProtocol: 3, fleetProtocol: 1, stateSchema: 11, migrationFromSchema: 10, downgradeSupported: false, probes: probes)
        let result = try CompatibilityMatrixRunner.run(row, allowedExecutables: ["/bin/echo"])
        XCTAssertTrue(result.passed); XCTAssertEqual(result.probes.count, 6); XCTAssertTrue(EvolutionFiles.validDigest(result.sourceRowSHA256))
    }
    func testXCTestCasesAndSafeReports() throws {
        let raw = Data(#"{"testNodes":[{"name":"Suite","children":[{"name":"test<unsafe>","nodeType":"Test Case","nodeIdentifier":"Suite/test<unsafe>","result":"Failed","duration":"0.25s"},{"name":"skip","nodeType":"Test Case","result":"Skipped"}]}]}"#.utf8)
        let cases = try XCTestBridge.parseCases(raw)
        XCTAssertEqual(cases.count, 2); XCTAssertEqual(cases[0].durationSeconds, 0.25)
        let report = XCTestImportReport(id: UUID(), importedAt: .now, bundlePath: "test.xcresult", summarySHA256: EvolutionFiles.digest(raw), cases: cases, attachmentsPath: nil, diagnosticsPath: nil, coveragePath: nil)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(XCTestBridge.junit(report).contains("&lt;unsafe&gt;"))
        XCTAssertFalse(XCTestBridge.html(report).contains("test<unsafe>"))
        XCTAssertThrowsError(try XCTestBridge.parseCases(Data("{}".utf8)))
    }
    func testXcodeRequestUsesArgumentsWithoutShellInterpolation() throws {
        let root = try temporary(), output = root.appendingPathComponent("test.xcresult")
        let request = XcodeTestRequest(projectPath: root.appendingPathComponent("My App.xcodeproj").path, scheme: "App $(ignored)", testPlan: "Plan", destination: "platform=macOS", resultBundlePath: output.path)
        let arguments = try request.arguments()
        XCTAssertTrue(arguments.contains("App $(ignored)")); XCTAssertTrue(arguments.contains("-testPlan"))
        try EvolutionFiles.directory(output); XCTAssertThrowsError(try request.arguments())
    }
    func testBoundedProcessTimeoutReturns() {
        let result = EvolutionProcess.run("/bin/sleep", ["5"], timeout: 0.05)
        XCTAssertTrue(result.timedOut); XCTAssertFalse(result.passed)
    }
}
