import CryptoKit
import Darwin
import Foundation

public enum RegistryArtifactKind: String, Codable, CaseIterable, Sendable {
    case ipa, symbols, firmware, snapshot, report, sbom, testAsset
}

public struct RegistryArtifact: Codable, Sendable, Identifiable {
    public var id: String { sha256 }
    public let sha256: String
    public let bytes: Int64
    public let kind: RegistryArtifactKind
    public let originalName: String
    public let source: String
    public let importedAt: Date
    public var approvedAt: Date?
}

/// Immutable payloads are quarantined until an explicit approval, and verified again on export.
public struct ArtifactRegistry: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    private var lockURL: URL { root.appendingPathComponent("registry.lock") }
    private func object(_ digest: String) -> URL { root.appendingPathComponent("objects/\(digest.prefix(2))/\(digest)") }
    private func metadata(_ digest: String) -> URL { root.appendingPathComponent("records/\(digest).json") }
    public func list() throws -> [RegistryArtifact] {
        let records = root.appendingPathComponent("records")
        guard FileManager.default.fileExists(atPath: records.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try EvolutionFiles.load(RegistryArtifact.self, $0) }
            .sorted { $0.importedAt > $1.importedAt }
    }
    public func ingest(_ source: URL, kind: RegistryArtifactKind, provenance: String) throws -> RegistryArtifact {
        guard !provenance.isEmpty, provenance.count <= 4096 else { throw EvolutionError.invalid("A bounded provenance/source note is required.") }
        return try EvolutionFiles.lock(lockURL) {
            let identity = try EvolutionFiles.hashFile(source)
            let payload = object(identity.digest)
            try EvolutionFiles.directory(payload.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: payload.path) {
                guard try EvolutionFiles.hashFile(payload).digest == identity.digest else { throw EvolutionError.invalid("An existing artifact failed its digest check.") }
            } else {
                let stage = payload.deletingLastPathComponent().appendingPathComponent(".stage-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: stage) }
                try FileManager.default.copyItem(at: source, to: stage)
                let copied = try EvolutionFiles.hashFile(stage)
                guard copied == identity else { throw EvolutionError.invalid("Artifact changed during import.") }
                try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: stage.path)
                try FileManager.default.moveItem(at: stage, to: payload)
            }
            if let existing = try? EvolutionFiles.load(RegistryArtifact.self, metadata(identity.digest)) { return existing }
            let record = RegistryArtifact(sha256: identity.digest, bytes: identity.bytes, kind: kind, originalName: source.lastPathComponent,
                source: provenance, importedAt: .now, approvedAt: nil)
            try EvolutionFiles.save(record, metadata(identity.digest))
            return record
        }
    }
    public func approve(_ digest: String) throws -> RegistryArtifact {
        guard EvolutionFiles.validDigest(digest) else { throw EvolutionError.invalid("Invalid SHA-256") }
        return try EvolutionFiles.lock(lockURL) {
            var record = try EvolutionFiles.load(RegistryArtifact.self, metadata(digest))
            guard try EvolutionFiles.hashFile(object(digest)).digest == digest else { throw EvolutionError.invalid("Quarantined artifact was modified.") }
            record.approvedAt = .now
            try EvolutionFiles.save(record, metadata(digest))
            return record
        }
    }
    public func export(_ digest: String, to destination: URL) throws {
        guard EvolutionFiles.validDigest(digest) else { throw EvolutionError.invalid("Invalid SHA-256") }
        try EvolutionFiles.lock(lockURL) {
            let record = try EvolutionFiles.load(RegistryArtifact.self, metadata(digest))
            guard record.approvedAt != nil else { throw EvolutionError.invalid("Approve the quarantined artifact before export.") }
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw EvolutionError.invalid("Export destination already exists.") }
            let identity = try EvolutionFiles.hashFile(object(digest))
            guard identity.digest == digest, identity.bytes == record.bytes else { throw EvolutionError.invalid("Artifact integrity verification failed.") }
            try FileManager.default.copyItem(at: object(digest), to: destination)
            guard try EvolutionFiles.hashFile(destination).digest == digest else { throw EvolutionError.invalid("Exported artifact failed its checksum.") }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }
    /// A copied prefix can be resumed across Macs; every byte is checked before promotion.
    public func resumeTransfer(_ digest: String, from source: URL, partial: URL) throws -> Int64 {
        guard EvolutionFiles.validDigest(digest), try EvolutionFiles.hashFile(source).digest == digest,
              source.standardizedFileURL != partial.standardizedFileURL else { throw EvolutionError.invalid("Invalid transfer source or expected digest.") }
        return try EvolutionFiles.lock(lockURL) {
            // O_NOFOLLOW also rejects dangling links before creating their target.
            let fd = open(partial.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw EvolutionError.invalid("Partial transfer must be a regular non-symlink file.") }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? output.close() }
            var attributes = stat()
            guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
                throw EvolutionError.invalid("Partial transfer must be a regular non-symlink file.")
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let offset = try output.seekToEnd()
            let sourceSize = try input.seekToEnd()
            guard offset <= sourceSize else { throw EvolutionError.invalid("Partial transfer exceeds source length.") }
            try input.seek(toOffset: 0); try output.seek(toOffset: 0)
            var checked: UInt64 = 0
            while checked < offset {
                let count = Int(min(1_048_576, offset - checked))
                let a = try input.read(upToCount: count), b = try output.read(upToCount: count)
                guard a == b, let a, a.count == count else { throw EvolutionError.invalid("Partial transfer prefix differs from source.") }
                checked += UInt64(count)
            }
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { try output.write(contentsOf: chunk) }
            try output.synchronize()
            guard try EvolutionFiles.hashFile(partial).digest == digest else { throw EvolutionError.invalid("Resumed transfer checksum mismatch.") }
            return Int64(sourceSize)
        }
    }
}
