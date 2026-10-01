@preconcurrency import Network
import Foundation
import VDLEvolutionCore

final class FixtureServer: @unchecked Sendable {
    let scenario: NetworkFixtureScenario
    let queue = DispatchQueue(label: "vdl.fixture")
    var http: NWListener?
    var dns: NWListener?
    init(_ scenario: NetworkFixtureScenario) { self.scenario = scenario }
    func run() throws {
        try scenario.validate()
        let tcp = NWParameters.tcp
        tcp.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: scenario.port)!)
        http = try NWListener(using: tcp)
        http?.stateUpdateHandler = { state in
            if case .ready = state { print("HTTP fixture ready at http://127.0.0.1:\(self.scenario.port)") }
            if case let .failed(error) = state { FileHandle.standardError.write(Data("Fixture listener: \(error)\n".utf8)); exit(1) }
        }
        http?.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            let timeout = DispatchWorkItem { connection.cancel() }
            self.queue.asyncAfter(deadline: .now() + 15, execute: timeout)
            self.read(connection, buffer: Data(), timeout: timeout)
        }
        http?.start(queue: queue)
        let udp = NWParameters.udp
        udp.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: scenario.dnsPort)!)
        dns = try NWListener(using: udp)
        dns?.stateUpdateHandler = { state in
            if case .ready = state { print("DNS fixture ready at 127.0.0.1:\(self.scenario.dnsPort)") }
            if case let .failed(error) = state { FileHandle.standardError.write(Data("DNS listener: \(error)\n".utf8)); exit(1) }
        }
        dns?.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            connection.receiveMessage { data, _, _, _ in
                guard let data, data.count <= 4096, !self.scenario.offline, let response = DNSFixture.response(to: data, records: self.scenario.dnsRecords) else {
                    connection.cancel(); return
                }
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        dns?.start(queue: queue)
        dispatchMain()
    }
    func read(_ connection: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var next = buffer
            if let data { next.append(data) }
            guard next.count <= 1_048_576 else { connection.cancel(); return }
            if let marker = next.range(of: Data("\r\n\r\n".utf8)), let header = String(data: next[..<marker.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n"), words = (lines.first ?? "").split(separator: " ")
                guard words.count == 3 else { connection.cancel(); return }
                let lengthLine = lines.first { $0.lowercased().hasPrefix("content-length:") }
                let length = lengthLine.flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
                guard length >= 0, length <= 1_048_576 else { connection.cancel(); return }
                if next.count < marker.upperBound + length { self.read(connection, buffer: next, timeout: timeout); return }
                timeout.cancel()
                let method = String(words[0]), path = String(words[1])
                let identity = "\(method) \(path):\(EvolutionFiles.digest(next.suffix(length)))"
                guard !self.scenario.drops(identity) else { connection.cancel(); return }
                let fixture = self.scenario.responses.first { $0.method == method && $0.path == path }
                    ?? HTTPFixture(path: path, status: 404, body: "{\"error\":\"fixture not found\"}")
                let body = method == "HEAD" ? Data() : Data(fixture.body.utf8)
                let date = self.scenario.simulatedDate.map { "X-VDL-Simulated-Date: \(ISO8601DateFormatter().string(from: $0))\r\n" } ?? ""
                let head = Data("HTTP/1.1 \(fixture.status) Fixture\r\nContent-Type: \(fixture.contentType)\r\nContent-Length: \(body.count)\r\n\(date)Connection: close\r\n\r\n".utf8)
                self.queue.asyncAfter(deadline: .now() + .milliseconds(self.scenario.latencyMilliseconds)) {
                    connection.send(content: head, completion: .contentProcessed { sendError in
                        if sendError != nil { connection.cancel() } else { self.send(body, offset: 0, connection: connection) }
                    })
                }
            } else if complete || error != nil { connection.cancel() }
            else { self.read(connection, buffer: next, timeout: timeout) }
        }
    }
    func send(_ data: Data, offset: Int, connection: NWConnection) {
        guard offset < data.count else { connection.cancel(); return }
        let chunkSize = scenario.bytesPerSecond == 0 ? 65536 : max(1, min(65536, scenario.bytesPerSecond / 10))
        let end = min(data.count, offset + chunkSize)
        connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { error in
            if error != nil || end == data.count { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + (self.scenario.bytesPerSecond == 0 ? 0 : Double(end - offset) / Double(self.scenario.bytesPerSecond))) {
                self.send(data, offset: end, connection: connection)
            }
        })
    }
}

@main
enum VDLFixture {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.isEmpty {
            print("vdl-fixture 1.2.0\nUsage: vdl-fixture --scenario <scenario.json>\nLoopback HTTP/DNS fixtures with deterministic loss, latency, bandwidth, offline mode, and simulated-date headers.")
            return
        }
        do {
            guard let index = arguments.firstIndex(of: "--scenario"), arguments.indices.contains(index + 1) else { throw EvolutionError.invalid("--scenario is required") }
            let scenario = try EvolutionFiles.load(NetworkFixtureScenario.self, URL(fileURLWithPath: arguments[index + 1]))
            try FixtureServer(scenario).run()
        } catch { FileHandle.standardError.write(Data("vdl-fixture: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
}
