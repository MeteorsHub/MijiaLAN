import Foundation
import Testing
import MijiaCore
@testable import MijiaLAN

/// Virtual monotonic time; cancelled timers wake immediately, without advancing the clock.
private final class PollTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    private var waits: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
    var now: Duration { lock.withLock { value } }
    var deadlines: [Duration] { lock.withLock { waits.values.map(\.0).sorted() } }
    var clock: DevicePollingLoop.Clock { .init(now: { self.now }, sleep: { try await self.sleep($0) }) }
    private func sleep(_ delay: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { waits[id] = (value + delay, continuation) }
                }
            }
        } onCancel: {
            self.lock.withLock { self.waits.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        }
    }
    func advance(_ delay: Duration) {
        lock.withLock {
            value += delay
            for id in Array(waits.keys) where waits[id]!.0 <= value { waits.removeValue(forKey: id)?.1.resume() }
        }
    }
}

@MainActor struct DevicePollingTests {
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<2_000 { if condition() { return }; await Task.yield() }
        #expect(condition())
    }
    @Test("Defaults are 5 seconds visible and 30 hidden, persist independently, and reject invalid stored intervals")
    func defaultsAndPersistence() throws {
        let name = "polling-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(DevicePollingIntervals.load(from: defaults) == .init())
        #expect(DevicePollingIntervals().interval(panelVisible: true) == .seconds(5))
        #expect(DevicePollingIntervals().interval(panelVisible: false) == .seconds(30))
        DevicePollingIntervals(foregroundSeconds: 7, backgroundSeconds: 81).save(to: defaults)
        let reopened = try #require(UserDefaults(suiteName: name))
        #expect(DevicePollingIntervals.load(from: reopened) == .init(foregroundSeconds: 7, backgroundSeconds: 81))
        reopened.set(0, forKey: DevicePollingIntervals.foregroundKey)
        reopened.set(3_601, forKey: DevicePollingIntervals.backgroundKey)
        #expect(DevicePollingIntervals.load(from: reopened) == .init())
        #expect(DevicePollingIntervals(foregroundSeconds: -1, backgroundSeconds: 9_000) == .init(foregroundSeconds: 1, backgroundSeconds: 3_600))
    }
    @Test("Round duration counts toward start-to-start cadence, and repeated starts create only one loop")
    func countsElapsed() async {
        let time = PollTime()
        let scheduler = DevicePollingLoop(interval: .seconds(5), clock: time.clock)
        defer { scheduler.stop() }
        var starts: [Duration] = []
        let refresh: @MainActor @Sendable () async -> Void = { starts.append(time.now); time.advance(.seconds(2)) }
        scheduler.start(refresh: refresh); scheduler.start(refresh: refresh)
        await settle { time.deadlines == [.seconds(5)] }
        #expect(starts == [.zero])
        time.advance(.seconds(2)); await Task.yield()
        #expect(starts.count == 1)
        time.advance(.seconds(1))
        await settle { starts.count == 2 && time.deadlines == [.seconds(10)] }
        #expect(starts == [.zero, .seconds(5)])
    }
    @Test("Panel opening interrupts a hidden 30-second wait; closing and setting edits recalculate from the last start")
    func visibilityAndEdits() async {
        let time = PollTime(), intervals = DevicePollingIntervals()
        let loop = DevicePollingLoop(interval: intervals.interval(panelVisible: false), clock: time.clock)
        defer { loop.stop() }
        var starts: [Duration] = []
        loop.start { starts.append(time.now) }
        await settle { time.deadlines == [.seconds(30)] }
        time.advance(.seconds(6))
        loop.setInterval(intervals.interval(panelVisible: true))
        await settle { starts == [.zero, .seconds(6)] && time.deadlines == [.seconds(11)] }
        time.advance(.seconds(1)); loop.setInterval(intervals.interval(panelVisible: false))
        await settle { time.deadlines == [.seconds(36)] }
        time.advance(.seconds(2)); loop.setInterval(.seconds(4))
        await settle { time.deadlines == [.seconds(10)] }
        time.advance(.seconds(1))
        await settle { starts.count == 3 && time.deadlines == [.seconds(14)] }
        #expect(starts.last == .seconds(10))
    }
    @Test("Capability provider drives DeviceController's single configurable round, including the verified curtain hook")
    func controllerWiring() async throws {
        let suite = "controller-cadence-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let time = PollTime(), config = LocalHomeConfig()
        let api = LANMiotAPI(config: { config }, transport: FakeMiioNetwork())
        let controller = DeviceController(api: api, config: { config }, pollingDefaults: defaults, pollingClock: time.clock)
        defer { controller.shutdown() }
        var starts: [Duration] = []
        controller.refreshCurtains = { starts.append(time.now) }
        let provider = CapabilityHomeProvider(controller: controller)
        let stream = provider.events()
        let subscriber = Task { for await _ in stream {} }
        defer { subscriber.cancel() }
        await settle { starts == [.zero] && time.deadlines == [.seconds(30)] }
        time.advance(.seconds(8))
        await provider.setPollingContext(.init(panelVisible: true))
        await settle { starts == [.zero, .seconds(8)] && time.deadlines == [.seconds(13)] }
        controller.setPollingIntervals(.init(foregroundSeconds: 9, backgroundSeconds: 60))
        await settle { time.deadlines == [.seconds(17)] }
        #expect(DevicePollingIntervals.load(from: defaults) == .init(foregroundSeconds: 9, backgroundSeconds: 60))
        await provider.setPollingContext(.init(panelVisible: false))
        await settle { time.deadlines == [.seconds(68)] }
        await provider.refreshNow() // Explicit refresh remains independent of the periodic wait.
        #expect(starts == [.zero, .seconds(8), .seconds(8)])
        #expect(time.deadlines == [.seconds(68)])
        await api.shutdown()
    }
    @Test("A slow round is never cancelled or overlapped on edits; missed periods produce no catch-up burst")
    func slowRound() async {
        let time = PollTime()
        let scheduler = DevicePollingLoop(interval: .seconds(5), clock: time.clock)
        defer { scheduler.stop() }
        var starts: [Duration] = [], active = 0, maximumActive = 0
        var finish: CheckedContinuation<Void, Never>?
        scheduler.start {
            active += 1; maximumActive = max(maximumActive, active); starts.append(time.now)
            if starts.count == 1 { await withCheckedContinuation { finish = $0 } }
            active -= 1
        }
        await settle { finish != nil }
        time.advance(.seconds(34)); scheduler.setInterval(.seconds(7))
        for _ in 0..<20 { await Task.yield() }
        #expect(starts == [.zero] && active == 1)
        finish?.resume(); finish = nil
        await settle { starts.count == 2 && time.deadlines == [.seconds(41)] }
        #expect(starts == [.zero, .seconds(34)] && maximumActive == 1)
        for _ in 0..<20 { await Task.yield() }
        #expect(starts.count == 2)
        scheduler.stop(); time.advance(.seconds(100))
        for _ in 0..<20 { await Task.yield() }
        #expect(starts.count == 2 && time.deadlines.isEmpty)
    }
}
