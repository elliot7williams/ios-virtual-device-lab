import Foundation
import AppKit
import CryptoKit
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
            status: .compatible, negotiatedVersion: 3, minimumSupportedVersion: 1,
            maximumSupportedVersion: 3, capabilities: [.screenshots, .guestFiles],
            maximumMessageBytes: 1_048_576, authenticated: true,
            replayProtected: true, authenticationClockSkewSeconds: 30,
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

    func testEveryHistoricalSchemaFixtureMigratesToCurrent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("migration-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for source in 0..<LabMigrationManager.currentSchemaVersion {
            let paths = makePaths(root: root.appendingPathComponent("v\(source)"))
            try paths.createDirectories()
            try HardeningJSON.save(
                LabMigrationState(schemaVersion: source, history: []),
                to: paths.stateRoot.appendingPathComponent("lab-schema.json")
            )
            try HardeningJSON.save(["fixture": source], to: paths.stateRoot.appendingPathComponent("activity.json"))
            let report = try LabMigrationManager.migrate(paths: paths)
            XCTAssertEqual(report.sourceVersion, source)
            XCTAssertEqual(report.destinationVersion, LabMigrationManager.currentSchemaVersion)
            XCTAssertEqual(report.applied.count, LabMigrationManager.currentSchemaVersion - source)
        }
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
            "replay_protection": true,
            "authentication_clock_skew_seconds": 30,
        ])
        XCTAssertEqual(compatible.status, .compatible)
        XCTAssertTrue(compatible.capabilities.contains(.screenshots))
        XCTAssertEqual(compatible.maximumMessageBytes, 4096)
        XCTAssertTrue(compatible.replayProtected)
        XCTAssertEqual(compatible.authenticationClockSkewSeconds, 30)
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

    func testQualificationCampaignPinsFixtureAndBlocksIncompleteEvidence() {
        let host = testHost()
        let campaign = QualificationCampaignStore.create(
            host: host, backend: .vphone, device: nil, firmware: nil, acceptance: .empty
        )
        XCTAssertEqual(campaign.state, .blocked)
        XCTAssertEqual(campaign.backendID, BackendDescriptor.vphone.id)
        XCTAssertTrue(campaign.hostFingerprint.contains(host.model))
        XCTAssertGreaterThanOrEqual(campaign.blockers.count, 3)
    }

    func testSetupAssistantRepairsOnlySafeDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("setup-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try SetupAssistant.repairSafeDirectories(paths: paths)
        let report = SetupAssistant.inspect(paths: paths, host: testHost())
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.stateRoot.appendingPathComponent("Evidence").path))
        XCTAssertTrue(report.checks.first(where: { $0.id == "host" })?.canRepairInApp == false)
        XCTAssertEqual(report.schemaVersion, 1)
    }

    func testGuestTrustAndAccessibilityFailClosed() {
        let unauthenticated = GuestProtocolHandshake(
            status: .compatible, negotiatedVersion: 3, minimumSupportedVersion: 1,
            maximumSupportedVersion: 3, capabilities: [.screenshots, .accessibilityTree],
            maximumMessageBytes: 1_048_576, authenticated: false,
            replayProtected: true, authenticationClockSkewSeconds: 30,
            transport: "fixture", message: "fixture"
        )
        XCTAssertFalse(GuestTrustEvaluator.evaluate(unauthenticated, policy: .strict).trustedForMutation)
        XCTAssertFalse(UIAutomationReadiness.assess(handshake: unauthenticated).available)
        let authenticated = GuestProtocolHandshake(
            status: .compatible, negotiatedVersion: 3, minimumSupportedVersion: 1,
            maximumSupportedVersion: 3, capabilities: [.accessibilityTree],
            maximumMessageBytes: 1_048_576, authenticated: true,
            replayProtected: true, authenticationClockSkewSeconds: 30,
            transport: "fixture", message: "fixture"
        )
        XCTAssertTrue(UIAutomationReadiness.assess(handshake: authenticated).available)
    }

    func testEvidenceLedgerDetectsPayloadTamperingAndSurvivesReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("evidence-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        let first = try EvidenceLedger.seal(
            ["gate": "passed"], subject: "Acceptance fixture", host: testHost(),
            appVersion: "0.7.0", backend: .vphone, paths: paths
        )
        _ = try EvidenceLedger.review(
            id: first.id, state: .approved, reviewer: "Test Reviewer", note: "Reviewed", paths: paths
        )
        _ = try EvidenceLedger.seal(
            ["gate": "passed-again"], subject: "Second fixture", host: testHost(),
            appVersion: "0.7.0", backend: .vphone, paths: paths
        )
        XCTAssertTrue(EvidenceLedger.verify(paths: paths).isEmpty)
        let payload = paths.stateRoot.appendingPathComponent("Evidence/\(first.id.uuidString)-payload.json")
        try Data("tampered".utf8).write(to: payload, options: .atomic)
        XCTAssertTrue(EvidenceLedger.verify(paths: paths).contains { $0.contains("payload checksum") })
    }

    func testBackupVerificationAndRestoreStagingExcludeCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root.appendingPathComponent("lab"))
        let destination = root.appendingPathComponent("backups")
        try paths.createDirectories()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: paths.stateRoot.appendingPathComponent("settings.json"))
        try Data("secret".utf8).write(to: paths.stateRoot.appendingPathComponent("agent-token"))
        let backup = try LabBackupManager.create(
            paths: paths, destination: destination, policy: .standard, appVersion: "0.7.0"
        )
        let verification = LabBackupManager.verify(backup)
        XCTAssertTrue(verification.passed)
        XCTAssertFalse(verification.manifest?.entries.contains { $0.relativePath.contains("agent-token") } ?? true)
        let injected = backup.appendingPathComponent("Payload/injected.txt")
        try Data("unexpected".utf8).write(to: injected)
        XCTAssertFalse(LabBackupManager.verify(backup).passed)
        try FileManager.default.removeItem(at: injected)
        let staged = try LabBackupManager.stageRestore(backup, paths: paths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("VirtualDeviceLab/settings.json").path))
    }

    func testEncryptedFullBackupRestorePlanAndCredentialExclusion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-v3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root.appendingPathComponent("lab"))
        let destination = root.appendingPathComponent("backups")
        try paths.createDirectories()
        let vm = paths.libraryRoot.appendingPathComponent("phone")
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: vm.appendingPathComponent("Disk.img"))
        try Data("credential".utf8).write(to: vm.appendingPathComponent(GuestCredentialVault.fileName))
        try Data("firmware".utf8).write(to: paths.firmwareRoot.appendingPathComponent("fixture.ipsw"))
        var policy = LabBackupPolicy.standard
        policy.includeFirmware = true
        policy.encryptArchive = true
        let archive = try LabBackupManager.create(
            paths: paths,
            destination: destination,
            policy: policy,
            appVersion: "0.8.0",
            passphrase: "correct horse battery"
        )
        XCTAssertEqual(archive.pathExtension, "vdlbackup")
        let archiveHandle = try FileHandle(forReadingFrom: archive)
        defer { try? archiveHandle.close() }
        XCTAssertEqual(
            try archiveHandle.read(upToCount: Data("VDLBACKUP2\n".utf8).count),
            Data("VDLBACKUP2\n".utf8)
        )
        XCTAssertFalse(LabBackupManager.verify(archive, passphrase: "incorrect passphrase").passed)
        let verification = LabBackupManager.verify(archive, passphrase: "correct horse battery")
        XCTAssertTrue(verification.passed, verification.issues.joined(separator: ", "))
        XCTAssertTrue(verification.manifest?.includesVirtualDevices == true)
        XCTAssertTrue(verification.manifest?.includesFirmware == true)
        XCTAssertFalse(verification.manifest?.entries.contains { $0.relativePath.contains(GuestCredentialVault.fileName) } ?? true)
        let plan = LabBackupManager.restorePlan(archive, paths: paths, passphrase: "correct horse battery")
        XCTAssertTrue(plan.canStage)
        XCTAssertTrue(plan.targets.contains(paths.libraryRoot.path))
        let staged = try LabBackupManager.stageRestore(archive, paths: paths, passphrase: "correct horse battery")
        let command = try LabBackupManager.writeApplyRestoreCommand(stagedPayload: staged, paths: paths)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: command.path))
    }

    func testEncryptedBackupCanOpenLegacyV1Container() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-v1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("VDL-Backup-Legacy")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("legacy payload".utf8).write(to: source.appendingPathComponent("fixture.txt"))
        let archive = try makeLegacyBackup(directory: source, passphrase: "correct horse battery")

        let payload = try BackupArchiveCrypto.withDecryptedDirectory(
            archive,
            passphrase: "correct horse battery"
        ) { directory in
            try Data(contentsOf: directory.appendingPathComponent("fixture.txt"))
        }
        XCTAssertEqual(payload, Data("legacy payload".utf8))
    }

    func testHardeningJSONConcurrentWritersRemainDecodableAndPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("locking-v3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        try HardeningJSON.save(["seed": 0], to: url)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            try? HardeningJSON.save(["value": index], to: url)
            _ = try? HardeningJSON.load([String: Int].self, from: url)
        }
        XCTAssertNoThrow(try HardeningJSON.load([String: Int].self, from: url))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testTenThousandRecordStateLoadRemainsBounded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("load-v3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("records.json")
        let fixture = Dictionary(uniqueKeysWithValues: (0..<10_000).map { ("record-\($0)", $0) })
        try HardeningJSON.save(fixture, to: url)
        let started = Date()
        let loaded = try HardeningJSON.load([String: Int].self, from: url)
        XCTAssertEqual(loaded.count, 10_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testCompanionContractRejectsLegacyAndAcceptsProtocolV3() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contract-v3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("vphone-cli")
        let contract = "{\"schemaVersion\":1,\"backendID\":\"vphone-cli\",\"backendVersion\":\"0.8.0\",\"minimumHostAppVersion\":\"0.8.0\",\"hostControlProtocol\":3,\"exportExcludesCredentials\":true,\"sourceRevision\":null}\n"
        let script = "#!/bin/zsh\nprint -r -- '\(contract.trimmingCharacters(in: .newlines))'\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertTrue(CompanionBackendInspector.inspect(binary: executable).compatible)

        let bundledBinary = root.appendingPathComponent("vphone-cli.app/Contents/MacOS/vphone-cli")
        try FileManager.default.createDirectory(at: bundledBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/zsh\nexit 137\n".write(to: bundledBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundledBinary.path)
        let resource = root.appendingPathComponent("vphone-cli.app/Contents/Resources/vdl-backend-contract.json")
        try FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contract.write(to: resource, atomically: true, encoding: .utf8)
        XCTAssertTrue(CompanionBackendInspector.inspect(binary: bundledBinary).compatible)
    }

    @MainActor
    func testLaunchHealthWatchdogKeepsActorBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-watchdog-v3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        LaunchHealthMonitor.shared.begin(paths: paths)
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(LaunchHealthMonitor.shared.record.lastPhase, "launching")
        XCTAssertEqual(LaunchHealthMonitor.shared.record.consecutiveUncleanLaunches, 0)
        LaunchHealthMonitor.shared.markCleanExit()
        XCTAssertEqual(LaunchHealthMonitor.shared.record.lastPhase, "clean-exit")
    }

    func testLaunchHealthForDefaultLabUsesHostLocalStorage() {
        let root = LaunchHealthLocation.markerRoot(for: .default)
        XCTAssertEqual(root, LaunchHealthLocation.hostRoot)
        XCTAssertFalse(root.path.hasPrefix(LabPaths.default.dataRoot.path + "/"))

        let temporary = makePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        XCTAssertEqual(LaunchHealthLocation.markerRoot(for: temporary), temporary.stateRoot)
    }

    func testStorageBootstrapDoesNotRewriteExistingDirectoryPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-permissions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try FileManager.default.createDirectory(at: paths.dataRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: paths.dataRoot.path)

        try paths.createDirectories()

        let permissions = try FileManager.default.attributesOfItem(atPath: paths.dataRoot.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o750)
        for directory in [paths.libraryRoot, paths.firmwareRoot, paths.snapshotsRoot, paths.stateRoot] {
            let created = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(created?.intValue, 0o700)
        }
    }

    func testUpdaterRejectsArchiveSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-escape-v3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root.appendingPathComponent("lab"))
        try paths.createDirectories()
        let badApp = root.appendingPathComponent("Bad.app")
        try FileManager.default.createDirectory(at: badApp, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: badApp.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
        let archive = root.appendingPathComponent("bad.zip")
        XCTAssertTrue(ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--keepParent", badApp.path, archive.path], timeout: 30
        ).succeeded)
        XCTAssertThrowsError(try UpdateLifecycleManager.stage(
            archive: archive,
            currentApp: nil,
            version: "0.8.1",
            paths: paths,
            policy: UpdateLifecyclePolicy(
                channel: .beta,
                requireSignedManifest: false,
                requireNotarization: false,
                retainRollbackVersions: 2
            )
        ))
    }

    func testProductionReadinessCriticalActionsHaveAccessibilityIdentifiers() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/IOSVirtualDeviceLab/Views/ProductionReadinessView.swift"),
            encoding: .utf8
        )
        for identifier in [
            "readiness.record-qualification", "readiness.seal-evidence", "readiness.create-backup",
            "readiness.verify-backup", "readiness.stage-restore", "readiness.run-resilience",
        ] {
            XCTAssertTrue(source.contains("accessibilityIdentifier(\"\(identifier)\")"), identifier)
        }
    }

    func testRemoteAgentBootstrapCreatesV2ProtectedKeyring() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        let configuration = try RemoteLabAgentBootstrap.initialize(paths: paths)
        XCTAssertEqual(configuration.schemaVersion, 2)
        XCTAssertNotNil(configuration.activeKeyID)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: configuration.tokenFilePath))) as? [String: Any]
        XCTAssertEqual(object?["schemaVersion"] as? Int, 2)
        let permissions = try FileManager.default.attributesOfItem(atPath: configuration.tokenFilePath)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue ?? 0, 0o600)
    }

    func testResilienceSuiteExercisesEveryDeclaredScenario() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resilience-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try SetupAssistant.repairSafeDirectories(paths: paths)
        let report = ResilienceSuite.run(paths: paths)
        XCTAssertTrue(report.passed)
        XCTAssertEqual(Set(report.results.map(\.scenario)), Set(ResilienceScenario.allCases))
    }

    func testUpdateStagingCreatesExplicitInstallAndRollbackCommands() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updates-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root.appendingPathComponent("lab"))
        try paths.createDirectories()
        let newApp = root.appendingPathComponent("New.app")
        let currentApp = root.appendingPathComponent("Current.app")
        try makeSignedFixtureApp(newApp)
        try FileManager.default.copyItem(at: newApp, to: currentApp)
        let archive = root.appendingPathComponent("update.zip")
        let zipped = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--keepParent", newApp.path, archive.path], timeout: 30
        )
        XCTAssertTrue(zipped.succeeded)
        let record = try UpdateLifecycleManager.stage(
            archive: archive, currentApp: currentApp, version: "0.7.1", paths: paths,
            policy: UpdateLifecyclePolicy(
                channel: .beta, requireSignedManifest: false,
                requireNotarization: false, retainRollbackVersions: 2
            )
        )
        XCTAssertTrue(record.signatureVerified)
        XCTAssertTrue(record.installerScriptPath.map(FileManager.default.isExecutableFile) ?? false)
        XCTAssertTrue(record.rollbackScriptPath.map(FileManager.default.isExecutableFile) ?? false)
        XCTAssertFalse(record.installationApproved)
    }

    func testExternalStorageDetectsBrokenLinkAndRelinksAtomically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-relink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent(".vphone")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appendingPathComponent("missing")
        )
        let registry = root.appendingPathComponent("registry.json")
        XCTAssertEqual(ExternalStorageManager.inspect(root: link, registryURL: registry).state, .relinkRequired)

        let destination = root.appendingPathComponent("dedicated-lab")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let status = try ExternalStorageManager.relink(root: link, to: destination, registryURL: registry)
        XCTAssertEqual(status.state, .online)
        XCTAssertEqual(URL(fileURLWithPath: status.resolvedPath ?? "").standardizedFileURL, destination.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("VirtualDeviceLab").path))
    }

    func testRecoveryCenterPersistsAuditedAbandonDecision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-center-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        let entry = OperationJournalEntry(
            id: UUID(), kind: .snapshot, target: "phone/golden", startedAt: .now,
            updatedAt: .now, state: .interrupted, phase: .failed,
            recoveryInstruction: "Inspect the archive.", message: "Interrupted"
        )
        var entries = [entry]
        try OperationJournalStore.save(entries, paths: paths)
        let decision = try RecoveryCenterStore.decide(
            entry: entry, action: .abandon, entries: &entries, paths: paths
        )
        XCTAssertEqual(decision.action, .abandon)
        XCTAssertEqual(entries.first?.state, .resolved)
        XCTAssertEqual(RecoveryCenterStore.load(paths: paths, entries: entries).decisions.first?.journalEntryID, entry.id)
    }

    func testCanonicalFixtureRequiresVerifiedRealEvidence() throws {
        var firmware = FirmwareImage.inspect(URL(fileURLWithPath: "/tmp/iPhone10,6_15.8_19H370_Restore.ipsw"))
        firmware.sha256 = String(repeating: "a", count: 64)
        firmware.validation = FirmwareValidation(
            state: .valid, checkedAt: .now, hasBuildManifest: true,
            archiveEntryCount: 10, issues: []
        )
        let device = VirtualDevice(
            name: "golden", cpuCount: 4, memoryMB: 4_096, diskSizeBytes: 32 * 1_073_741_824,
            network: NetworkReport(mode: "nat", macAddress: nil, bridgeInterface: nil),
            restoreInfo: RestoreInfoReport(
                ios: OSVersionReport(version: "15.8", build: "19H370"),
                cloudOS: OSVersionReport(version: "15.8", build: "19H370"),
                variant: "regular", device: "iPhone10,6"
            ), udid: nil, bundleURL: URL(fileURLWithPath: "/tmp/golden"),
            diskURL: URL(fileURLWithPath: "/tmp/golden/Disk.img"), isRunning: false,
            hardwareProfileID: "iphone-x"
        )
        let snapshot = SnapshotRecord(
            id: UUID(), name: "golden", sourceVM: device.name, createdAt: .now,
            archivePath: "/tmp/golden.tgz", sizeBytes: 1,
            sha256: String(repeating: "b", count: 64), lastVerifiedAt: .now,
            integrityStatus: .verified
        )
        let gates = AcceptanceGateKind.allCases.map {
            AcceptanceGateResult(kind: $0, status: .passed, evidence: "fixture", requiredEvidence: "fixture")
        }
        let acceptance = AcceptanceReport(
            schemaVersion: 1, generatedAt: .now, deviceName: device.name, gates: gates
        )
        XCTAssertTrue(CanonicalFixtureStore.assess(
            device: device, firmware: firmware, snapshot: snapshot, acceptance: acceptance
        ).ready)
        XCTAssertFalse(CanonicalFixtureStore.assess(
            device: device, firmware: firmware, snapshot: nil, acceptance: acceptance
        ).ready)
    }

    func testLabfilePlannerProducesCreateUpdateAndBlockedChanges() throws {
        let paths = makePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("labfile-\(UUID().uuidString)"))
        let profiles = HardwareProfilesCatalog.load(paths: paths)
        let profile = try XCTUnwrap(profiles.profiles.first)
        var image = FirmwareImage.inspect(URL(fileURLWithPath: "/tmp/fixture_26.1_23B85_Restore.ipsw"))
        image.sha256 = String(repeating: "c", count: 64)
        let document = LabfileDocument(
            schemaVersion: 1, name: "Fixture", backendID: BackendDescriptor.vphone.id,
            devices: [LabfileDevice(
                name: "new-phone", hardwareProfileID: profile.id,
                firmwareSHA256: image.sha256!, cloudOSFirmwareSHA256: nil,
                cpuCount: 4, memoryMB: 4_096, diskSizeGB: 32,
                networkMode: "nat", environmentProfileID: nil, workflowNames: []
            )]
        )
        let plan = LabfilePlanner.plan(
            document, devices: [], firmware: [image], profiles: profiles, backend: .vphone
        )
        XCTAssertTrue(plan.canApply)
        XCTAssertEqual(plan.changes.first?.kind, .create)

        var missing = document
        missing.devices[0].firmwareSHA256 = String(repeating: "d", count: 64)
        XCTAssertEqual(LabfilePlanner.plan(
            missing, devices: [], firmware: [image], profiles: profiles, backend: .vphone
        ).changes.first?.kind, .blocked)
    }

    func testEvidenceLifecycleInvalidatesOldOrChangedCampaign() {
        let campaign = QualificationCampaign(
            id: UUID(), deviceName: "phone", firmwareSHA256: String(repeating: "e", count: 64),
            hardwareProfileID: "iphone-x", hostFingerprint: "old-host", backendID: BackendDescriptor.vphone.id,
            backendVersion: "0.7", createdAt: Date(timeIntervalSinceNow: -60 * 86_400),
            completedAt: Date(timeIntervalSinceNow: -60 * 86_400), state: .passed,
            blockers: [], acceptance: .empty, evidenceSealID: nil
        )
        var policy = EvidenceLifecyclePolicy.standard
        policy.requireApprovedSeal = false
        let report = EvidenceLifecycleManager.evaluate(
            campaigns: [campaign], policy: policy, host: testHost(), backend: .vphone,
            currentFirmwareHashes: [String(repeating: "e", count: 64)], seals: []
        )
        XCTAssertFalse(report.items[0].fresh)
        XCTAssertTrue(report.items[0].reasons.contains { $0.contains("older") })
        XCTAssertTrue(report.items[0].reasons.contains { $0.contains("Host fingerprint") })
    }

    func testHostCapacityUsesLowMemoryMode() {
        let calibration = HostCapacityCalibrator.recommendation(
            physicalMemoryMB: 8_192, processors: 8, availableStorageBytes: 200 * 1_073_741_824
        )
        XCTAssertEqual(calibration.capacityClass, .constrained)
        XCTAssertEqual(calibration.recommendedConcurrentVMs, 1)
        XCTAssertLessThanOrEqual(calibration.recommendedAggregateMemoryMB, 4_096)
    }

    func testHostileInputSuiteRejectsTraversalAndOversize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostile-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        XCTAssertFalse(HostileInputValidator.isSafeArchivePath("../escape"))
        XCTAssertFalse(HostileInputValidator.acceptsJSON(Data(repeating: 0x20, count: 1_048_577)))
        XCTAssertTrue(HostileInputValidator.run(paths: paths).passed)
    }

    func testRetentionPreviewIsNonDestructiveAndQuarantineIsRecoverable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retention-v3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        let diagnostics = paths.stateRoot.appendingPathComponent("Diagnostics")
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
        let old = diagnostics.appendingPathComponent("old.log")
        try Data("sanitized".utf8).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -20 * 86_400)], ofItemAtPath: old.path
        )
        let preview = UnifiedDataLifecycleManager.preview(paths: paths, policy: .standard)
        XCTAssertEqual(preview.candidates.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        let quarantine = try XCTUnwrap(UnifiedDataLifecycleManager.quarantine(preview, paths: paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
    }

    func testOperationalObjectivesFailClosedWithoutRealEvidence() {
        let report = OperationalObjectiveEvaluator.evaluate(
            policy: .standard, testRuns: [], acceptance: .empty,
            resilience: nil, secondVolumeRestoreRecorded: false
        )
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.gates.allSatisfy { !$0.passed })
    }

    func testPublicBetaReadinessKeepsHumanGatesExplicit() {
        var record = BetaVerificationRecord.empty
        record.voiceOverVerified = true
        let report = PublicBetaReadinessManager.evaluate(record: record, localizationCount: 1)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.items.first { $0.name == "VoiceOver" }?.passed, true)
        XCTAssertEqual(report.items.first { $0.name == "Legal review" }?.passed, false)
    }

    func testAdapterConformanceAcceptsSDKExampleAndRejectsUnknownCapability() {
        XCTAssertTrue(BackendAdapterConformance.evaluate(BackendAdapterConformance.example).passed)
        var invalid = BackendAdapterConformance.example
        invalid.capabilities.append("pretendSuccess")
        XCTAssertFalse(BackendAdapterConformance.evaluate(invalid).passed)
        invalid = BackendAdapterConformance.example
        invalid.minimumLabVersion = "99.0.0"
        XCTAssertFalse(BackendAdapterConformance.evaluate(invalid).passed)
    }

    func testDeterministicResetFailsClosedWithoutBackendGuestReset() {
        let device = VirtualDevice(
            name: "reset-phone", cpuCount: 4, memoryMB: 4_096, diskSizeBytes: 32 * 1_073_741_824,
            network: NetworkReport(mode: "nat", macAddress: nil, bridgeInterface: nil), restoreInfo: nil,
            udid: nil, bundleURL: URL(fileURLWithPath: "/tmp/reset-phone"),
            diskURL: URL(fileURLWithPath: "/tmp/reset-phone/Disk.img"), isRunning: false
        )
        let fixture = CanonicalVMFixture(
            id: UUID(), schemaVersion: 1, name: "Golden", createdAt: .now,
            deviceName: device.name, deviceProductType: "iPhone10,6",
            firmwareSHA256: String(repeating: "a", count: 64), cloudOSFirmwareSHA256: nil,
            hardwareProfileID: "iphone-x", backendID: BackendDescriptor.vphone.id,
            backendVersion: "0.10.0", guestProtocolVersion: 3,
            snapshotSHA256: String(repeating: "b", count: 64), smokeAppSHA256: nil,
            acceptanceGeneratedAt: .now, acceptanceGateIDs: []
        )
        let plan = DeterministicResetPlanner.plan(
            device: device, fixture: fixture, policy: .standard,
            backendCapabilities: ["snapshotRestore", "xcodeDeployment", "networking", "automation"]
        )
        XCTAssertFalse(plan.canExecute)
        XCTAssertTrue(plan.blockers.contains { $0.contains("deterministicReset") })
    }

    func testBuildIdentityCatalogReadsBundleAndSymbolsWithoutInventingSigning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("build-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "dev.virtualdevicelab.iosfixture", "CFBundleExecutable": "Fixture",
            "CFBundleVersion": "42", "CFBundleShortVersionString": "1.2.3",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Fixture"))
        let artifact = AppArtifact(id: UUID(), name: "Fixture", path: app.path, importedAt: .now, sizeBytes: 1, sha256: "abc")
        let record = BuildIdentityCatalog.index(artifact: artifact, sourceRevision: "deadbeef")
        XCTAssertEqual(record.bundleIdentifier, "dev.virtualdevicelab.iosfixture")
        XCTAssertEqual(record.buildNumber, "42")
        XCTAssertEqual(record.sourceRevision, "deadbeef")
        XCTAssertFalse(record.executableUUIDs.isEmpty)
    }

    func testFailureReplayBundleIsSanitizedAndHashPinned() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        let started = Date(timeIntervalSinceNow: -1)
        let result = DeviceTestResult(
            id: UUID(), deviceName: "phone", state: .failed, message: "Assertion failed",
            screenshotPath: "/sanitized/screen.png", diagnosticBundlePath: "/sanitized/diagnostics",
            startedAt: started, completedAt: .now
        )
        let run = TestRunRecord(
            id: UUID(), kind: .deployment, name: "Failure", packagePath: nil, createdAt: started,
            completedAt: .now, state: .failed, results: [result]
        )
        let bundle = try FailureReplayBundler.create(run: run, labfile: nil, assignments: [:], fixtures: [], paths: paths)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path + "/replay-manifest.json"))
        XCTAssertEqual(bundle.manifestSHA256.count, 64)
        let manifest = try String(contentsOfFile: bundle.path + "/replay-manifest.json", encoding: .utf8)
        XCTAssertTrue(manifest.contains("signing keys"))
        XCTAssertFalse(manifest.contains("secretValue"))
        let commandPath = bundle.path + "/replay.command"
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: commandPath))
        XCTAssertTrue(try String(contentsOfFile: commandPath, encoding: .utf8).contains("--workflow"))
    }

    func testRunTrendAnalyzerDetectsFlakyAndConsecutiveFailures() {
        let states: [TestRunState] = [.passed, .failed, .passed, .failed, .failed, .failed]
        let runs = states.enumerated().map { index, state in
            let start = Date(timeIntervalSince1970: Double(index * 10))
            return TestRunRecord(
                id: UUID(), kind: .deployment, name: "Matrix", packagePath: nil, createdAt: start,
                completedAt: start.addingTimeInterval(5), state: state,
                results: [DeviceTestResult(
                    id: UUID(), deviceName: "phone", state: state, message: state.rawValue,
                    screenshotPath: nil, diagnosticBundlePath: nil, startedAt: start,
                    completedAt: start.addingTimeInterval(5)
                )]
            )
        }
        let trend = RunTrendAnalyzer.evaluate(runs: runs, policy: .standard).trends.first
        XCTAssertEqual(trend?.flaky, true)
        XCTAssertEqual(trend?.quarantined, true)
        XCTAssertEqual(trend?.consecutiveFailures, 3)
    }

    func testFleetSchedulerRejectsDrainedHostsAndPlacesEligibleHost() {
        var host = FleetScheduler.localHost(capabilities: ["lifecycle", "automation"], maximumConcurrentVMs: 2)
        let request = FleetJobRequest(name: "job", requiredCapabilities: ["automation"], requiredMemoryMB: 1_024)
        host.drained = true
        XCTAssertFalse(FleetScheduler.place(request, on: [host]).placed)
        host.drained = false
        XCTAssertTrue(FleetScheduler.place(request, on: [host]).placed)
    }

    func testUnifiedTimelineCorrelatesRunEvidenceAndReportsMissingVideo() {
        let start = Date(timeIntervalSinceNow: -2)
        let run = TestRunRecord(
            id: UUID(), kind: .deployment, name: "Timeline", packagePath: nil, createdAt: start,
            completedAt: .now, state: .passed,
            results: [DeviceTestResult(
                id: UUID(), deviceName: "phone", state: .passed, message: "passed",
                screenshotPath: "/tmp/screen.png", diagnosticBundlePath: nil,
                startedAt: start, completedAt: .now
            )]
        )
        let timeline = UnifiedTimelineBuilder.build(
            run: run, logs: [LogEntry(level: .info, scope: "phone", message: "ready")],
            performance: [:], videoSupported: false
        )
        XCTAssertTrue(timeline.events.contains { $0.kind == .screenshot })
        XCTAssertFalse(timeline.unavailableSources.isEmpty)
    }

    func testSecurityPostureInventoryNeverContainsSecretValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("security-posture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        let report = SecurityPostureEvaluator.evaluate(paths: paths, devices: [], remoteAgentConfigured: false)
        let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("secretValue"))
        XCTAssertTrue(report.secrets.allSatisfy { !$0.exportAllowed })
    }

    func testFuzzCampaignIsDeterministicAndCoverageFailsClosed() {
        let first = EngineeringQualityEvaluator.run(policy: .standard)
        let second = EngineeringQualityEvaluator.run(policy: .standard)
        XCTAssertEqual(first.totalCases, second.totalCases)
        XCTAssertEqual(first.failedCases, second.failedCases)
        XCTAssertTrue(first.fuzzGatePassed)
        XCTAssertFalse(first.coverageGatePassed)
    }

    func testBetaOperationsRequireHealthQualityFeedbackAndPublicEvidence() {
        var policy = BetaOperationsPolicy.standard
        policy.channel = .beta
        policy.feedbackURL = "https://example.invalid/feedback"
        let report = BetaOperationsEvaluator.evaluate(
            policy: policy, runs: [], publicBeta: .empty, quality: .empty, security: .empty
        )
        XCTAssertFalse(report.canPromote)
        XCTAssertEqual(report.gates.first { $0.id == "feedback" }?.passed, true)
        XCTAssertEqual(report.gates.first { $0.id == "launch-health" }?.passed, false)
    }

    func testPlatformEngineeringStateRoundTripsAndCriticalActionsAreAccessible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("platform-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        var state = PlatformEngineeringState.empty
        state.adapterManifests = [BackendAdapterConformance.example]
        try PlatformEngineeringStore.save(state, paths: paths)
        XCTAssertEqual(PlatformEngineeringStore.load(paths: paths).adapterManifests.count, 1)

        let source = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/IOSVirtualDeviceLab/Views/PlatformEngineeringView.swift"),
            encoding: .utf8
        )
        for identifier in [
            "platform.refresh", "platform.adapter-import", "platform.reset-plan", "platform.build-index",
            "platform.replay-create", "platform.trends-analyze", "platform.fleet-register",
            "platform.timeline-capture", "platform.security-assess", "platform.quality-run", "platform.beta-evaluate",
        ] {
            XCTAssertTrue(source.contains("accessibilityIdentifier(\"\(identifier)\")"), identifier)
        }
    }

    func testCapabilityMaturityDoesNotInventRealVMQualification() {
        let records = CapabilityMaturityEvaluator.evaluate(.init(
            adapterInstalled: true, adapterInvocationSucceeded: true,
            guestAutomationAvailable: true, replayValidated: true,
            symbolicationSucceeded: true, fleetLeaseActive: true, timelineCaptured: true,
            coverageImported: true, physicalTargetDiscovered: true, approvedQualificationCount: 0
        ))
        XCTAssertEqual(records.count, 10)
        XCTAssertFalse(records.contains { $0.level >= .realVMQualified })
        XCTAssertEqual(records.first { $0.id == "runtime-adapters" }?.level, .integrated)
    }

    func testQualificationMatrixPublishesOnlyApprovedSeals() throws {
        let device = expansionDevice()
        let sealID = UUID()
        let campaign = QualificationCampaign(
            id: UUID(), deviceName: device.name, firmwareSHA256: String(repeating: "a", count: 64),
            hardwareProfileID: "iphone-x", hostFingerprint: "host", backendID: "backend",
            backendVersion: "1.0.0", createdAt: .now, completedAt: .now, state: .passed,
            blockers: [], acceptance: .empty, evidenceSealID: sealID
        )
        let seal = EvidenceSeal(
            id: sealID, schemaVersion: 1, createdAt: .now, subject: "fixture", hostFingerprint: "host",
            appVersion: "0.11.0", backendID: "backend", backendVersion: "1.0.0",
            payloadSHA256: String(repeating: "b", count: 64), previousSealSHA256: nil,
            signingPublicKey: "public", signature: "signature", reviewState: .approved,
            reviewer: "reviewer", reviewedAt: .now, reviewNote: "approved"
        )
        let matrix = QualificationMatrixEvaluator.evaluate(devices: [device], campaigns: [campaign], seals: [seal])
        XCTAssertEqual(matrix.first?.state, .approved)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qualification-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try QualificationMatrixEvaluator.publishApproved(matrix, seals: [seal], to: url).entries.count, 1)
    }

    func testRuntimeAdapterInstallerPinsChecksumAndInvocationFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adapter-runtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        var manifest = BackendAdapterConformance.example
        manifest.executablePath = "/usr/bin/true"
        let installed = try RuntimeAdapterInstaller.install(manifest: manifest, paths: paths, existing: [])
        XCTAssertEqual(installed.executableSHA256, try fileSHA256(URL(fileURLWithPath: installed.executablePath)))
        let request = AdapterRuntimeRequest(
            schemaVersion: 1, requestID: UUID(), operation: "lifecycle",
            deviceName: nil, arguments: ["probe": "true"]
        )
        let response = RuntimeAdapterHost.invoke(adapter: installed, request: request, paths: paths)
        XCTAssertNil(response.0)
        XCTAssertFalse(response.1.succeeded)
    }

    func testGuestAutomationRequiresAuthenticatedDeclaredCapability() {
        let request = GuestAutomationRequest(
            id: UUID(), action: .resetAppData, bundleIdentifier: "dev.example.app",
            selector: nil, value: nil, timeoutSeconds: 30
        )
        var handshake = GuestProtocolHandshake(
            status: .compatible, negotiatedVersion: 3, minimumSupportedVersion: 1,
            maximumSupportedVersion: 3, capabilities: [.deterministicReset],
            maximumMessageBytes: 1_048_576, authenticated: true, replayProtected: true,
            authenticationClockSkewSeconds: 10, transport: "test", message: "test"
        )
        XCTAssertTrue(GuestAutomationGate.validate(request: request, handshake: handshake, policy: .strict).isEmpty)
        handshake = GuestProtocolHandshake(
            status: .compatible, negotiatedVersion: 3, minimumSupportedVersion: 1,
            maximumSupportedVersion: 3, capabilities: [.deterministicReset],
            maximumMessageBytes: 1_048_576, authenticated: false, replayProtected: true,
            authenticationClockSkewSeconds: 10, transport: "test", message: "test"
        )
        XCTAssertFalse(GuestAutomationGate.validate(request: request, handshake: handshake, policy: .strict).isEmpty)
    }

    func testReplayValidationChecksExactFixtureAndManifestHash() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("replay-validation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        let device = expansionDevice()
        let fixture = expansionFixture(device: device)
        let directory = paths.stateRoot.appendingPathComponent("replay")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = FailureReplayManifest(
            id: UUID(), schemaVersion: 1, generatedAt: .now, runID: UUID(), runName: "Replay",
            runState: .failed, deviceNames: [device.name], appArtifactID: nil, labfile: nil,
            environmentAssignments: [:], fixtureIDs: [fixture.id], diagnosticPaths: [],
            screenshotPaths: [], exclusions: ["Apple firmware"]
        )
        let manifestURL = directory.appendingPathComponent("replay-manifest.json")
        try HardeningJSON.save(manifest, to: manifestURL)
        let record = FailureReplayBundleRecord(
            id: manifest.id, generatedAt: manifest.generatedAt, runID: manifest.runID,
            path: directory.path, manifestSHA256: try fileSHA256(manifestURL)
        )
        let report = ReplayValidator.validate(
            record: record, devices: [device], artifacts: [], fixtures: [fixture],
            environments: [], backend: .vphone
        ).1
        XCTAssertTrue(report.passed)
    }

    func testSymbolicationRejectsUnmatchedDSYM() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("symbolication-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let crash = root.appendingPathComponent("Fixture.crash")
        let dSYM = root.appendingPathComponent("Fixture.dSYM")
        try FileManager.default.createDirectory(at: dSYM.appendingPathComponent("Contents/Resources/DWARF"), withIntermediateDirectories: true)
        try Data("UUID: 11111111-1111-1111-1111-111111111111\n0x100001234".utf8).write(to: crash)
        let report = CrashSymbolicator.symbolicate(crash: crash, dSYM: dSYM, builds: [])
        XCTAssertFalse(report.succeeded)
        XCTAssertTrue(report.blockers.contains { $0.contains("dSYM") })
    }

    func testFleetControlPlanePreventsDoubleCapacityAndExpiresLeases() throws {
        var host = FleetScheduler.localHost(capabilities: ["automation"], maximumConcurrentVMs: 1)
        host.lastSeen = .now
        let request = FleetJobRequest(name: "one", requiredCapabilities: ["automation"], requiredMemoryMB: 512)
        let first = FleetControlPlane.acquire(request: request, hosts: [host], leases: [], durationSeconds: 60)
        let lease = try XCTUnwrap(first.1)
        XCTAssertNil(FleetControlPlane.acquire(request: request, hosts: [host], leases: [lease], durationSeconds: 60).1)
        var expired = lease
        expired = FleetLease(
            id: expired.id, hostID: expired.hostID, jobName: expired.jobName,
            createdAt: expired.createdAt, expiresAt: .distantPast, state: .active,
            requiredCapabilities: expired.requiredCapabilities, reservedMemoryMB: expired.reservedMemoryMB
        )
        XCTAssertEqual(FleetControlPlane.expire([expired]).first?.state, .expired)
    }

    func testHighFidelityTimelineUsesMonotonicEventsAndReportsMissingSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-v11-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        let start = Date(timeIntervalSinceNow: -1)
        let run = TestRunRecord(
            id: UUID(), kind: .deployment, name: "Timeline", packagePath: nil,
            createdAt: start, completedAt: .now, state: .passed,
            results: [DeviceTestResult(
                id: UUID(), deviceName: "phone", state: .passed, message: "passed",
                screenshotPath: "/tmp/screen.png", diagnosticBundlePath: nil,
                startedAt: start, completedAt: .now
            )]
        )
        let session = try HighFidelityTimelineBuilder.capture(
            run: run, logs: [LogEntry(level: .info, scope: "phone", message: "ready")],
            performance: [:], availableSources: [.hostLogs, .screenshots], paths: paths
        )
        XCTAssertEqual(session.events, session.events.sorted { $0.monotonicNanoseconds < $1.monotonicNanoseconds })
        XCTAssertNotNil(session.unavailableSources[.video])
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.artifactPath ?? ""))
    }

    func testCoverageImporterReadsLLVMReportAndFeedsGate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coverage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let object: [String: Any] = ["data": [["totals": [
            "lines": ["percent": 82.5], "functions": ["percent": 78.0], "regions": ["percent": 80.0],
        ]]]]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let record = try SourceCoverageImporter.importReport(url, sourceRevision: "deadbeef")
        XCTAssertEqual(record.linePercent, 82.5)
        XCTAssertEqual(record.producer, "llvm-cov")
        var policy = FuzzAndCoveragePolicy.standard
        policy.measuredSourceCoveragePercent = record.linePercent
        XCTAssertTrue(EngineeringQualityEvaluator.run(policy: policy).coverageGatePassed)
    }

    func testHybridRouterUsesPhysicalTargetForPhysicalOnlyCapability() {
        let virtual = HybridTargetRouter.virtualTargets([expansionDevice()], backendCapabilities: ["networking", "audio"])
        let physical = ExecutionTargetRecord(
            id: "physical", kind: .physical, name: "Test iPhone", productType: "iPhone17,3",
            osVersion: "15.8", available: true, authorized: true,
            capabilities: ["networking", "audio", "camera"], source: "test"
        )
        let decision = HybridTargetRouter.route(
            HybridRouteRequest(iosMajor: 15, requiredCapabilities: ["camera"], preferPhysical: false),
            targets: virtual + [physical]
        )
        XCTAssertEqual(decision.target?.kind, .physical)
    }

    func testPhysicalDeploymentFailsClosedForVirtualTarget() {
        let target = ExecutionTargetRecord(
            id: "virtual", kind: .virtual, name: "Virtual", productType: nil,
            osVersion: "15.8", available: true, authorized: true,
            capabilities: ["xcodeDeployment"], source: "test"
        )
        let result = PhysicalDeviceService.installAndLaunch(
            app: URL(fileURLWithPath: "/tmp/Fixture.app"), on: target
        )
        XCTAssertFalse(result.installed)
        XCTAssertFalse(result.launched)
    }

    func testExpansionStateRoundTripsAndCriticalActionsAreAccessible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("expansion-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(root: root)
        try paths.createDirectories()
        var state = LabExpansionState.empty
        state.maturity = CapabilityMaturityEvaluator.evaluate(.init(
            adapterInstalled: false, adapterInvocationSucceeded: false,
            guestAutomationAvailable: false, replayValidated: false,
            symbolicationSucceeded: false, fleetLeaseActive: false, timelineCaptured: false,
            coverageImported: false, physicalTargetDiscovered: false, approvedQualificationCount: 0
        ))
        try LabExpansionStore.save(state, paths: paths)
        XCTAssertEqual(LabExpansionStore.load(paths: paths).maturity.count, 10)
        let source = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/IOSVirtualDeviceLab/Views/LabExpansionView.swift"), encoding: .utf8
        )
        for identifier in [
            "expansion.refresh", "expansion.qualification-record", "expansion.adapter-install",
            "expansion.symbolicate", "expansion.fleet-lease", "expansion.timeline-capture",
            "expansion.coverage-import", "expansion.physical-discover",
            "expansion.physical-deploy",
        ] {
            XCTAssertTrue(source.contains("accessibilityIdentifier(\"\(identifier)\")"), identifier)
        }
    }

    func testContinuityCriticalActionsHaveAccessibilityIdentifiers() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/IOSVirtualDeviceLab/Views/LabContinuityView.swift"),
            encoding: .utf8
        )
        for identifier in [
            "continuity.refresh", "continuity.storage-relink", "continuity.fixture-record",
            "continuity.labfile-apply", "continuity.capacity-calibrate", "continuity.hostile-inputs",
        ] {
            XCTAssertTrue(source.contains("accessibilityIdentifier(\"\(identifier)\")"), identifier)
        }
    }

    private func testHost() -> HostReadiness {
        HostReadiness(
            state: .ready, macOSVersion: "26.3", model: "Mac16,12", architecture: "arm64",
            sipStatus: "enabled", researchGuestsStatus: "enabled", binaryPath: "/mock/vphone-cli",
            binaryExitCode: 0, nestedVirtualization: true, checkedAt: .now
        )
    }

    private func expansionDevice() -> VirtualDevice {
        VirtualDevice(
            name: "expansion-phone", cpuCount: 4, memoryMB: 4_096,
            diskSizeBytes: 32 * 1_073_741_824,
            network: NetworkReport(mode: "nat", macAddress: nil, bridgeInterface: nil),
            restoreInfo: RestoreInfoReport(
                ios: OSVersionReport(version: "15.8", build: "19H370"),
                cloudOS: OSVersionReport(version: "15.8", build: "19H370"),
                variant: "regular", device: "iPhone10,6"
            ), udid: nil, bundleURL: URL(fileURLWithPath: "/tmp/expansion-phone"),
            diskURL: URL(fileURLWithPath: "/tmp/expansion-phone/Disk.img"),
            isRunning: false, hardwareProfileID: "iphone-x"
        )
    }

    private func expansionFixture(device: VirtualDevice) -> CanonicalVMFixture {
        CanonicalVMFixture(
            id: UUID(), schemaVersion: 1, name: "Expansion", createdAt: .now,
            deviceName: device.name, deviceProductType: device.restoreInfo?.device ?? "unknown",
            firmwareSHA256: String(repeating: "a", count: 64), cloudOSFirmwareSHA256: nil,
            hardwareProfileID: device.hardwareProfileID ?? "unknown", backendID: BackendDescriptor.vphone.id,
            backendVersion: "0.8.0", guestProtocolVersion: 3,
            snapshotSHA256: String(repeating: "b", count: 64), smokeAppSHA256: nil,
            acceptanceGeneratedAt: .now, acceptanceGateIDs: AcceptanceGateKind.allCases.map(\.rawValue)
        )
    }

    private func makeSignedFixtureApp(_ app: URL) throws {
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Fixture"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": "dev.virtualdevicelab.fixture",
            "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let signed = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--deep", "--sign", "-", app.path], timeout: 30
        )
        XCTAssertTrue(signed.succeeded, signed.output)
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

    private func makeLegacyBackup(directory: URL, passphrase: String) throws -> URL {
        let zip = directory.deletingLastPathComponent().appendingPathComponent("legacy.zip")
        let archive = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--keepParent", directory.path, zip.path]
        )
        XCTAssertTrue(archive.succeeded, archive.output)
        let salt = Data(repeating: 0xA5, count: 16)
        let rounds: UInt32 = 120_000
        var digest = Data(SHA256.hash(data: Data(passphrase.utf8) + salt))
        for _ in 1..<rounds { digest = Data(SHA256.hash(data: digest + salt)) }
        let sealed = try AES.GCM.seal(Data(contentsOf: zip), using: SymmetricKey(data: digest))
        let combined = try XCTUnwrap(sealed.combined)
        var container = Data("VDLBACKUP1\n".utf8)
        container.append(salt)
        container.append(bigEndianData(rounds))
        container.append(bigEndianData(UInt32(combined.count)))
        container.append(combined)
        container.append(bigEndianData(0))
        let destination = directory.deletingLastPathComponent().appendingPathComponent("legacy.vdlbackup")
        try container.write(to: destination, options: .atomic)
        return destination
    }

    private func bigEndianData(_ value: UInt32) -> Data {
        var encoded = value.bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }
}
