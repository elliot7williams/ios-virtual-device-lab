#!/usr/bin/env swift

import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fleet protocol: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2,
      let data = FileManager.default.contents(atPath: CommandLine.arguments[1]),
      data.count <= 1_048_576,
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    fail("usage: check_fleet_protocol.swift <protocol.json>")
}
guard root["schema_version"] as? Int == 1,
      root["authentication"] as? String == "mutual-tls-with-certificate-pinning",
      root["audit"] as? String == "sha256-chain-with-server-identity-signature",
      let maximum = root["maximum_request_bytes"] as? Int, maximum == 1_048_576,
      let operations = root["operations"] as? [[String: Any]] else {
    fail("identity, authentication, audit, or bounds contract is invalid")
}
let routes = Set(operations.compactMap { operation -> String? in
    guard let method = operation["method"] as? String,
          let path = operation["path"] as? String else { return nil }
    return "\(method) \(path)"
})
let required = Set([
    "GET /v1/health", "POST /v1/hosts/enroll", "POST /v1/hosts/heartbeat",
    "POST /v1/jobs", "POST /v1/jobs/next/claim", "POST /v1/jobs/{id}/claim",
    "POST /v1/jobs/{id}/progress", "POST /v1/jobs/{id}/result",
    "GET /v1/jobs/{id}", "POST /v1/jobs/{id}/cancel",
])
guard required.isSubset(of: routes) else { fail("one or more required worker routes is missing") }
print("Fleet protocol PASS — \(routes.count) authenticated routes")
