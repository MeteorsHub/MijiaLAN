import AppKit
import OSLog
import SwiftUI

/// Keeps the panel's AppKit host in sync when discovery or navigation changes
/// the panel's ideal height. SwiftUI can otherwise retain a previously larger window.
/// Installed as a background: its bounds are the panel's size, not the window's proposal.
struct PanelWindowSizing: NSViewRepresentable {
    var anchorsToMenuBarIcon = false
    var anchorsTopToMenuBarIcon = false

    func makeNSView(context: Context) -> SizingView {
        let view = SizingView()
        view.anchorsToMenuBarIcon = anchorsToMenuBarIcon
        view.anchorsTopToMenuBarIcon = anchorsTopToMenuBarIcon
        return view
    }

    func updateNSView(_ view: SizingView, context: Context) {
        view.anchorsToMenuBarIcon = anchorsToMenuBarIcon
        view.anchorsTopToMenuBarIcon = anchorsTopToMenuBarIcon
        view.scheduleResize()
    }

    final class SizingView: NSView {
        var anchorsToMenuBarIcon = false
        var anchorsTopToMenuBarIcon = false
        private var resizeScheduled = false
        private weak var menuBarButton: NSStatusBarButton?
        private var lastRecordedFrame: NSRect?
        private let logger = Logger(subsystem: "com.mijialan.MijiaLAN", category: "PanelLayout")

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if window != nil {
                for name in [NSWindow.didBecomeKeyNotification, NSWindow.didMoveNotification,
                             NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(windowPositionChanged), name: name, object: nil)
                }
            }
            scheduleResize()
        }

        @objc private func windowPositionChanged(_ notification: Notification) {
            guard let changed = notification.object as? NSWindow else { return }
            if changed === window { recordWindowFrame(); scheduleResize(); return }
            guard anchorsToMenuBarIcon else { return }
            if changed === menuBarButton?.window || changed.contentView.flatMap(Self.statusButton(in:)) != nil { scheduleResize() }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleResize()
        }

        func scheduleResize() {
            guard !resizeScheduled else { return }
            resizeScheduled = true
            // Defer until SwiftUI has finished this layout pass; never mutate the
            // enclosing window while its hosting view is laying out children.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.resizeScheduled = false
                self.resizeToPanel()
            }
        }

        private func resizeToPanel() {
            guard let window, let contentView = window.contentView,
                  bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width > 0, bounds.height > 0 else { return }
            let size = NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
            let current = contentView.bounds.size
            let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
            let anchor = anchorsToMenuBarIcon ? menuBarIconFrame(on: window.screen) : nil
            // Preserve the system's vertical attachment and horizontal center.
            // Keeping minX when the width changes shifts the panel off its icon.
            var frame = window.frame
            frame.origin.x = (anchor?.midX ?? frame.midX) - frameSize.width / 2
            frame.origin.y = frame.maxY - frameSize.height
            if anchorsTopToMenuBarIcon, let anchor { frame.origin.y = anchor.minY - 8 - frameSize.height }
            frame.size = frameSize
            if anchorsToMenuBarIcon, let visible = window.screen?.visibleFrame {
                let minX = visible.minX + 8
                let maxX = max(minX, visible.maxX - 8 - frame.width)
                frame.origin.x = min(max(frame.minX, minX), maxX)
            }
            guard abs(window.frame.minX - frame.minX) > 0.5 ||
                    abs(window.frame.minY - frame.minY) > 0.5 ||
                    abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 else { return }
            // SwiftUI is already animating the finite panel bounds. Do not
            // force a synchronous redraw of a half-updated hosting hierarchy.
            window.setFrame(frame, display: false, animate: false)
            recordWindowFrame()
            logger.debug("Panel host resized: \(Int(current.width))x\(Int(current.height)) → \(Int(size.width))x\(Int(size.height)); icon anchor: \(anchor != nil)")
        }

        private func recordWindowFrame() {
            guard let window, window.isVisible, lastRecordedFrame != window.frame else { return }
            let frame = window.frame
            lastRecordedFrame = frame
            PanelTransitionDiagnostics.record("windowFrame", ["window": window.windowNumber,
                "x": frame.minX, "y": frame.minY, "width": frame.width,
                "height": frame.height, "top": frame.maxY])
        }

        /// Find the app's public status-bar button without a private window
        /// class name or KVC; the same sizing bridge also serves native previews.
        private func menuBarIconFrame(on screen: NSScreen?) -> NSRect? {
            if let button = menuBarButton, let host = button.window,
               host.isVisible, host.screen == screen, !button.isHidden, button.bounds.width > 0 {
                return host.convertToScreen(button.convert(button.bounds, to: nil))
            }
            menuBarButton = nil
            for window in NSApp.windows where window.isVisible && window.screen == screen {
                guard let root = window.contentView, let button = Self.statusButton(in: root),
                      !button.isHidden, button.bounds.width > 0 else { continue }
                menuBarButton = button
                return window.convertToScreen(button.convert(button.bounds, to: nil))
            }
            return nil
        }

        private static func statusButton(in view: NSView) -> NSStatusBarButton? {
            if let button = view as? NSStatusBarButton { return button }
            for child in view.subviews {
                if let button = statusButton(in: child) { return button }
            }
            return nil
        }
    }
}
