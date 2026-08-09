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
}
