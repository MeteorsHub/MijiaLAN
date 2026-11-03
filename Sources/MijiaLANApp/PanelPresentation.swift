import AppKit
import Observation
import SwiftUI

/// Owns ordering as well as animation: the window stays onscreen until its exit
/// finishes. A newer show/hide request invalidates an older completion.
@MainActor @Observable
final class PanelPresentation {
    enum Phase: String { case closed, opening, open, closing }

    private(set) var phase: Phase = .closed
    private(set) var isPresented = false
    private(set) var progress: CGFloat = 0
    private(set) var usesReducedMotion = false
    @ObservationIgnored let window: NSWindow
    @ObservationIgnored var visibilityChanged: ((Bool) -> Void)?
    @ObservationIgnored var didClose: (() -> Void)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let reduceMotion: () -> Bool

    init(window: NSWindow, reduceMotion: @escaping () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }) {
        self.window = window
        self.reduceMotion = reduceMotion
        window.animationBehavior = .none
        window.alphaValue = 0
    }

    func show() {
        guard !isPresented else { return }
        generation += 1
        let request = generation
        usesReducedMotion = reduceMotion()
        isPresented = true
        phase = .opening
        window.ignoresMouseEvents = false
        if !window.isVisible {
            progress = 0
            window.alphaValue = 0
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        window.makeKeyAndOrderFront(nil)
        visibilityChanged?(true)
        animate(to: 1, request: request) { [weak self] in self?.phase = .open }
    }

    func hide() {
        guard isPresented, window.attachedSheet == nil else { return }
        generation += 1
        let request = generation
        usesReducedMotion = reduceMotion()
        isPresented = false
        phase = .closing
        // Dismissal never captures the user's next click in a fading window.
        window.ignoresMouseEvents = true
        visibilityChanged?(false)
        animate(to: 0, request: request) { [weak self] in
            guard let self else { return }
            window.orderOut(nil)
            phase = .closed
            didClose?()
        }
    }

    func hideForOutsideMouseDown(at point: NSPoint, statusItemFrame: NSRect?) {
        // The status button acts on mouse-up. Hiding it on the preceding
        // mouse-down would make that action see a closed panel and reopen it.
        let overStatusItem = statusItemFrame?.contains(point) == true
        PanelTransitionDiagnostics.record("pointerDismissal", ["overStatusItem": overStatusItem])
        guard !overStatusItem else { return }
        hide()
    }

    func stop() {
        generation += 1
        isPresented = false
        phase = .closed
        progress = 0
        window.orderOut(nil)
        window.alphaValue = 0
        visibilityChanged?(false)
    }

    private func animate(to target: CGFloat, request: Int, completion: @escaping @MainActor () -> Void) {
        let duration = usesReducedMotion ? 0.12 : PanelMotion.duration
        withAnimation(usesReducedMotion ? nil : PanelMotion.animation) { progress = target }
        PanelTransitionDiagnostics.record("presentationBegin", ["generation": request,
            "presented": isPresented, "reducedMotion": usesReducedMotion, "duration": duration])
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = PanelMotion.timingFunction
            window.animator().alphaValue = target
        } completionHandler: { [weak self] in
            // AppKit delivers the completion on the main thread.
            MainActor.assumeIsolated {
                guard let self, self.generation == request else { return }
                completion()
                PanelTransitionDiagnostics.record("presentationEnd", ["generation": request,
                    "presented": self.isPresented, "visible": self.window.isVisible, "alpha": self.window.alphaValue])
                PanelTransitionDiagnostics.flushSoon()
            }
        }
    }
}

struct PresentedPanel<Content: View>: View {
    let presentation: PanelPresentation
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(\.panelPresented, presentation.isPresented)
            .environment(\.appearsActive, true)
            .scaleEffect(presentation.usesReducedMotion ? 1 : 0.985 + 0.015 * presentation.progress, anchor: .top)
            .offset(y: presentation.usesReducedMotion ? 0 : -6 * (1 - presentation.progress))
    }
}
