import Foundation
import Testing
@testable import MijiaLAN

struct MatterDiagnosticTests {
    @Test("Matter diagnostics decode only typed numeric paths and reviewed scalars; unknown private fields cannot persist")
    func privacy() throws {
        let data = Data(#"{"event":"reportSent","endpoint":19,"cluster":258,"attribute":14,"value":8100,"session":1,"caseSession":true,"token":"secret-token","ip":"192.0.2.8","did":"private-123","fabric":{"privateKey":"secret-key"},"payload":"raw"}"#.utf8)
        let record = try JSONDecoder().decode(MatterDiagnosticsRecord.self, from: data)
        #expect(record.validated() != nil)
        let text = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        for secret in ["secret-token", "192.0.2.8", "private-123", "secret-key", "payload", "fabric"] { #expect(!text.contains(secret)) }
        #expect(record.value == 8100 && record.endpoint == 19 && record.caseSession == true)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MatterDiagnosticsRecord.self, from: Data(#"{"event":"reportSent","value":"secret"}"#.utf8)) }
    }
    @Test("Matter event validation bounds arrays and scalars and rejects arbitrary reason strings")
    func bounds() throws {
        var record = MatterDiagnosticsRecord(event: .layout)
        record.numbers = Array(repeating: 1, count: 65)
        #expect(record.validated() == nil)
        record.numbers = [1, 19, 22]; record.value = .infinity
        #expect(record.validated() == nil)
        record.value = 8100; record.signature = String(repeating: "g", count: 64)
        #expect(record.validated() == nil)
        record.signature = String(repeating: "a", count: 64)
        #expect(record.validated() != nil)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(MatterDiagnosticsRecord.self, from: Data(#"{"event":"protocolFailure","reason":"token-private"}"#.utf8)) }
    }
    @Test("Matter reports persist in the same bounded journal, retain typed data across reopen, and export without device queries")
    func persistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("events.jsonl")
        let journal = DeviceEventLog(fileURL: file, scope: .offlineTest, fileLimit: 2048)
        journal.register(["private-device"])
        var record = MatterDiagnosticsRecord(event: .reportSent)
        record.run = UUID(); record.device = journal.alias(for: "private-device"); record.endpoint = 2
        record.cluster = 258; record.attribute = 14; record.value = 8100; record.dataVersion = 5
        for i in 0..<50 { record.sequence = i; journal.recordMatter(record) }
        #expect(!journal.recentText(importantOnly: true).contains("reportSent"))
        record.event = .protocolFailure; record.reason = .timeout; journal.recordMatter(record)
        for i in 100..<110 { record.sequence = i; journal.recordMatter(record) }
        #expect(journal.snapshot().filter { $0.matter?.event == .protocolFailure }.count == 11)
        #expect(journal.recentText(importantOnly: true).components(separatedBy: "\"event\":\"protocolFailure\"").count == 2)
        journal.flush()
        let reopened = DeviceEventLog(fileURL: file, scope: .offlineTest, fileLimit: 2048)
        #expect(reopened.snapshot().last?.matter?.reason == .timeout)
        #expect(reopened.snapshot().contains { $0.matter?.value == 8100 && $0.device == 1 })
        #expect(!reopened.exportText().contains("private-device"))
        #expect(reopened.recentText(importantOnly: true).contains("reportSent")) // Error keeps the preceding matching endpoint context.
        let destination = root.appendingPathComponent("export.jsonl")
        try await reopened.export(to: destination)
        let exported = try String(contentsOf: destination, encoding: .utf8)
        #expect(exported.contains("reportSent") && exported.contains("protocolFailure"))
        let traffic = await reopened.history().traffic
        #expect(traffic.bytes <= 4 * 2048)
    }
}
