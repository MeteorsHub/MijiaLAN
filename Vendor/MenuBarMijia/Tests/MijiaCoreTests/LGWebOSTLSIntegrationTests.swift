#if os(macOS)
import Foundation
import Testing
@testable import MijiaCore

struct LGWebOSTLSIntegrationTests {
    @Test("Real TLS rejects a replaced TV certificate and accepts it only after re-pair", .timeLimit(.minutes(1)))
    func certificateReplacementAtTLSBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lg-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "test.lg.tls.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let trust = LGCertificateTrust(defaults: defaults)
        let firstPort = Int.random(in: 49152..<56000)
        let secondPort = Int.random(in: 56000..<65000)
        let first = try startServer(directory: directory, name: "original", port: firstPort)
        defer { stop(first) }
        let second = try startServer(directory: directory, name: "replacement", port: secondPort)
        defer { stop(second) }
        let firstURL = try #require(URL(string: "https://127.0.0.1:\(firstPort)/"))
        let secondURL = try #require(URL(string: "https://127.0.0.1:\(secondPort)/"))

        let accepted = try await request(firstURL, trust: trust)
        #expect(accepted == 200)
        do {
            _ = try await request(secondURL, trust: trust)
            Issue.record("A replacement certificate completed TLS without re-pairing")
        } catch {
            #expect(trust.failure(for: "127.0.0.1") == .changed)
        }
        #expect(try await request(firstURL, trust: trust) == 200)
        #expect(trust.reset(host: "127.0.0.1"))
        #expect(try await request(secondURL, trust: trust) == 200)
        do {
            _ = try await request(firstURL, trust: trust)
            Issue.record("The discarded certificate completed TLS after re-pairing")
        } catch {
            #expect(trust.failure(for: "127.0.0.1") == .changed)
        }
    }

    private func startServer(directory: URL, name: String, port: Int) throws -> Process {
        let certificate = directory.appendingPathComponent("\(name).crt").path
        let key = directory.appendingPathComponent("\(name).key").path
        let generate = Process()
        generate.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        generate.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                              "-subj", "/CN=\(name)", "-keyout", key, "-out", certificate]
        generate.standardOutput = FileHandle.nullDevice
        generate.standardError = FileHandle.nullDevice
        try generate.run()
        generate.waitUntilExit()
        try #require(generate.terminationStatus == 0, "Could not generate isolated test certificates")

        let server = Process()
        server.executableURL = generate.executableURL
        server.arguments = ["s_server", "-accept", "\(port)", "-cert", certificate, "-key", key, "-www", "-quiet"]
        server.standardInput = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        return server
    }

    private func stop(_ process: Process) {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private func request(_ url: URL, trust: LGCertificateTrust) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration, delegate: LGWebOSTrustDelegate(trustStore: trust), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for attempt in 0..<40 {
            do {
                let (_, response) = try await session.data(from: url)
                return try #require(response as? HTTPURLResponse).statusCode
            } catch let error as URLError where error.code == .cannotConnectToHost && attempt < 39 {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        throw URLError(.cannotConnectToHost)
    }
}
#endif
