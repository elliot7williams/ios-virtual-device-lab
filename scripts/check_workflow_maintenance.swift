#!/usr/bin/env swift
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("workflow maintenance: \(message)\n".utf8))
    exit(1)
}

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let workflowRoot = root.appendingPathComponent(".github/workflows", isDirectory: true)
let files = (try? FileManager.default.contentsOfDirectory(
    at: workflowRoot,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles]
))?.filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) } ?? []

guard !files.isEmpty else { fail("no workflow files found") }
var issues: [String] = []
var pinned = 0
for file in files.sorted(by: { $0.path < $1.path }) {
    guard let body = try? String(contentsOf: file, encoding: .utf8) else {
        issues.append("\(file.lastPathComponent): unreadable")
        continue
    }
    for (offset, line) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        guard let match = line.range(of: #"uses:\s*([^\s#]+)"#, options: .regularExpression) else { continue }
        let token = line[match].replacingOccurrences(of: #"uses:\s*"#, with: "", options: .regularExpression)
        let location = "\(file.lastPathComponent):\(offset + 1)"
        guard let at = token.lastIndex(of: "@") else {
            issues.append("\(location): action reference has no revision")
            continue
        }
        let revision = token[token.index(after: at)...]
        if revision.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) == nil {
            issues.append("\(location): \(token) is not pinned to a full commit SHA")
        } else {
            pinned += 1
        }
        let comment = String(line).lowercased()
        if token.hasPrefix("actions/checkout@"), !comment.contains("# v6") {
            issues.append("\(location): actions/checkout must document v6 (Node 24)")
        }
        if token.hasPrefix("github/codeql-action/"), !comment.contains("# v4") {
            issues.append("\(location): CodeQL Action must document v4")
        }
    }
}

guard issues.isEmpty else { fail(issues.joined(separator: "\n")) }
print("Workflow maintenance PASS — \(files.count) files, \(pinned) immutable action references")
