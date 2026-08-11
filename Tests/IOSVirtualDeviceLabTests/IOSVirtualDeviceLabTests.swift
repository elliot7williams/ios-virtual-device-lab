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

    func testProcessExecutorEnforcesOutputLimitDuringExecution() {
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/yes"),
            timeout: 5,
            maximumOutputBytes: 1_024
        )
        XCTAssertTrue(result.outputLimitExceeded)
        XCTAssertLessThanOrEqual(result.output.lengthOfBytes(using: .utf8), 1_024)
        XCTAssertTrue(result.cancelled)
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
        let audit = PluginAuditStore.load(paths: paths)
        XCTAssertEqual(audit.first?.pluginID, "test.echo")
        XCTAssertTrue(audit.first?.sandboxed == true)
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

    func testAcceptanceDefinitionRequiresRealEvidence() {
        let device = VirtualDevice(
            name: "music-lab", cpuCount: 6, memoryMB: 4_096, diskSizeBytes: 64 * 1_073_741_824,
            network: NetworkReport(mode: "nat", macAddress: nil, bridgeInterface: nil),
            restoreInfo: RestoreInfoReport(
                ios: OSVersionReport(version: "26.1", build: "23B85"),
                cloudOS: OSVersionReport(version: "26.1", build: "23B85"),
                variant: "regular", device: "iPhone17,3"
            ),
            udid: nil, bundleURL: URL(fileURLWithPath: "/tmp/music-lab"),
            diskURL: URL(fileURLWithPath: "/tmp/music-lab/Disk.img"), isRunning: false,
            hardwareProfileID: "iphone-16-pro-a18"
        )
        let host = HostReadiness(
            state: .ready, macOSVersion: "26.3", model: "Mac16,12", architecture: "arm64",
            sipStatus: "enabled without debug", researchGuestsStatus: "enabled",
            binaryPath: "/mock/vphone-cli", binaryExitCode: 0, nestedVirtualization: true, checkedAt: .now
        )
        let kinds: [TestAssertionKind] = [
            .guestReady, .networkMode, .audioConfigured, .launchSucceeded,
            .diagnosticsCollected, .maximumDuration,
        ]
        let results = kinds.map { kind in
            TestAssertionResult(assertion: TestAssertion(kind), passed: true, message: "evidence")
        }
        let run = TestRunRecord(
            id: UUID(), kind: .baselineAcceptance, name: "Baseline", packagePath: nil,
            createdAt: .now, completedAt: .now, state: .passed,
            results: [DeviceTestResult(
                id: UUID(), deviceName: device.name, state: .passed, message: "passed",
                screenshotPath: "/tmp/screen.png", diagnosticBundlePath: "/tmp/diagnostics",
                startedAt: .now, completedAt: .now, assertionResults: results
            )]
        )
        let handshake = GuestProtocolHandshake(
            status: .compatible, negotiatedVersion: 2, minimumSupportedVersion: 1,
            maximumSupportedVersion: 2, capabilities: [.screenshots, .guestFiles],
            maximumMessageBytes: 1_048_576, authenticated: true,
            transport: "test", message: "compatible"
        )
        let report = AcceptanceEvaluator.evaluate(
            host: host, device: device, testRuns: [run], capabilities: .vphone, handshake: handshake
        )
        XCTAssertTrue(report.isPassed)
        XCTAssertEqual(report.gates.count, AcceptanceGateKind.allCases.count)
    }

    func testHostCompatibilityMatrixMatchesSpecificEvidence() {
        let catalog = HostCompatibilityCatalog(
            schemaVersion: 1,
            records: [HostCompatibilityRecord(
                id: "test", macOSPrefixes: ["26."], modelPrefixes: ["Mac16,"],
                backendVersionPrefixes: ["*"], iosMajorVersions: [26], status: .validated,
                evidence: "validated fixture", updatedAt: "2026-08-10"
            )]
        )
        let host = HostReadiness(
            state: .ready, macOSVersion: "26.3", model: "Mac16,12", architecture: "arm64",
            sipStatus: "enabled", researchGuestsStatus: "enabled", binaryPath: "/mock",
            binaryExitCode: 0, nestedVirtualization: true, checkedAt: .now
        )
        var device = VirtualDevice(
            name: "test", cpuCount: 1, memoryMB: 1_024, diskSizeBytes: 1,
            network: NetworkReport(mode: "nat", macAddress: nil, bridgeInterface: nil),
            restoreInfo: RestoreInfoReport(
                ios: OSVersionReport(version: "26.1", build: "x"),
                cloudOS: OSVersionReport(version: "26.1", build: "x"), variant: nil, device: nil
            ), udid: nil, bundleURL: URL(fileURLWithPath: "/tmp/test"),
            diskURL: URL(fileURLWithPath: "/tmp/test/Disk.img"), isRunning: false
        )
        device.hardwareProfileID = "profile"
        XCTAssertEqual(
            HostCompatibilityDatabase.assess(catalog: catalog, host: host, backendVersion: nil, device: device).status,
            .validated
        )
    }

    func testSchemaMigrationBacksUpAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        try Data("[]".utf8).write(to: paths.stateRoot.appendingPathComponent("activity.json"))
        let first = try LabMigrationManager.migrate(paths: paths)
        XCTAssertEqual(first.destinationVersion, LabMigrationManager.currentSchemaVersion)
        XCTAssertFalse(first.applied.isEmpty)
        XCTAssertNotNil(first.latestBackupPath)
        let second = try LabMigrationManager.migrate(paths: paths)
        XCTAssertTrue(second.applied.isEmpty)
    }

    func testOperationJournalRecoversInterruptedWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        let entry = OperationJournalEntry(
            id: UUID(), kind: .restore, target: "restored-device", startedAt: .now,
            updatedAt: .now, state: .running, phase: .restoring,
            recoveryInstruction: "Verify the imported bundle", message: "running"
        )
        try OperationJournalStore.save([entry], paths: paths)
        let recovered = try OperationJournalStore.recoverInterrupted(paths: paths)
        XCTAssertEqual(recovered.first?.state, .interrupted)
        XCTAssertEqual(recovered.first?.phase, .failed)
    }

    func testEnvironmentProfilesAndAssignmentsPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("environment-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        XCTAssertGreaterThanOrEqual(EnvironmentProfileStore.load(paths: paths).count, 2)
        let profileID = EnvironmentProfileStore.builtIns[0].id
        try EnvironmentProfileStore.saveAssignments(["music-lab": profileID], paths: paths)
        XCTAssertEqual(EnvironmentProfileStore.loadAssignments(paths: paths)["music-lab"], profileID)
    }

    func testGuestProtocolNegotiationRejectsUnknownVersion() {
        let compatible = GuestProtocolNegotiator.negotiate(json: [
            "protocol_version": 2,
            "screenshots": true,
            "maximum_message_bytes": 4096,
            "authenticated": true,
        ])
        XCTAssertEqual(compatible.status, .compatible)
        XCTAssertTrue(compatible.capabilities.contains(.screenshots))
        XCTAssertEqual(compatible.maximumMessageBytes, 4096)
        XCTAssertEqual(GuestProtocolNegotiator.negotiate(json: ["protocol_version": 99]).status, .incompatible)
    }

    func testStorageLifecycleDetectsDuplicateFirmware() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        var first = FirmwareImage.inspect(root.appendingPathComponent("a.ipsw"))
        var second = FirmwareImage.inspect(root.appendingPathComponent("b.ipsw"))
        first.sha256 = "same"
        second.sha256 = "same"
        let inventory = StorageLifecycleManager.scan(
            paths: paths, devices: [], firmware: [first, second], snapshots: [], policy: .standard
        )
        XCTAssertEqual(inventory.duplicateFirmware.count, 1)
        XCTAssertTrue(inventory.warnings.contains { $0.contains("Duplicate") })
    }

    func testFirmwareInspectionRecordsProvenance() {
        let image = FirmwareImage.inspect(URL(fileURLWithPath: "/tmp/test.ipsw"))
        XCTAssertEqual(image.provenance?.sourceKind, .localImport)
        XCTAssertEqual(image.provenance?.retentionPolicy, .keep)
        XCTAssertTrue(image.provenance?.ownershipNote.contains("does not redistribute") == true)
    }

    func testBackendAndAttributionCatalogsPreserveIntegrationBoundaries() {
        let paths = makePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let backends = ProjectCatalogLoader.loadBackends(paths: paths)
        let attribution = ProjectCatalogLoader.loadAttribution(paths: paths)

        XCTAssertEqual(backends.entries.filter(\.isRunnable).map(\.id), ["com.virtualdevicelab.vphone"])
        XCTAssertEqual(backends.entry(id: "org.qemu.qemu")?.integrationState, .plannedAdapter)
        XCTAssertFalse(backends.entry(id: "org.qemu.qemu")?.selectable ?? true)
        XCTAssertEqual(backends.entry(id: "com.corellium.reference")?.integrationState, .referenceOnly)
        XCTAssertFalse(backends.entry(id: "com.corellium.reference")?.selectable ?? true)
        XCTAssertTrue(attribution.completenessIssues.isEmpty)
        XCTAssertEqual(attribution.records.first(where: { $0.id == "vphone-cli" })?.license, "MIT")
        XCTAssertFalse(attribution.records.first(where: { $0.id == "qemu" })?.distributedWithApp ?? true)
    }

    func testBackendRecommendationDoesNotPromoteResearchCandidateToRunnable() {
        let paths = makePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let backends = ProjectCatalogLoader.loadBackends(paths: paths)
        let compatibility = CompatibilityCatalog.load(paths: paths)
        let supported = FirmwareImage.inspect(URL(fileURLWithPath: "/tmp/iPhone17,3_18.6.2_22G100_Restore.ipsw"))
        let oldResearch = FirmwareImage.inspect(URL(fileURLWithPath: "/tmp/iPhone10,6_14.8_18H17_Restore.ipsw"))

        let supportedRecommendation = BackendRecommendationEvaluator.recommend(
            firmware: supported,
            catalog: backends,
            compatibility: compatibility,
            activeBackendID: "com.virtualdevicelab.vphone",
            hostReady: true
        )
        XCTAssertEqual(supportedRecommendation.verdict, .ready)
        XCTAssertEqual(supportedRecommendation.selectedBackendID, "com.virtualdevicelab.vphone")

        let researchRecommendation = BackendRecommendationEvaluator.recommend(
            firmware: oldResearch,
            catalog: backends,
            compatibility: compatibility,
            activeBackendID: "com.virtualdevicelab.vphone",
            hostReady: true
        )
        XCTAssertEqual(researchRecommendation.verdict, .unavailable)
        XCTAssertNil(researchRecommendation.selectedBackendID)
        XCTAssertTrue(researchRecommendation.researchCandidateIDs.contains("org.qemu.qemu"))
        XCTAssertFalse(researchRecommendation.researchCandidateIDs.contains("com.corellium.reference"))
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
