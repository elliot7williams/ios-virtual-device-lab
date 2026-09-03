import AppKit
import ApplicationServices
import Foundation

private let harnessVersion = "1.0.0"
private let requiredIdentifiers = [
    "lab.refresh", "lab.create-device", "continuity.refresh",
    "continuity.storage-relink", "continuity.labfile-apply",
    "depth.fault.inject", "depth.fault.clear", "completion.evaluate",
]

struct UICheck: Identifiable, Codable {
    let id: String
    let passed: Bool
    let evidence: String
}

struct UIReport: Identifiable, Codable {
    let schemaVersion: Int
    let id: UUID
    let generatedAt: Date
    let appPath: String
    let appVersion: String?
    let sourceRevision: String?
    let harnessVersion: String
    let checks: [UICheck]
    let observedIdentifiers: [String]
    let passed: Bool
    let reportSHA256: String?
}

enum SmokeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(message) = self { message } else { "Unknown UI smoke error." }
    }
}

final class AccessibilitySnapshot {
    private(set) var identifiers = Set<String>()
    private(set) var roles = [String]()
    private var elementsByIdentifier = [String: AXUIElement]()
    private var visited = 0

    func capture(_ element: AXUIElement) {
        visited = 0
        captureChildren(element)
    }

    func activate(identifier: String) -> Bool {
        guard let element = elementsByIdentifier[identifier] else { return false }
        let ancestors = ancestry(startingAt: element)
        let row = ancestors.first {
            stringAttribute($0, kAXRoleAttribute as CFString) == (kAXRowRole as String)
        }
        let target = row ?? element
        let selectionError = AXUIElementSetAttributeValue(
            target, kAXSelectedAttribute as CFString, kCFBooleanTrue
        )
        let pressError = AXUIElementPerformAction(target, kAXPressAction as CFString)
        let clicked = clickCenter(of: element)
        print(
            "Activate \(identifier): target=\(stringAttribute(target, kAXRoleAttribute as CFString) ?? "unknown") "
                + "select=\(selectionError.rawValue) press=\(pressError.rawValue) click=\(clicked)"
        )
        return selectionError == .success || pressError == .success || clicked
    }

    private func ancestry(startingAt element: AXUIElement) -> [AXUIElement] {
        var result = [element]
        var current = element
        for _ in 0..<12 {
            var rawParent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                current, kAXParentAttribute as CFString, &rawParent
            ) == .success, let parent = rawParent as! AXUIElement? else { break }
            result.append(parent)
            current = parent
        }
        return result
    }

    private func clickCenter(of element: AXUIElement) -> Bool {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
              let positionValue = rawPosition as! AXValue?, let sizeValue = rawSize as! AXValue?
        else { return false }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size), size.width > 0, size.height > 0
        else { return false }
        let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else { return false }
        down.post(tap: CGEventTapLocation.cghidEventTap)
        up.post(tap: CGEventTapLocation.cghidEventTap)
        return true
    }

    private func captureChildren(_ element: AXUIElement, depth: Int = 0) {
        guard depth <= 64, visited < 10_000 else { return }
        visited += 1
        if let identifier = stringAttribute(element, kAXIdentifierAttribute as CFString), !identifier.isEmpty {
            identifiers.insert(identifier)
            elementsByIdentifier[identifier] = element
        }
        if let role = stringAttribute(element, kAXRoleAttribute as CFString), !role.isEmpty {
            roles.append(role)
        }
        var rawChildren: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawChildren) == .success,
              let children = rawChildren as? [AXUIElement] else { return }
        for child in children { captureChildren(child, depth: depth + 1) }
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }
}

func value(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func usage() {
    print("""
    vdl-ui-smoke \(harnessVersion) — real macOS accessibility smoke runner

    Usage:
      vdl-ui-smoke --app <iOS Virtual Device Lab.app> --output <report.json> [--timeout <seconds>] [--keep-running]

    Run in a logged-in macOS session. The terminal or calling process must be granted
    Accessibility permission. The report is suitable for import into v1 Completion.
    """)
}

func waitForApplication(
    bundleIdentifier: String,
    excluding existingProcessIdentifiers: Set<pid_t>,
    timeout: TimeInterval
) -> NSRunningApplication? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: {
                !$0.isTerminated && !existingProcessIdentifiers.contains($0.processIdentifier)
            }) { return application }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return nil
}

func waitForWindow(_ application: AXUIElement, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement], !windows.isEmpty { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }
    return false
}

