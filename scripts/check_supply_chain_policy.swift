#!/usr/bin/env swift

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("supply-chain policy: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: check_supply_chain_policy.swift <policy.json> <sbom.cdx.json> <provenance.json>")
}

func object(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path), data.count <= 32 * 1_024 * 1_024,
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fail("\(path) is not a bounded JSON object")
    }
    return value
}

let policy = object(CommandLine.arguments[1])
let sbom = object(CommandLine.arguments[2])
let provenance = object(CommandLine.arguments[3])
guard policy["schemaVersion"] as? Int == 1 else { fail("unsupported policy schema") }
guard sbom["bomFormat"] as? String == "CycloneDX",
      let spec = sbom["specVersion"] as? String, spec >= "1.5" else {
    fail("CycloneDX 1.5 or newer is required")
}
let allowed = Set(policy["allowedLicenses"] as? [String] ?? [])
let denied = Set(policy["deniedLicenses"] as? [String] ?? [])
let blockUnknown = policy["blockUnknownLicenses"] as? Bool ?? true
let maximum = policy["maximumAllowedSeverity"] as? String ?? "high"
let severityRank = ["unknown": 0, "low": 1, "medium": 2, "high": 3, "critical": 4]

var components = sbom["components"] as? [[String: Any]] ?? []
if let metadata = sbom["metadata"] as? [String: Any],
   let product = metadata["component"] as? [String: Any] {
    components.append(product)
}
guard !components.isEmpty else { fail("SBOM contains no components") }
for component in components where component["scope"] as? String != "excluded" {
    let name = component["name"] as? String ?? "unnamed component"
    let declarations = component["licenses"] as? [[String: Any]] ?? []
    let licenses = declarations.compactMap { declaration -> String? in
        (declaration["license"] as? [String: Any])?["id"] as? String
    }
    if blockUnknown && licenses.isEmpty { fail("\(name) has no SPDX license identifier") }
    if licenses.contains(where: denied.contains) { fail("\(name) uses a denied license") }
    if !allowed.isEmpty && !licenses.allSatisfy(allowed.contains) { fail("\(name) has a license outside the allowlist") }
}

guard sbom["vulnerabilities"] is [[String: Any]] else { fail("SBOM has no vulnerability result set") }
for vulnerability in sbom["vulnerabilities"] as? [[String: Any]] ?? [] {
    let ratings = vulnerability["ratings"] as? [[String: Any]] ?? []
    for rating in ratings {
        let severity = (rating["severity"] as? String ?? "unknown").lowercased()
        if (severityRank[severity] ?? 0) > (severityRank[maximum] ?? 3) {
            fail("\(vulnerability["id"] as? String ?? "vulnerability") exceeds the \(maximum) severity threshold")
        }
    }
}

guard provenance["_type"] as? String == "https://in-toto.io/Statement/v1",
      provenance["predicateType"] as? String == "https://slsa.dev/provenance/v1",
      let predicate = provenance["predicate"] as? [String: Any],
      let definition = predicate["buildDefinition"] as? [String: Any],
      let dependencies = definition["resolvedDependencies"] as? [[String: Any]],
      let digest = dependencies.first?["digest"] as? [String: Any],
      let revision = digest["gitCommit"] as? String,
      revision.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else {
    fail("SLSA provenance must pin a full Git source revision")
}

print("Supply-chain policy PASS — \(components.count) component record(s), \((sbom["vulnerabilities"] as? [Any])?.count ?? 0) vulnerability finding(s), revision \(revision)")
