import Foundation
import AppKit
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

    func testBuildManifestOverridesMisleadingIPSWFilename() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-inspection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "ProductVersion": "14.8.1",
            "ProductBuildVersion": "18H107",
            "SupportedProductTypes": ["iPhone10,6"],
            "BuildIdentities": [[
                "ApBoardID": 10,
                "ApChipID": 32784,
                "Info": ["DeviceClass": "d221ap", "Variant": "Customer Erase Install"],
            ]],
        ]
        let manifestData = try PropertyListSerialization.data(fromPropertyList: manifest, format: .binary, options: 0)
        try manifestData.write(to: root.appendingPathComponent("BuildManifest.plist"))
        let ipsw = root.appendingPathComponent("iPhone17,3_26.1_23B85_Restore.ipsw")
        let zipped = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-q", ipsw.path, "BuildManifest.plist"],
            currentDirectory: root
        )
        XCTAssertTrue(zipped.succeeded)

        let backend = VPhoneBackend(paths: makePaths(root: root.appendingPathComponent("lab")))
        try await backend.prepareStorage()
        let imported = try await backend.importFirmware([ipsw], kind: .iPhone)
        XCTAssertEqual(imported.first?.version, "14.8.1")
        XCTAssertEqual(imported.first?.build, "18H107")
        XCTAssertEqual(imported.first?.device, "iPhone10,6")
        let validated = try await backend.validateFirmware(imported[0], compatibility: .empty)
        XCTAssertEqual(validated[0].manifestMetadata?.buildIdentities.first?.deviceClass, "d221ap")
        XCTAssertTrue(validated[0].validation?.issues.contains { $0.contains("Filename iOS") } == true)
    }

    func testDiagnosticSanitizerAndClassifier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-sanitizer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("raw")
        let destination = root.appendingPathComponent("sanitized")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "Authorization: Bearer secret-token-123456\nuser@example.com\nkernel panic detected\n"
            .write(to: source.appendingPathComponent("panic.log"), atomically: true, encoding: .utf8)
        try "serial number".write(
            to: source.appendingPathComponent("host-system-profile.txt"),
            atomically: true,
            encoding: .utf8
        )
        let preview = try DiagnosticSanitizer.sanitize(
            source: source,
            destination: destination,
            policy: .standard
        )
        XCTAssertGreaterThanOrEqual(preview.redactions, 2)
        XCTAssertEqual(preview.filesExcluded, 1)
        let sanitized = try String(contentsOf: destination.appendingPathComponent("panic.log"), encoding: .utf8)
        XCTAssertFalse(sanitized.contains("secret-token"))
        XCTAssertFalse(sanitized.contains("user@example.com"))
        let report = try DiagnosticAnalyzer.analyze(destination)
        XCTAssertTrue(report.findings.contains { $0.classification == .kernelPanic })
        let encrypted = root.appendingPathComponent("diagnostics.vdlenc")
        let decrypted = root.appendingPathComponent("diagnostics.zip")
        _ = try DiagnosticSanitizer.encryptedArchive(
            of: destination,
            destination: encrypted,
            passphrase: "correct horse battery staple"
        )
        _ = try DiagnosticSanitizer.decryptArchive(
            encrypted,
            destination: decrypted,
            passphrase: "correct horse battery staple"
        )
        XCTAssertEqual(try Data(contentsOf: decrypted).prefix(2), Data([0x50, 0x4B]))
    }

    func testResourceGateQueuesBeyondConcurrencyAndMemoryBudget() async {
        let gate = LabResourceGate(policy: LabResourcePolicy(
            maximumConcurrentVMs: 1,
            maximumAggregateMemoryMB: 4_096,
            reservedHostMemoryMB: 1_024,
            maximumHostCPUPercent: 100
        ))
        await gate.acquire(memoryMB: 4_096)
        let waiter = Task { await gate.acquire(memoryMB: 4_096) }
        try? await Task.sleep(for: .milliseconds(50))
        let queuedState = await gate.state()
        XCTAssertEqual(queuedState, LabResourceGate.State(runningCount: 1, reservedMemoryMB: 4_096, waitingCount: 1))
        await gate.release(memoryMB: 4_096)
        await waiter.value
        let resumedState = await gate.state()
        XCTAssertEqual(resumedState.runningCount, 1)
        await gate.release(memoryMB: 4_096)
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
            description: nil,
            trusted: false,
            permissions: ["diagnostics"]
        )
        let data = try JSONEncoder().encode(plugin)
        try data.write(to: PluginRegistry.root(paths: paths).appendingPathComponent("echo.json"))
        let loaded = PluginRegistry.loadPlugins(paths: paths)
        XCTAssertEqual(loaded.map(\.id), ["test.echo"])
        let blocked = await PluginRegistry.run(
            loaded[0],
            capability: "diagnostics",
            device: nil,
            paths: paths,
            onLine: { _ in }
        )
        XCTAssertFalse(blocked.succeeded)
        XCTAssertTrue(blocked.output.contains("not trusted"))

        try PluginRegistry.setTrusted(loaded[0], trusted: true, paths: paths)
        let trusted = try XCTUnwrap(PluginRegistry.loadPlugins(paths: paths).first)
        XCTAssertTrue(trusted.trusted == true)
        XCTAssertNotNil(trusted.executableSHA256)
        let result = await PluginRegistry.run(
            trusted,
            capability: "diagnostics",
            device: nil,
            paths: paths,
            onLine: { _ in }
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.output.contains("plugin diagnostics"))
    }

    func testHardwareProfilesAndOlderIOSRecommendation() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let paths = makePaths(root: root)
        let profiles = HardwareProfilesCatalog.load(paths: paths)
        XCTAssertGreaterThanOrEqual(profiles.profiles.count, 6)
        XCTAssertEqual(profiles.profile(id: "iphone-x-a11")?.soc, "A11 Bionic")

        let compatibility = CompatibilityCatalog.load(paths: paths)
        let ios15 = FirmwareImage.inspect(
            URL(fileURLWithPath: "/tmp/iPhone10,6_15.8_19H370_Restore.ipsw")
        )
        let recommendation = CompatibilityEvaluator.recommend(
            iphone: ios15,
            catalog: compatibility,
            profiles: profiles,
            availableFirmware: [ios15]
        )
        XCTAssertEqual(recommendation.status, .researching)
        XCTAssertEqual(recommendation.decision, .warning)
        XCTAssertEqual(recommendation.hardwareProfile?.id, "iphone-x-a11")
    }

    func testCompatibilityGateBlocksMismatchedHardware() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let paths = makePaths(root: root)
        let profiles = HardwareProfilesCatalog.load(paths: paths)
        let profile = try XCTUnwrap(profiles.profile(id: "iphone-x-a11"))
        let image = FirmwareImage.inspect(
            URL(fileURLWithPath: "/tmp/iPhone17,3_26.1_23B85_Restore.ipsw")
        )
        let request = VMCreationRequest(
            operationID: UUID(),
            name: "mismatch",
            hardwareProfile: profile,
            variant: .regular,
            diskSizeGB: 64,
            iphoneFirmware: image,
            cloudOSFirmware: nil,
            network: .standard,
            audio: .playback,
            isolation: .strict,
            allowUnverifiedFirmware: true
        )
        let result = CompatibilityEvaluator.evaluate(
            request,
            compatibility: CompatibilityCatalog.load(paths: paths)
        )
        XCTAssertEqual(result.decision, .blocked)
        XCTAssertTrue(result.messages.contains { $0.contains("does not match") })
    }

    func testAssertionEvaluatorProducesExplicitPassFailEvidence() {
        let screenshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("assertion-screen-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: screenshot) }
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 32).fill()
        NSColor.white.setFill()
        NSRect(x: 16, y: 0, width: 16, height: 32).fill()
        image.unlockFocus()
        let bitmap = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        try? bitmap?.representation(using: .png, properties: [:])?.write(to: screenshot)
        let assertions = TestAssertion.deploymentDefaults + [
            TestAssertion(.maximumDuration, expectedValue: "10")
        ]
        let command = CommandResult(
            executable: "mock",
            arguments: [],
            output: "ok",
            exitCode: 0,
            duration: 4
        )
        let results = TestAssertionEvaluator.evaluate(
            assertions,
            guestReady: true,
            launch: command,
            screenshotPath: screenshot.path,
            diagnosticPath: nil,
            duration: 4
        )
        XCTAssertEqual(results.count, assertions.count)
        XCTAssertTrue(results.allSatisfy(\.passed))
    }

    func testAppArtifactLibraryCopiesAndRemovesBuild() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        let source = root.appendingPathComponent("Music.ipa")
        try Data("sample-app".utf8).write(to: source)
        let imported = try AppArtifactStore.importArtifact(source, paths: paths)
        XCTAssertEqual(imported.count, 1)
        XCTAssertNotNil(imported[0].sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported[0].path))
        let remaining = try AppArtifactStore.remove(imported[0], paths: paths)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testTestReportIncludesAssertions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        let assertion = TestAssertion(.guestReady)
        let run = TestRunRecord(
            id: UUID(),
            kind: .deployment,
            name: "Music Compatibility",
            packagePath: "/tmp/Music.ipa",
            createdAt: .now,
            completedAt: .now,
            state: .passed,
            results: [DeviceTestResult(
                id: UUID(),
                deviceName: "iOS 15",
                state: .passed,
                message: "1/1 assertions passed",
                screenshotPath: nil,
                diagnosticBundlePath: nil,
                startedAt: .now,
                completedAt: .now,
                assertionResults: [TestAssertionResult(assertion: assertion, passed: true, message: "Connected")]
            )]
        )
        let report = try TestReportStore.write(run, paths: paths)
        let text = try String(contentsOf: report, encoding: .utf8)
        XCTAssertTrue(text.contains("Music Compatibility"))
        XCTAssertTrue(text.contains("Guest control connected"))
    }

    @MainActor
    func testSnapshotRetentionKeepsNewestPerDevice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("retention-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        let now = Date()
        let snapshots = (0..<4).map { index in
            SnapshotRecord(
                id: UUID(),
                name: "Snapshot \(index)",
                sourceVM: "music-lab",
                createdAt: now.addingTimeInterval(TimeInterval(-index * 86_400)),
                archivePath: "/mock/\(index).tgz",
                sizeBytes: 1_024
            )
        }
        let backend = MockLabBackend(snapshots: snapshots)
        let model = LabAppModel(paths: paths, backend: backend)
        await model.bootstrap()
        model.updateSnapshotRetention(SnapshotRetentionPolicy(
            isEnabled: true,
            keepLastPerDevice: 2,
            maximumAgeDays: 1,
            maximumTotalBytes: .max,
            verifyBeforePruning: true
        ))
        let result = await model.applySnapshotRetention()
        XCTAssertEqual(result.removed.count, 2)
        XCTAssertEqual(model.snapshots.count, 2)
    }

    func testDeveloperHelperGeneration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("developer-helper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        let helper = try DeveloperTools.installHelper(paths: paths, vdlctlPath: "/opt/homebrew/bin/vdlctl")
        let text = try String(contentsOf: helper, encoding: .utf8)
        XCTAssertTrue(text.contains("vdlctl"))
        XCTAssertTrue(text.contains("deploy --device"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
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
