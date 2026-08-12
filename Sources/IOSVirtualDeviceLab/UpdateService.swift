import CryptoKit
import Foundation

enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(version: String)
    case downloaded(version: String, path: String)
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Not checked"
        case .checking: "Checking…"
        case .upToDate: "Up to date"
        case let .available(version): "Version \(version) available"
        case let .downloaded(version, _): "Version \(version) downloaded and verified"
        case let .failed(message): "Update check failed: \(message)"
        }
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]
    let prerelease: Bool
    let draft: Bool

    enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
            case prerelease
            case draft
    }
}

private struct SignedUpdateManifest: Decodable {
    let schemaVersion: Int
    let version: String
    let archive: String
    let sha256: String
    let releaseURL: String
}

actor UpdateService {
    static let repository = "elliot7williams/ios-virtual-device-lab"
    private var latestRelease: GitHubRelease?

    func check(currentVersion: String, channel: UpdateChannel = .stable) async throws -> UpdateState {
        let path = channel == .stable ? "releases/latest" : "releases?per_page=20"
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(Self.repository)/\(path)")!
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("iOS-Virtual-Device-Lab/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let release: GitHubRelease
        if channel == .stable {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } else {
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            guard let candidate = releases.first(where: { !$0.draft }) else {
                throw URLError(.resourceUnavailable)
            }
            release = candidate
        }
        latestRelease = release
        let remote = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return isNewer(remote, than: currentVersion) ? .available(version: remote) : .upToDate
    }

    func downloadVerifiedUpdate(
        destinationRoot: URL,
        requireSignedManifest: Bool = true
    ) async throws -> UpdateState {
        guard let release = latestRelease else { throw URLError(.resourceUnavailable) }
        let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard let archive = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let checksum = release.assets.first(where: { $0.name == archive.name + ".sha256" })
        else { throw URLError(.fileDoesNotExist) }
        async let archiveRequest = URLSession.shared.data(from: archive.browserDownloadURL)
        async let checksumRequest = URLSession.shared.data(from: checksum.browserDownloadURL)
        let ((archiveData, archiveResponse), (checksumData, checksumResponse)) = try await (archiveRequest, checksumRequest)
        guard (archiveResponse as? HTTPURLResponse)?.statusCode == 200,
              (checksumResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let expected = String(decoding: checksumData, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased()
        let actual = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        guard expected == actual else { throw URLError(.cannotDecodeRawData) }
        try await verifySignedManifestIfConfigured(
            release: release,
            archiveName: archive.name,
            archiveSHA256: actual,
            version: version,
            required: requireSignedManifest
        )
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let destination = destinationRoot.appendingPathComponent(archive.name)
        try archiveData.write(to: destination, options: .atomic)
        return .downloaded(version: version, path: destination.path)
    }

    func releasePage() -> URL? { latestRelease?.htmlURL }

    private func verifySignedManifestIfConfigured(
        release: GitHubRelease,
        archiveName: String,
        archiveSHA256: String,
        version: String,
        required: Bool
    ) async throws {
        guard let publicKey = Bundle.main.url(forResource: "update-public-key", withExtension: "pem") else {
            if required { throw URLError(.userAuthenticationRequired) }
            return
        }
        guard let manifestAsset = release.assets.first(where: { $0.name == "update-manifest.json" }),
              let signatureAsset = release.assets.first(where: { $0.name == "update-manifest.json.sig" })
        else { throw URLError(.fileDoesNotExist) }
        async let manifestRequest = URLSession.shared.data(from: manifestAsset.browserDownloadURL)
        async let signatureRequest = URLSession.shared.data(from: signatureAsset.browserDownloadURL)
        let ((manifestData, manifestResponse), (signatureData, signatureResponse)) = try await (manifestRequest, signatureRequest)
        guard (manifestResponse as? HTTPURLResponse)?.statusCode == 200,
              (signatureResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vdl-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("manifest.json")
        let signatureURL = root.appendingPathComponent("manifest.sig")
        try manifestData.write(to: manifestURL, options: .atomic)
        try signatureData.write(to: signatureURL, options: .atomic)
        let verification = ProcessExecutor.run(
            executable: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: [
                "dgst", "-sha256", "-verify", publicKey.path,
                "-signature", signatureURL.path, manifestURL.path,
            ],
            timeout: 30
        )
        guard verification.succeeded else { throw URLError(.secureConnectionFailed) }
        let manifest = try JSONDecoder().decode(SignedUpdateManifest.self, from: manifestData)
        guard manifest.schemaVersion == 1,
              manifest.version == version,
              manifest.archive == archiveName,
              manifest.sha256.lowercased() == archiveSHA256 else {
            throw URLError(.cannotParseResponse)
        }
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
