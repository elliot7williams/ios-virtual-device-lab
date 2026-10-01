import Foundation

enum IPSWManifestInspectorError: LocalizedError {
    case manifestMissing
    case extractionFailed(String)
    case invalidPropertyList

    var errorDescription: String? {
        switch self {
        case .manifestMissing:
            "BuildManifest.plist was not found in the IPSW"
        case let .extractionFailed(message):
            "BuildManifest.plist could not be extracted: \(message)"
        case .invalidPropertyList:
            "BuildManifest.plist is not a readable property list"
        }
    }
}

enum IPSWManifestInspector {
    static func inspect(_ url: URL, archiveEntries: [String]? = nil) throws -> IPSWManifestMetadata {
        let entries = archiveEntries ?? listEntries(url)
        guard let entry = entries.first(where: {
            $0 == "BuildManifest.plist" || $0.hasSuffix("/BuildManifest.plist")
        }) else {
            throw IPSWManifestInspectorError.manifestMissing
        }

        let data = try extract(entry: entry, from: url)
        guard let root = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw IPSWManifestInspectorError.invalidPropertyList
        }

        let productVersion = string(root["ProductVersion"])
        let productBuildVersion = string(root["ProductBuildVersion"])
        var supported = root["SupportedProductTypes"] as? [String] ?? []
        let identities = (root["BuildIdentities"] as? [[String: Any]] ?? []).map { identity in
            let info = identity["Info"] as? [String: Any]
            let deviceClass = string(info?["DeviceClass"])
                ?? string(identity["DeviceClass"])
            if let product = string(info?["ProductType"]), !supported.contains(product) {
                supported.append(product)
            }
            return IPSWBuildIdentity(
                deviceClass: deviceClass,
                variant: string(info?["Variant"]) ?? string(info?["RestoreBehavior"]),
                boardID: identifier(identity["ApBoardID"]),
                chipID: identifier(identity["ApChipID"])
            )
        }

        supported = Array(Set(supported)).sorted()
        return IPSWManifestMetadata(
            productVersion: productVersion,
            productBuildVersion: productBuildVersion,
            supportedProductTypes: supported,
            buildIdentities: identities,
            sourceEntry: entry
        )
    }

    static func preferredProductType(
        from metadata: IPSWManifestMetadata,
        filenameDevice: String?
    ) -> String? {
        if let filenameDevice, metadata.supportedProductTypes.contains(filenameDevice) {
            return filenameDevice
        }
        return metadata.primaryProductType ?? metadata.supportedProductTypes.first
    }

    private static func listEntries(_ url: URL) -> [String] {
        let result = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-Z1", url.path],
            timeout: 120
        )
        guard result.succeeded else { return [] }
        return result.output.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    private static func extract(entry: String, from url: URL) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw IPSWManifestInspectorError.extractionFailed(error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw IPSWManifestInspectorError.extractionFailed(message.isEmpty ? "unzip exited with \(process.terminationStatus)" : message)
        }
        return data
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    private static func identifier(_ value: Any?) -> String? {
        if let value = value as? NSNumber {
            return String(format: "0x%llX", value.uint64Value)
        }
        return string(value)
    }
}
