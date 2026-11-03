import AppKit
import Testing
@testable import MijiaLANApp

@MainActor
@Suite(.serialized)
struct PanelToggleTests {
    private let icon = NSRect(x: 900, y: 1100, width: 24, height: 24)

    @Test("A status-button mouse-down cannot turn its mouse-up close into a reopen")
    func statusClickCloses() {
        let panel = makePresentation()
        panel.show()
        for _ in 0..<10 {
            panel.hideForOutsideMouseDown(at: NSPoint(x: icon.midX, y: icon.midY), statusItemFrame: icon)
            #expect(panel.isPresented)
            // The button's mouse-up action must still see the open panel.
            if panel.isPresented { panel.hide() } else { panel.show() }
            #expect(!panel.isPresented)
            // Next click can reverse the exit, just like a normal toggle.
            panel.show()
        }
        panel.stop()
    }

    @Test("A click outside the status item dismisses the panel")
    func outsideClickCloses() {
        let panel = makePresentation()
        panel.show()
        panel.hideForOutsideMouseDown(at: NSPoint(x: icon.minX - 10, y: icon.midY), statusItemFrame: icon)
        #expect(!panel.isPresented)
        panel.stop()
    }

    @Test("Missing status geometry still allows an outside click to dismiss")
    func missingIconFrame() {
        let panel = makePresentation()
        panel.show()
        panel.hideForOutsideMouseDown(at: .zero, statusItemFrame: nil)
        #expect(!panel.isPresented)
        panel.stop()
    }

    private func makePresentation() -> PanelPresentation {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 20, height: 20),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return PanelPresentation(window: window, reduceMotion: { true })
    }
}
