import Foundation
import XCTest
@testable import IOSVirtualDeviceLab

final class BootstrapRescueTests: XCTestCase {
    @MainActor
    func testMissingVolumeRemainsRecoverableAndRetriesAfterReconnect() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("vdl-bootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let storage = temp.appendingPathComponent("external"), root = temp.appendingPathComponent("lab")
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: storage)
        let paths = LabPaths(dataRoot: root, libraryRoot: root.appendingPathComponent("VMs"), firmwareRoot: root.appendingPathComponent("ipsws"), snapshotsRoot: root.appendingPathComponent("Snapshots"), stateRoot: root.appendingPathComponent("State"))
        let model = LabAppModel(paths: paths, backend: MockLabBackend(), storageRegistryURL: temp.appendingPathComponent("registry.json"))
        await model.bootstrap(safeMode: true)
        XCTAssertTrue(model.storageRescueActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path))
        // Mount/reconnect simulation: the original configured symlink remains intact.
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try paths.createDirectories()
        await model.bootstrap(safeMode: true)
        XCTAssertFalse(model.storageRescueActive)
        XCTAssertEqual(model.readiness.state, .ready)
        XCTAssertEqual(model.operationsHardening.report.gates.count, 10)
    }
    @MainActor
    func testUnqualifiedBackendBlocksMachineStateRestore() async {
        let backend = MockLabBackend()
        let supported = await backend.supportsMachineState
        XCTAssertFalse(supported)
    }
}
