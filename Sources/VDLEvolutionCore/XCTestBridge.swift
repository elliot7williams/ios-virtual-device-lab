import Foundation

public struct ImportedTestCase: Codable, Sendable, Identifiable {
    public var id: String { identifier }
    public let identifier: String
    public let result: String
    public let durationSeconds: Double
}
public struct XCTestImportReport: Codable, Sendable {
    public let id: UUID
    public let importedAt: Date
    public let bundlePath: String
    public let summarySHA256: String
    public let cases: [ImportedTestCase]
    public let attachmentsPath: String?
    public let diagnosticsPath: String?
    public let coveragePath: String?
    public var passed: Bool { !cases.isEmpty && cases.allSatisfy { ["Passed", "Skipped", "Expected Failure"].contains($0.result) } }
}
public struct XcodeTestRequest: Codable, Sendable {
    public let projectPath: String
    public let scheme: String
    public let testPlan: String?
    public let destination: String
    public let resultBundlePath: String
    public init(projectPath: String, scheme: String, testPlan: String?, destination: String, resultBundlePath: String) {
        self.projectPath = projectPath; self.scheme = scheme; self.testPlan = testPlan; self.destination = destination; self.resultBundlePath = resultBundlePath
    }
    public func arguments() throws -> [String] {
        let project = URL(fileURLWithPath: projectPath)
        guard ["xcodeproj", "xcworkspace"].contains(project.pathExtension), !scheme.isEmpty, scheme.count <= 255,
              !destination.isEmpty, destination.count <= 1024, URL(fileURLWithPath: resultBundlePath).pathExtension == "xcresult",
              !FileManager.default.fileExists(atPath: resultBundlePath) else { throw EvolutionError.invalid("Choose a project/workspace, scheme, Xcode destination, and a new .xcresult destination.") }
        var args = ["xcodebuild", "test", project.pathExtension == "xcworkspace" ? "-workspace" : "-project", projectPath,
                    "-scheme", scheme, "-destination", destination, "-resultBundlePath", resultBundlePath]
        if let testPlan, !testPlan.isEmpty { args += ["-testPlan", testPlan] }
        return args
    }
}
public enum XCTestBridge {
    public static func test(_ request: XcodeTestRequest) throws -> EvolutionCommand {
        EvolutionProcess.run("/usr/bin/xcrun", try request.arguments(), timeout: 3600)
    }
    public static func parseCases(_ data: Data) throws -> [ImportedTestCase] {
        guard data.count <= 8_388_608, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nodes = root["testNodes"] as? [[String: Any]] else { throw EvolutionError.invalid("Invalid xcresulttool test-results schema.") }
        var results = [ImportedTestCase]()
        func visit(_ node: [String: Any], parent: String, depth: Int) {
            guard depth < 64, results.count < 50000 else { return }
            let name = node["name"] as? String ?? "test"
            let identifier = node["nodeIdentifier"] as? String ?? "\(parent)/\(name)"
            if node["nodeType"] as? String == "Test Case" {
                let duration = node["duration"] as? String ?? "0"
                let seconds = node["durationInSeconds"] as? Double ?? Double(duration.replacingOccurrences(of: "s", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
                results.append(ImportedTestCase(identifier: identifier, result: node["result"] as? String ?? "Unknown", durationSeconds: max(0, seconds)))
            }
            for child in node["children"] as? [[String: Any]] ?? [] { visit(child, parent: identifier, depth: depth + 1) }
        }
        for node in nodes { visit(node, parent: "", depth: 0) }
        guard !results.isEmpty else { throw EvolutionError.invalid("No completed XCTest cases were found in this result bundle.") }
        return results
    }
    public static func importBundle(_ bundle: URL, output: URL) throws -> XCTestImportReport {
        guard bundle.pathExtension == "xcresult", !FileManager.default.fileExists(atPath: output.path) else { throw EvolutionError.invalid("Choose an .xcresult bundle and a new report directory.") }
        let tests = EvolutionProcess.run("/usr/bin/xcrun", ["xcresulttool", "get", "test-results", "tests", "--path", bundle.path, "--compact"], timeout: 60)
        guard tests.passed else { throw EvolutionError.invalid(tests.output) }
        let raw = Data(tests.output.utf8), cases = try parseCases(raw)
        try EvolutionFiles.directory(output)
        let original = output.appendingPathComponent("Original.xcresult")
        try FileManager.default.copyItem(at: bundle, to: original)
        try raw.write(to: output.appendingPathComponent("tests.json"), options: .atomic)
        func export(_ subcommand: String) -> String? {
            let target = output.appendingPathComponent(subcommand)
            let result = EvolutionProcess.run("/usr/bin/xcrun", ["xcresulttool", "export", subcommand, "--path", original.path, "--output-path", target.path], timeout: 60)
            return result.passed ? target.path : nil
        }
        let report = XCTestImportReport(id: UUID(), importedAt: .now, bundlePath: original.path,
            summarySHA256: EvolutionFiles.digest(raw), cases: cases, attachmentsPath: export("attachments"), diagnosticsPath: export("diagnostics"), coveragePath: export("coverage"))
        try EvolutionFiles.save(report, output.appendingPathComponent("report.json"))
        try junit(report).write(to: output.appendingPathComponent("junit.xml"), atomically: true, encoding: .utf8)
        try html(report).write(to: output.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        return report
    }
    public static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    public static func junit(_ report: XCTestImportReport) -> String {
        let failures = report.cases.filter { !["Passed", "Skipped", "Expected Failure"].contains($0.result) }.count
        let items = report.cases.map { item in
            let content = ["Passed", "Expected Failure"].contains(item.result) ? "" : item.result == "Skipped" ? "<skipped/>" : "<failure message=\"\(escaped(item.result))\"/>"
            return "<testcase name=\"\(escaped(item.identifier))\" time=\"\(item.durationSeconds)\">\(content)</testcase>"
        }.joined(separator: "\n")
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuite name=\"XCTest\" tests=\"\(report.cases.count)\" failures=\"\(failures)\">\n\(items)\n</testsuite>\n"
    }
    public static func html(_ report: XCTestImportReport) -> String {
        let rows = report.cases.map { "<tr><td>\(escaped($0.identifier))</td><td>\(escaped($0.result))</td><td>\($0.durationSeconds)</td></tr>" }.joined()
        return "<!doctype html><html lang=\"en\"><meta charset=\"utf-8\"><title>XCTest Report</title><style>body{font:16px system-ui;padding:24px}td,th{padding:8px;text-align:left;border-bottom:1px solid #ddd}</style><h1>XCTest Report</h1><p>\(report.cases.count) cases · \(report.passed ? "Passed" : "Review failures")</p><table><tr><th>Test</th><th>Result</th><th>Seconds</th></tr>\(rows)</table></html>"
    }
}
