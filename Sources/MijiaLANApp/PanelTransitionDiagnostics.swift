import Foundation

/// Opt-in, local layout measurements for native transition verification.
/// No device data or credentials are recorded and normal runs do no work here.
@MainActor
enum PanelTransitionDiagnostics {
    private static let path = ProcessInfo.processInfo.environment["MIJIALAN_NAV_DIAGNOSTICS_OUTPUT"]
    private static var events: [[String: Any]] = []
    private static var flushTask: Task<Void, Never>?
    private static let writer = DiagnosticFileWriter()

    static func record(_ event: String, _ values: @autoclosure () -> [String: Any]) {
        guard path != nil else { return }
        var entry = values()
        entry["event"] = event
        entry["timeMS"] = ProcessInfo.processInfo.systemUptime * 1000
        if events.count >= 2_000 { events.removeFirst(events.count - 1_999) }
        events.append(entry)
    }

    static func flushSoon() {
        guard let path else { return }
        flushTask?.cancel()
        flushTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            if let data = try? JSONSerialization.data(withJSONObject: ["events": events], options: [.prettyPrinted, .sortedKeys]) {
                writer.submit(data, to: URL(fileURLWithPath: path))
            }
            flushTask = nil
        }
    }
}