func sourceRevision(in appURL: URL) -> String? {
    let url = appURL.appendingPathComponent("Contents/Resources/build-provenance.json")
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    if let revision = object["sourceRevision"] as? String { return revision }
    let predicate = object["predicate"] as? [String: Any]
    let buildDefinition = predicate?["buildDefinition"] as? [String: Any]
    let dependencies = buildDefinition?["resolvedDependencies"] as? [[String: Any]]
    return dependencies?.compactMap { dependency in
        (dependency["digest"] as? [String: Any])?["gitCommit"] as? String
    }.first
}

@main
enum VDLUISmoke {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") { usage(); return }
        do {
            guard let appPath = value(after: "--app", in: arguments),
                  let outputPath = value(after: "--output", in: arguments) else {
                throw SmokeError.message("--app and --output are required")
            }
            let timeout = value(after: "--timeout", in: arguments).flatMap(Double.init).map { min(120, max(5, $0)) } ?? 30
            let appURL = URL(fileURLWithPath: appPath).standardizedFileURL
            let outputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
            guard appURL.pathExtension == "app", let bundle = Bundle(url: appURL),
                  let bundleIdentifier = bundle.bundleIdentifier else {
                throw SmokeError.message("--app must identify a readable macOS application bundle")
            }

            let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            let testStateRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("vdl-ui-smoke-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: testStateRoot, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let existingProcessIdentifiers = Set(
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                    .filter { !$0.isTerminated }
                    .map(\.processIdentifier)
            )
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launch.arguments = ["-na", appURL.path, "--args", "--vdl-ui-test-root", testStateRoot.path]
            try launch.run()
            launch.waitUntilExit()
            let running = waitForApplication(
                bundleIdentifier: bundleIdentifier,
                excluding: existingProcessIdentifiers,
                timeout: timeout
            )
            running?.activate(options: [])
            let applicationElement = running.map { AXUIElementCreateApplication($0.processIdentifier) }
            let windowReady = applicationElement.map { waitForWindow($0, timeout: timeout) } == true
            let snapshot = AccessibilitySnapshot()
            var navigationChecks = [UICheck]()
            if let applicationElement, windowReady {
                snapshot.capture(applicationElement)
                for (section, expectedIdentifier) in [
                    ("lab.section.continuity-&-beta", "continuity.refresh"),
                    ("lab.section.production-depth", "depth.fault.inject"),
                    ("lab.section.v1-completion", "completion.evaluate"),
                ] {
                    let activated = snapshot.activate(identifier: section)
                    if activated {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.75))
                        snapshot.capture(applicationElement)
                    }
                    let reached = activated && snapshot.identifiers.contains(expectedIdentifier)
                    navigationChecks.append(UICheck(
                        id: "navigation:\(section)", passed: reached,
                        evidence: reached ? "Activated \(section) and observed \(expectedIdentifier)." : "Could not reach \(section) through macOS Accessibility."
                    ))
                }
            }

            var checks = [
                UICheck(id: "accessibility-permission", passed: trusted, evidence: trusted ? "Accessibility permission is active." : "Grant Accessibility permission to the calling terminal or runner."),
                UICheck(id: "application-launch", passed: running != nil, evidence: running.map { "Launched PID \($0.processIdentifier)." } ?? "The application did not launch before timeout."),
                UICheck(id: "main-window", passed: windowReady, evidence: windowReady ? "A real accessibility window appeared." : "No application window appeared before timeout."),
            ]
            checks += navigationChecks
            checks += requiredIdentifiers.map { identifier in
                UICheck(
                    id: "identifier:\(identifier)", passed: snapshot.identifiers.contains(identifier),
                    evidence: snapshot.identifiers.contains(identifier)
                        ? "Observed \(identifier) in the live accessibility tree."
                        : "The live accessibility tree did not expose \(identifier)."
                )
            }
            checks.append(UICheck(
                id: "bounded-tree", passed: snapshot.identifiers.count <= 10_000,
                evidence: "Observed \(snapshot.identifiers.count) identifiers and \(snapshot.roles.count) roles within the 10,000-node bound."
            ))
            let sourceRevision = sourceRevision(in: appURL)
            let report = UIReport(
                schemaVersion: 1, id: UUID(), generatedAt: .now,
                appPath: appURL.path,
                appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                sourceRevision: sourceRevision, harnessVersion: harnessVersion,
                checks: checks, observedIdentifiers: snapshot.identifiers.sorted(),
                passed: checks.allSatisfy(\.passed), reportSHA256: nil
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: outputURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
            if !arguments.contains("--keep-running") {
                running?.terminate()
                let terminationDeadline = Date().addingTimeInterval(5)
                while running?.isTerminated == false, Date() < terminationDeadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
                if running?.isTerminated != false {
                    try? FileManager.default.removeItem(at: testStateRoot)
                }
            }
            print("\(report.passed ? "PASS" : "FAIL") — \(outputURL.path)")
            exit(report.passed ? 0 : 2)
        } catch {
            fputs("vdl-ui-smoke: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
