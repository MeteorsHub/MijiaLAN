import Foundation
import Testing
@testable import MijiaLAN

private actor WireGate {
    private var opened = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func block() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }; entryWaiters = []
        if opened { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
    func release() { opened = true; releaseWaiter?.resume(); releaseWaiter = nil }
}
private actor WireOrder {
    var events: [String] = []
    func append(_ value: String) { events.append(value) }
}

struct CurtainRequestSchedulerTests {
    private func wait(_ scheduler: CurtainRequestScheduler, count: Int) async throws {
        for _ in 0..<2_000 {
            if await scheduler.queuedCount == count { return }
            await Task.yield()
        }
        Issue.record("Scheduler queue did not reach the expected count")
        throw CancellationError()
    }
    @Test("Stop jumps ahead of queued ordinary traffic, while the already-in-flight exchange drains first")
    func stopPriority() async throws {
        let scheduler = CurtainRequestScheduler(), gate = WireGate(), order = WireOrder()
        let first = Task { try await scheduler.perform(priority: .ordinary) { await order.append("in-flight"); await gate.block() } }
        await gate.waitUntilEntered()
        let ordinary = Task { try await scheduler.perform(priority: .ordinary) { await order.append("ordinary") } }
        try await wait(scheduler, count: 1)
        let stop = Task { try await scheduler.perform(priority: .stop) { await order.append("stop") } }
        try await wait(scheduler, count: 2)
        #expect(await order.events == ["in-flight"])
        await gate.release()
        try await first.value; try await stop.value; try await ordinary.value
        #expect(await order.events == ["in-flight", "stop", "ordinary"])
    }
    @Test("Cancelling queued traffic removes its permit and never executes its transport body")
    func cancelledWaiter() async throws {
        let scheduler = CurtainRequestScheduler(), gate = WireGate(), order = WireOrder()
        let first = Task { try await scheduler.perform(priority: .ordinary) { await gate.block() } }
        await gate.waitUntilEntered()
        let queued = Task { try await scheduler.perform(priority: .ordinary) { await order.append("must-not-send") } }
        try await wait(scheduler, count: 1)
        queued.cancel()
        await #expect(throws: (any Error).self) { try await queued.value }
        await gate.release(); try await first.value
        #expect(await order.events.isEmpty)
        #expect(await scheduler.queuedCount == 0)
    }
}
