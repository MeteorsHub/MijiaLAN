import AppKit
import SwiftUI

/// Keep scroll values outside the view tree. Restore the native clip view after
/// its viewport has been laid out; SwiftUI's initial point request can be lost
/// when a detached hosting view is recreated with a changing panel height.
struct PanelScrollState: NSViewRepresentable {
    let session: PanelSession
    let route: ControlCenterRoute
    let isPresented: Bool

    func makeNSView(context: Context) -> ScrollStateView {
        ScrollStateView(session: session, route: route)
    }

    func updateNSView(_ view: ScrollStateView, context: Context) {
        view.isPresented = isPresented
        view.scheduleRestore()
    }

    static func dismantleNSView(_ view: ScrollStateView, coordinator: ()) { view.stop() }

    final class ScrollStateView: NSView {
        let session: PanelSession
        let route: ControlCenterRoute
        var isPresented = false
        private var desiredOffset: CGFloat?
        private weak var observedClip: NSClipView?
        private var scheduled = false
        private var restoring = false
        private var stopped = false

        init(session: PanelSession, route: ControlCenterRoute) {
            self.session = session; self.route = route
            desiredOffset = session.scrollOffsets[route] ?? 0
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            observedClip = nil
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                    name: NSWindow.didBecomeKeyNotification, object: window)
                scheduleRestore()
            }
        }

        override func layout() { super.layout(); restoreIfReady() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); scheduleRestore() }

        func scheduleRestore() {
            guard !scheduled, !stopped, desiredOffset != nil else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                scheduled = false
                restoreIfReady()
            }
        }

        @objc private func windowBecameKey() { scheduleRestore() }

        private func restoreIfReady() {
            guard !stopped, let scroll = enclosingScrollView, let document = scroll.documentView,
                  scroll.contentView.bounds.height > 0, document.bounds.height > 0 else { return }
            let clip = scroll.contentView
            if observedClip !== clip {
                if let observedClip { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClip) }
                observedClip = clip
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                    name: NSView.boundsDidChangeNotification, object: clip)
            }
            guard let desiredOffset else { return }
            let maximum = max(0, document.bounds.height - clip.bounds.height)
            guard desiredOffset == 0 || maximum > 0 else { return }
            let offset = min(maximum, max(0, desiredOffset))
            restoring = true
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: document.isFlipped ? offset : maximum - offset))
            scroll.reflectScrolledClipView(clip)
            restoring = false
            // Keep the request through offscreen layout, then commit it after
            // AppKit orders the prepared window and finalizes the viewport.
            if window?.isVisible == true, isPresented {
                self.desiredOffset = nil
                PanelTransitionDiagnostics.record("scrollRestored", ["route": route.diagnosticName, "offset": offset])
            }
        }

        @objc private func scrolled() {
            guard !stopped, !restoring, desiredOffset == nil, isPresented, window?.isVisible == true,
                  let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            let maximum = max(0, document.bounds.height - clip.bounds.height)
            session.scrollOffsets[route] = max(0, document.isFlipped ? clip.bounds.minY : maximum - clip.bounds.minY)
        }

        func stop() {
            stopped = true
            NotificationCenter.default.removeObserver(self)
        }
    }
}
