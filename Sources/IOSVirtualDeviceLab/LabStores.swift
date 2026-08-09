import CryptoKit
import Foundation

enum TestRunStore {
    static func load(paths: LabPaths) -> [TestRunRecord] {
        decodeFile([TestRunRecord].self, from: paths.stateRoot.appendingPathComponent("test-runs.json")) ?? []
    }

    static func save(_ records: [TestRunRecord], paths: LabPaths) throws {
        try encodeFile(records, to: paths.stateRoot.appendingPathComponent("test-runs.json"))
    }
}

enum WorkflowStore {
    static let builtIns: [AutomationWorkflow] = [
        AutomationWorkflow(
            id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000001")!,
            name: "Boot Smoke Test",
            steps: [
                AutomationStep(.boot),
                AutomationStep(.waitForGuest, value: "120"),
                AutomationStep(.screenshot),
                AutomationStep(.stop),
                AutomationStep(.diagnostics),
            ],
            isBuiltIn: true
        ),
        AutomationWorkflow(
            id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000002")!,
            name: "Home Screen Capture",
            steps: [
                AutomationStep(.pressHome),
                AutomationStep(.screenshot),
                AutomationStep(.diagnostics),
            ],
            isBuiltIn: true
        ),
        AutomationWorkflow(
            id: UUID(uuidString: "A11CE000-0000-4000-8000-000000000003")!,
            name: "Stop and Snapshot",
            steps: [
                AutomationStep(.stop),
                AutomationStep(.snapshot, value: "Automated Safe State"),
            ],
            isBuiltIn: true
        ),
    ]

    static func load(paths: LabPaths) -> [AutomationWorkflow] {
        let custom = decodeFile(
            [AutomationWorkflow].self,
            from: paths.stateRoot.appendingPathComponent("automation-workflows.json")
        ) ?? []
        return builtIns + custom.filter { !$0.isBuiltIn }
    }

    static func saveCustom(_ records: [AutomationWorkflow], paths: LabPaths) throws {
        try encodeFile(
            records.filter { !$0.isBuiltIn },
            to: paths.stateRoot.appendingPathComponent("automation-workflows.json")
        )
    }
}

enum PluginRegistry {
    static func root(paths: LabPaths) -> URL {
        paths.stateRoot.appendingPathComponent("Plugins", isDirectory: true)
    }

    static func prepare(paths: LabPaths) throws {
        let directory = root(paths: paths)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let readme = directory.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) {
            let text = """
            # iOS Virtual Device Lab plugins

            Add one JSON descriptor per plugin. A plugin runs only after an explicit user action.

            ```json
            {
              "id": "com.example.lab-tools",
              "name": "Example Lab Tools",
              "version": "1.0.0",
              "executable": "/absolute/path/to/lab-tools",
              "capabilities": ["diagnostics"],
              "arguments": [],
              "description": "Optional diagnostics integration",
              "apiVersion": 1,
              "trusted": false,
              "permissions": ["diagnostics"]
            }
            ```

            The manager invokes the executable with descriptor arguments followed by the selected
            capability. Context is provided through `LAB_DEVICE_NAME`, `LAB_DEVICE_BUNDLE`,
            `LAB_DATA_ROOT`, and `LAB_OUTPUT_ROOT` environment variables.
            """
            try text.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    static func loadPlugins(paths: LabPaths) -> [PluginDescriptor] {
        let directory = root(paths: paths)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { decodeFile(PluginDescriptor.self, from: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func run(
        _ plugin: PluginDescriptor,
        capability: String,
        device: VirtualDevice?,
        paths: LabPaths,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> CommandResult {
        guard plugin.capabilities.contains(capability) else {
            return CommandResult(
                executable: plugin.executable,
                arguments: plugin.arguments + [capability],
                output: "Plugin does not declare the \(capability) capability",
                exitCode: 64
            )
        }
        guard plugin.apiVersion ?? 1 == 1 else {
            return CommandResult(
                executable: plugin.executable,
                arguments: plugin.arguments + [capability],
                output: "Plugin API version \(plugin.apiVersion ?? 0) is not supported; this app supports version 1",
                exitCode: 65
            )
        }
        guard plugin.trusted == true else {
            return CommandResult(
                executable: plugin.executable,
                arguments: plugin.arguments + [capability],
                output: "Plugin is not trusted. Review its executable and grant trust in the Plugins screen.",
                exitCode: 77
            )
        }
        if let permissions = plugin.permissions, !permissions.contains(capability) {
            return CommandResult(
                executable: plugin.executable,
                arguments: plugin.arguments + [capability],
                output: "Plugin has not been granted the \(capability) permission",
                exitCode: 77
            )
        }
        guard FileManager.default.isExecutableFile(atPath: plugin.executable) else {
            return CommandResult(
                executable: plugin.executable,
                arguments: plugin.arguments + [capability],
                output: "Plugin executable is missing or not executable",
                exitCode: 126
            )
        }
        if let expected = plugin.executableSHA256 {
            guard let actual = try? sha256(of: URL(fileURLWithPath: plugin.executable)), actual == expected else {
                return CommandResult(
                    executable: plugin.executable,
                    arguments: plugin.arguments + [capability],
                    output: "Plugin executable changed after it was trusted; review and trust it again",
                    exitCode: 77
                )
            }
        }
        let outputRoot = paths.stateRoot.appendingPathComponent("Plugin Output", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        var environment = [
            "LAB_DATA_ROOT": paths.dataRoot.path,
            "LAB_OUTPUT_ROOT": outputRoot.path,
        ]
        if let device {
            environment["LAB_DEVICE_NAME"] = device.name
            environment["LAB_DEVICE_BUNDLE"] = device.bundleURL.path
        }
        return await ProcessExecutor.runAsync(
            executable: URL(fileURLWithPath: plugin.executable),
            arguments: plugin.arguments + [capability],
            environment: environment,
            timeout: 300,
            onLine: onLine
        )
    }

    static func setTrusted(_ plugin: PluginDescriptor, trusted: Bool, paths: LabPaths) throws {
        let directory = root(paths: paths)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        guard let descriptorURL = files.first(where: {
            $0.pathExtension.lowercased() == "json"
                && decodeFile(PluginDescriptor.self, from: $0)?.id == plugin.id
        }) else { throw CocoaError(.fileNoSuchFile) }
        var updated = plugin
        updated.apiVersion = updated.apiVersion ?? 1
        updated.trusted = trusted
        updated.permissions = updated.permissions ?? updated.capabilities
        updated.executableSHA256 = trusted
            ? try sha256(of: URL(fileURLWithPath: plugin.executable))
            : nil
        try encodeFile(updated, to: descriptorURL)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private func decodeFile<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? decoder.decode(type, from: data)
}

private func encodeFile<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: .atomic)
}
