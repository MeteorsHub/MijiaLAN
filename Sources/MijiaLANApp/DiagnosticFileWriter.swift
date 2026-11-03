import Foundation
import Synchronization

/// Blocking filesystem access never runs on the main actor or a cooperative executor.
/// Each export stream retains at most one in-flight file and its newest pending replacement.
final class DiagnosticFileWriter: Sendable {
    private struct Write: Sendable { let data: Data; let url: URL }
    private struct State { var running = false; var pending: Write? }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "MijiaLAN.diagnostic-export", qos: .utility)
    private let write: @Sendable (Data, URL) -> Void

    init(write: @escaping @Sendable (Data, URL) -> Void = { data, url in
        try? data.write(to: url, options: .atomic)
    }) { self.write = write }

    func submit(_ data: Data, to url: URL) {
        let start = state.withLock { state in
            state.pending = Write(data: data, url: url)
            guard !state.running else { return false }
            state.running = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while let next = state.withLock({ state -> Write? in
            guard let next = state.pending else { state.running = false; return nil }
            state.pending = nil
            return next
        }) {
            write(next.data, next.url)
        }
    }
}
