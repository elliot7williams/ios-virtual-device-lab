import Foundation

enum CompatibilityCatalog {
    static func load(paths: LabPaths) -> CompatibilityManifest {
        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("compatibility-manifest.json"),
            URL(fileURLWithPath: fm.currentDirectoryPath)
                .appendingPathComponent("Resources/compatibility-manifest.json"),
            paths.stateRoot.appendingPathComponent("compatibility-manifest.json"),
        ]
        let decoder = JSONDecoder()
        for case let candidate? in candidates where fm.fileExists(atPath: candidate.path) {
            if let data = try? Data(contentsOf: candidate),
               let manifest = try? decoder.decode(CompatibilityManifest.self, from: data) {
                return manifest
            }
        }
        return .empty
    }
}
