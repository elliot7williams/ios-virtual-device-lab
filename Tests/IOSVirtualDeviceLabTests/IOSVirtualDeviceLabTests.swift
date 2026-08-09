import Foundation
import XCTest
@testable import IOSVirtualDeviceLab

final class IOSVirtualDeviceLabTests: XCTestCase {
    func testParsesStandardIPSWFilename() {
        let parsed = FirmwareFilenameParser.parse("iPhone17,3_26.1_23B85_Restore.ipsw")
        XCTAssertEqual(parsed.device, "iPhone17,3")
        XCTAssertEqual(parsed.version, "26.1")
        XCTAssertEqual(parsed.build, "23B85")
    }

    func testUnknownFirmwareFilenameDegradesGracefully() {
        let parsed = FirmwareFilenameParser.parse("custom-firmware.ipsw")
        XCTAssertNil(parsed.device)
        XCTAssertNil(parsed.version)
        XCTAssertNil(parsed.build)
    }

    func testSnapshotNameSanitizer() {
        XCTAssertEqual(NameSanitizer.fileComponent("Clean install / beta 1"), "Clean-install-beta-1")
        XCTAssertEqual(NameSanitizer.fileComponent("***"), "snapshot")
    }

    func testProcessExecutorCapturesOutputAndStatus() {
        let success = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello", "lab"]
        )
        XCTAssertTrue(success.succeeded)
        XCTAssertEqual(success.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello lab")

        let failure = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/false")
        )
        XCTAssertEqual(failure.exitCode, 1)
    }

    func testDirectBundleScannerReadsBackendFormat() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-virtual-device-lab-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = LabPaths(
            dataRoot: root,
            libraryRoot: root.appendingPathComponent("VMs"),
            firmwareRoot: root.appendingPathComponent("ipsws"),
            snapshotsRoot: root.appendingPathComponent("Snapshots"),
            stateRoot: root.appendingPathComponent("VirtualDeviceLab")
        )
        let backend = VPhoneBackend(paths: paths)
        try await backend.prepareStorage()

        let bundle = paths.libraryRoot.appendingPathComponent("test-phone")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "cpuCount": 6,
            "memorySize": 4_294_967_296 as Int64,
            "diskImage": "Disk.img",
            "networkConfig": [
                "mode": "nat",
                "macAddress": "02:00:00:00:00:01",
            ],
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: bundle.appendingPathComponent("config.plist"))
        try Data(repeating: 0, count: 1_024).write(to: bundle.appendingPathComponent("Disk.img"))

        let restore: [String: Any] = [
            "ios": ["version": "26.1", "build": "23B85"],
            "cloudOS": ["version": "26.1", "build": "23B85"],
            "variant": "regular",
            "device": "iPhone17,3",
        ]
        let restoreData = try JSONSerialization.data(withJSONObject: restore)
        try restoreData.write(to: bundle.appendingPathComponent("restore-info.json"))

        let devices = await backend.listDevices()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].name, "test-phone")
        XCTAssertEqual(devices[0].cpuCount, 6)
        XCTAssertEqual(devices[0].memoryMB, 4_096)
        XCTAssertEqual(devices[0].restoreInfo?.ios.version, "26.1")
        XCTAssertFalse(devices[0].isRunning)
    }

    func testCompatibilityManifestMatchesSpecificAndResearchEntries() throws {
        let manifestURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/compatibility-manifest.json")
        let manifest = try JSONDecoder().decode(
            CompatibilityManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let supported = FirmwareImage.inspect(
            URL(fileURLWithPath: "/tmp/iPhone17,3_26.1_23B85_Restore.ipsw")
        )
        let researching = FirmwareImage.inspect(
            URL(fileURLWithPath: "/tmp/iPhone10,6_15.8_19H370_Restore.ipsw")
        )
        let cloud = FirmwareImage.inspect(
            URL(fileURLWithPath: "/tmp/UniversalMac_26.1_23B85_Restore.ipsw"),
            kind: .cloudOS
        )
        XCTAssertEqual(manifest.status(for: supported), .supported)
        XCTAssertEqual(manifest.status(for: researching), .researching)
        XCTAssertEqual(manifest.status(for: cloud), .supported)
        XCTAssertGreaterThanOrEqual(manifest.schemaVersion, 1)
    }

    func testSnapshotChecksumDetectsMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-integrity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        let backend = VPhoneBackend(paths: paths)
        try await backend.prepareStorage()
        let archive = paths.snapshotsRoot.appendingPathComponent("sample.tgz")
        try Data("first".utf8).write(to: archive)
        let record = SnapshotRecord(
            id: UUID(),
            name: "Sample",
            sourceVM: "test",
            createdAt: .now,
            archivePath: archive.path,
            sizeBytes: 5
        )

        let first = await backend.verifySnapshot(record)
        XCTAssertEqual(first.status, .verified)
        try FileHandle(forWritingTo: archive).write(contentsOf: Data("changed".utf8))
        let second = await backend.verifySnapshot(first.snapshot)
        XCTAssertEqual(second.status, .changed)
    }

    func testFirmwareValidationRejectsNonArchive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("firmware-validation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        let backend = VPhoneBackend(paths: paths)
        try await backend.prepareStorage()
        let ipsw = root.appendingPathComponent("iPhone17,3_26.1_23B85_Restore.ipsw")
        try Data("not a zip".utf8).write(to: ipsw)
        let imported = try await backend.importFirmware([ipsw], kind: .iPhone)
        let manifest = CompatibilityCatalog.load(paths: paths)
        let validated = try await backend.validateFirmware(imported[0], compatibility: manifest)
        XCTAssertEqual(validated[0].validation?.state, .invalid)
        XCTAssertNotNil(validated[0].sha256)
    }

    func testProcessExecutorTimeoutAndCancellation() async {
        let timed = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["5"],
            timeout: 0.05
        )
        XCTAssertTrue(timed.timedOut)

        let control = ProcessControl()
        let task = Task {
            await ProcessExecutor.runAsync(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                control: control
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        control.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled.cancelled)
    }

    func testMockBackendAndBuiltInWorkflows() async {
        let backend: any LabBackend = MockLabBackend()
        let readiness = await backend.checkHost()
        XCTAssertTrue(readiness.isReady)
        XCTAssertEqual(WorkflowStore.builtIns.count, 3)
        XCTAssertTrue(WorkflowStore.builtIns[0].steps.contains { $0.action == .screenshot })
    }

    func testPluginRegistryLoadsAndRunsDeclaredCapability() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-registry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        try PluginRegistry.prepare(paths: paths)
        let plugin = PluginDescriptor(
            id: "test.echo",
            name: "Echo",
            version: "1.0.0",
            executable: "/bin/echo",
            capabilities: ["diagnostics"],
            arguments: ["plugin"],
            description: nil
        )
        let data = try JSONEncoder().encode(plugin)
        try data.write(to: PluginRegistry.root(paths: paths).appendingPathComponent("echo.json"))
        let loaded = PluginRegistry.loadPlugins(paths: paths)
        XCTAssertEqual(loaded.map(\.id), ["test.echo"])
        let result = await PluginRegistry.run(
            loaded[0],
            capability: "diagnostics",
            device: nil,
            paths: paths,
            onLine: { _ in }
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.output.contains("plugin diagnostics"))
    }

    private func makePaths(root: URL) -> LabPaths {
        LabPaths(
            dataRoot: root,
            libraryRoot: root.appendingPathComponent("VMs"),
            firmwareRoot: root.appendingPathComponent("ipsws"),
            snapshotsRoot: root.appendingPathComponent("Snapshots"),
            stateRoot: root.appendingPathComponent("VirtualDeviceLab")
        )
    }
}
