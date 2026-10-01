import Foundation
import VDLEvolutionCore

enum EvolutionCLI {
    static func execute(_ command: String, arguments: [String]) async throws {
        func required(_ option: String) throws -> String {
            guard let v = value(after: option, in: arguments) else { throw EvolutionError.invalid("\(option) is required") }; return v
        }
        func json<T: Encodable>(_ value: T) throws { print(String(decoding: try EvolutionFiles.encode(value), as: UTF8.self)) }
        func url(_ option: String) throws -> URL { URL(fileURLWithPath: try required(option)) }
        let action = arguments.count > 1 ? arguments[1] : "status"
        switch command {
        case "evolution":
            let root = value(after: "--root", in: arguments).map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vphone/VirtualDeviceLab")
            let file = root.appendingPathComponent("lab-evolution.json")
            if FileManager.default.fileExists(atPath: file.path) { print(String(decoding: try Data(contentsOf: file), as: UTF8.self)) }
            else { print("{\"schemaVersion\":1,\"initialized\":false,\"version\":\"0.15.0\"}") }
        case "host-policy": try json(HostPolicyInspector.inspect(binary: value(after: "--backend", in: arguments).map { URL(fileURLWithPath: $0) }))
        case "upstream":
            let snapshot = try await UpstreamTracker.check(installedRevision: required("--revision"))
            if let path = value(after: "--output", in: arguments) { try EvolutionFiles.save(snapshot, URL(fileURLWithPath: path)) }; try json(snapshot)
        case "artifact":
            let registry = ArtifactRegistry(root: value(after: "--root", in: arguments).map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vphone/ArtifactRegistry"))
            switch action {
            case "list": try json(registry.list())
            case "import":
                guard let kind = RegistryArtifactKind(rawValue: try required("--kind")) else { throw EvolutionError.invalid("Unknown artifact kind") }
                try json(registry.ingest(url("--file"), kind: kind, provenance: required("--source")))
            case "approve": try json(registry.approve(required("--sha256")))
            case "export": try registry.export(required("--sha256"), to: url("--output"))
            case "resume": print("Verified transfer: \(try registry.resumeTransfer(required("--sha256"), from: url("--file"), partial: url("--partial"))) bytes")
            default: throw EvolutionError.invalid("artifact <list|import|approve|export|resume>")
            }
        case "matrix":
            let rows = try EvolutionFiles.load([CompatibilityMatrixRow].self, url("--file"))
            guard rows.count <= 100, !rows.isEmpty else { throw EvolutionError.invalid("Matrix requires 1…100 rows") }
            let allowed = Set(values(after: "--allow-executable", in: arguments).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            let result = try rows.map { try CompatibilityMatrixRunner.run($0, allowedExecutables: allowed) }
            if let path = value(after: "--output", in: arguments) { try EvolutionFiles.save(result, URL(fileURLWithPath: path)) }; try json(result)
            if !result.allSatisfy(\.passed) { exit(2) }
        case "fixture":
            var scenario = NetworkFixtureScenario()
            if action == "record" {
                guard let target = URL(string: try required("--url")) else { throw EvolutionError.invalid("Invalid URL") }
                scenario.responses = [try await NetworkFixtureScenario.record(url: target, path: required("--path"))]
            } else if action != "template" { throw EvolutionError.invalid("fixture <template|record>") }
            try scenario.validate(); try EvolutionFiles.save(scenario, url("--output"))
        case "fleet-recovery":
            guard arguments.contains("--coordinator-fenced") else { throw EvolutionError.invalid("Stop and fence the old coordinator, then pass --coordinator-fenced.") }
            if action == "backup" { try FleetRecoveryArchive.snapshot(root: url("--source"), destination: url("--output")) }
            else if action == "restore" { try FleetRecoveryArchive.restore(source: url("--source"), destination: url("--output")) }
            else { throw EvolutionError.invalid("fleet-recovery <backup|restore>") }
            print("Verified coordinator recovery archive: \(try required("--output"))")
        case "xctest":
            if action == "import" {
                let report = try XCTestBridge.importBundle(url("--bundle"), output: url("--output")); try json(report)
                if !report.passed { exit(2) }
            } else if action == "run" {
                let destinations = values(after: "--destination", in: arguments)
                guard !destinations.isEmpty, destinations.count <= 32 else { throw EvolutionError.invalid("Provide 1…32 Xcode destinations") }
                let output = try url("--output"); try EvolutionFiles.directory(output)
                var passed = true
                for (index, destination) in destinations.enumerated() {
                    let bundle = output.appendingPathComponent("target-\(index).xcresult")
                    let request = XcodeTestRequest(projectPath: try required("--project"), scheme: try required("--scheme"), testPlan: value(after: "--test-plan", in: arguments), destination: destination, resultBundlePath: bundle.path)
                    let run = try XCTestBridge.test(request); passed = passed && run.passed
                    guard FileManager.default.fileExists(atPath: bundle.path) else { throw EvolutionError.invalid("No Xcode result bundle: \(run.output.suffix(2000))") }
                    let report = try XCTestBridge.importBundle(bundle, output: output.appendingPathComponent("report-\(index)"))
                    passed = passed && report.passed; try json(report)
                }
                if !passed { exit(2) }
            } else { throw EvolutionError.invalid("xctest <import|run>") }
        default: throw EvolutionError.invalid("Unknown lab-tools command")
        }
    }
}
