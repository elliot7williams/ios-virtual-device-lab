#!/usr/bin/env swift

import CryptoKit
import Foundation

struct FileRecord: Codable {
    let path: String
    let sha256: String
    let sizeBytes: Int64
}

struct Manifest: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let product: String
    let version: String
    let sourceRevision: String
    let files: [FileRecord]
}

func digest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 1_048_576) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: generate_supply_chain.swift <app> <version> <revision>\n".utf8))
    exit(64)
}

let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let version = CommandLine.arguments[2]
let revision = CommandLine.arguments[3]
let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
let generatedNames = Set(["supply-chain-manifest.json", "sbom.cdx.json", "build-provenance.json"])
let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
guard let enumerator = FileManager.default.enumerator(
    at: app, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
) else { exit(66) }

var files: [FileRecord] = []
for case let url as URL in enumerator {
    let relative = String(url.path.dropFirst(app.path.count + 1))
    if relative.hasPrefix("Contents/MacOS/") || relative.hasPrefix("Contents/_CodeSignature/") { continue }
    if generatedNames.contains(url.lastPathComponent) { continue }
    let values = try url.resourceValues(forKeys: keys)
    guard values.isRegularFile == true else { continue }
    files.append(FileRecord(
        path: relative,
        sha256: try digest(url),
        sizeBytes: Int64(values.fileSize ?? 0)
    ))
}
files.sort { $0.path < $1.path }

let formatter = ISO8601DateFormatter()
let generatedAt = formatter.string(from: Date())
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let manifest = Manifest(
    schemaVersion: 1, generatedAt: generatedAt,
    product: "iOS Virtual Device Lab", version: version,
    sourceRevision: revision, files: files
)
try encoder.encode(manifest).write(
    to: resources.appendingPathComponent("supply-chain-manifest.json"), options: .atomic
)

let sbom: [String: Any] = [
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": "urn:uuid:\(UUID().uuidString)",
    "version": 1,
    "metadata": [
        "timestamp": generatedAt,
        "component": [
            "type": "application",
            "name": "iOS Virtual Device Lab",
            "version": version,
            "purl": "pkg:github/elliot7williams/ios-virtual-device-lab@\(version)",
            "licenses": [["license": ["id": "MIT"]]],
        ],
        "tools": [["vendor": "Apple", "name": "Swift Package Manager"]],
    ],
    "components": [[
        "type": "application",
        "name": "vphone-cli backend adapter",
        "scope": "excluded",
        "description": "Optional external backend; not distributed in this app bundle.",
        "licenses": [["license": ["id": "MIT"]]],
    ]],
    "vulnerabilities": [],
]
try JSONSerialization.data(withJSONObject: sbom, options: [.prettyPrinted, .sortedKeys])
    .write(to: resources.appendingPathComponent("sbom.cdx.json"), options: .atomic)

let provenance: [String: Any] = [
    "_type": "https://in-toto.io/Statement/v1",
    "subject": [["name": "iOS Virtual Device Lab", "version": version]],
    "predicateType": "https://slsa.dev/provenance/v1",
    "predicate": [
        "buildDefinition": [
            "buildType": "https://github.com/elliot7williams/ios-virtual-device-lab/build_app/v1",
            "externalParameters": ["version": version],
            "resolvedDependencies": [[
                "uri": "git+https://github.com/elliot7williams/ios-virtual-device-lab",
                "digest": ["gitCommit": revision],
            ]],
        ],
        "runDetails": [
            "builder": ["id": "swift-package-manager"],
            "metadata": ["invocationId": UUID().uuidString, "startedOn": generatedAt],
        ],
    ],
]
try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted, .sortedKeys])
    .write(to: resources.appendingPathComponent("build-provenance.json"), options: .atomic)

print("Generated supply-chain manifest, CycloneDX SBOM, and SLSA-style provenance")
