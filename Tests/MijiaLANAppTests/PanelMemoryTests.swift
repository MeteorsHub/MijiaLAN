import AppKit
import SwiftUI
import Testing
@testable import MijiaLANApp

@MainActor
@Suite(.serialized)
struct PanelMemoryTests {
    @Test("Panel content is lazy, quick reopen retains it, idle releases it")
    func idleEviction() async throws {
        _ = NSApplication.shared
        let clock = SuspendedIdleClock()
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let lifetime = PanelContentLifetime(sleep: { _ in await clock.sleep() })
        weak var released: NSView?
        var loads = 0
        lifetime.load = {
            let view = NSHostingView(rootView: Text("Memory lifetime probe"))
            window.contentView = view
            released = view
            loads += 1
        }
        lifetime.unload = { window.contentView = nil }
        #expect(!lifetime.isLoaded)
        #expect(lifetime.prepare())
        #expect(!lifetime.prepare())
        #expect(loads == 1)
        lifetime.didHide()
        await clock.waitForSleeps(1)
        #expect(lifetime.isLoaded)
        await clock.resume(0)
        await settle { !lifetime.isLoaded }
        #expect(!lifetime.isLoaded)
        #expect(window.contentView == nil)
        #expect(released == nil)
        #expect(lifetime.prepare())
        #expect(loads == 2)
        lifetime.stop()
    }

    @Test("Reopen rejects an obsolete deadline even when cancellation arrives late")
    func canceledDeadline() async {
        let clock = SuspendedIdleClock()
        let lifetime = PanelContentLifetime(sleep: { _ in await clock.sleep() })
        var unloads = 0
        lifetime.unload = { unloads += 1 }
        lifetime.prepare()
        lifetime.didHide()
        await clock.waitForSleeps(1)
        #expect(!lifetime.prepare())
        lifetime.didHide()
        await clock.waitForSleeps(2)
        await clock.resume(0)
        for _ in 0..<20 { await Task.yield() }
        #expect(lifetime.isLoaded)
        #expect(unloads == 0)
        await clock.resume(1)
        await settle { unloads == 1 }
        #expect(unloads == 1)
        #expect(!lifetime.isLoaded)
    }

    @Test("Stopping invalidates pending eviction and the timer does not retain its owner")
    func stopAndOwnership() async {
        let clock = SuspendedIdleClock()
        var lifetime: PanelContentLifetime? = PanelContentLifetime(sleep: { _ in await clock.sleep() })
        var unloads = 0
        lifetime?.unload = { unloads += 1 }
        lifetime?.prepare()
        lifetime?.didHide()
        await clock.waitForSleeps(1)
        lifetime?.stop()
        #expect(unloads == 1)
        weak let owner = lifetime
        lifetime = nil
        #expect(owner == nil)
        await clock.resume(0)
        for _ in 0..<20 { await Task.yield() }
        #expect(unloads == 1)
    }

    @Test("Lightweight state survives unloading and removed device state is pruned")
    func retainedState() {
        let state = PanelSession(route: .device("removed"))
        state.selectedOffline = "removed"
        state.manual.host = "192.0.2.1"
        state.manual.name = "Unsaved name"
        let number = state.numberDraft(deviceID: "kept", capabilityID: "p:2:1")
        number.text = "4321"
        number.isEditing = true
        weak let removedDraft = state.numberDraft(deviceID: "removed", capabilityID: "p:2:1")
        state.scrollOffsets[.settingsDevices] = 147
        state.scrollOffsets[.device("removed")] = 300
        state.expansion(deviceID: "kept", section: "information").wrappedValue = true
        state.prune(deviceIDs: ["kept"])
        #expect(state.route == .home)
        #expect(state.selectedOffline == nil)
        #expect(state.scrollOffsets[.device("removed")] == nil)
        #expect(removedDraft == nil)
        #expect(state.scrollOffsets[.settingsDevices] == 147)
        #expect(state.manual.host == "192.0.2.1")
        #expect(state.manual.name == "Unsaved name")
        #expect(state.numberDraft(deviceID: "kept", capabilityID: "p:2:1") === number)
        #expect(number.text == "4321" && number.isEditing)
        #expect(state.expansion(deviceID: "kept", section: "information").wrappedValue)
    }

    @Test("Content eviction starts after the exit completes; reversed exit cannot evict an open panel")
    func exitCompletion() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 20, height: 20),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let presentation = PanelPresentation(window: window, reduceMotion: { true })
        defer { presentation.stop(); window.close() }
        var closes = 0
        presentation.didClose = { closes += 1 }
        presentation.show()
        presentation.hide()
        #expect(closes == 0)
        presentation.show()
        let reopened = try await waitForAppKit { presentation.phase == .open }
        try #require(reopened, "Reopened animation did not complete within the fixture deadline")
        #expect(closes == 0)
        #expect(presentation.isPresented)
        presentation.hide()
        let closed = try await waitForAppKit { presentation.phase == .closed && closes == 1 && !window.isVisible }
        #expect(closed, "Exit did not complete: phase=\(presentation.phase.rawValue), closes=\(closes), visible=\(window.isVisible)")
        #expect(closes == 1)
        #expect(!window.isVisible)
    }

    @Test("Native scroll offsets restore in either coordinate system and teardown cannot overwrite them")
    func scrollRestoration() {
        _ = NSApplication.shared
        for flipped in [true, false] {
            let session = PanelSession(route: .settingsDevices)
            session.scrollOffsets[.settingsDevices] = 180
            let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 100, height: 100),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            let document = ScrollDocument(flipped: flipped)
            document.frame = NSRect(x: 0, y: 0, width: 100, height: 700)
            let recorder = PanelScrollState.ScrollStateView(session: session, route: .settingsDevices)
            document.addSubview(recorder)
            scroll.documentView = document
            window.contentView = scroll
            recorder.isPresented = true
            window.orderFront(nil)
            recorder.layout()
            let maximum = document.bounds.height - scroll.contentView.bounds.height
            #expect(abs(scroll.contentView.bounds.minY - (flipped ? 180 : maximum - 180)) < 0.5)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: flipped ? 250 : maximum - 250))
            #expect(abs((session.scrollOffsets[.settingsDevices] ?? 0) - 250) < 0.5)
            recorder.isPresented = false
            window.orderOut(nil)
            scroll.contentView.scroll(to: .zero)
            #expect(abs((session.scrollOffsets[.settingsDevices] ?? 0) - 250) < 0.5)
            recorder.stop()
            window.contentView = nil
        }
    }

    /// Animation duration is not a completion guarantee, especially with a locked WindowServer.
    /// Service AppKit's default run loop, then yield the main actor so queued completions can run.
    private func waitForAppKit(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            pumpAppKitTurn()
            try await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
    private func pumpAppKitTurn() {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class ScrollDocument: NSView {
    let usesFlippedCoordinates: Bool
    init(flipped: Bool) { usesFlippedCoordinates = flipped; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { usesFlippedCoordinates }
}

/// Deliberately ignores cancellation so tests can deliver obsolete completions.
private actor SuspendedIdleClock {
    private var waits: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0
    private var registrations: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep() async {
        let id = nextID
        nextID += 1
        let ready = registrations.filter { $0.0 <= nextID }
        registrations.removeAll { $0.0 <= nextID }
        for (_, continuation) in ready { continuation.resume() }
        await withCheckedContinuation { waits[id] = $0 }
    }

    func waitForSleeps(_ count: Int) async {
        guard nextID < count else { return }
        await withCheckedContinuation { registrations.append((count, $0)) }
    }

    func resume(_ id: Int) { waits.removeValue(forKey: id)?.resume() }
}
