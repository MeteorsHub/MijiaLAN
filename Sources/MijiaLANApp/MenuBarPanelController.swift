import AppKit
import MijiaCore
import Observation
import SwiftUI

@MainActor
final class MenuBarPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let panel: ControlCenterPanel
    private let presentation: PanelPresentation
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pendingShow: Task<Void, Never>?
    private var settledIconFrame: NSRect?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "MijiaLAN.controlCenter"
        panel = ControlCenterPanel(contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: PanelView.maxHeight),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        #if DEBUG
        let reduceOverride = ProcessInfo.processInfo.environment["MIJIALAN_UI_REDUCE_MOTION"].map { $0 == "1" }
        presentation = PanelPresentation(window: panel) { reduceOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        #else
        presentation = PanelPresentation(window: panel)
        #endif
        super.init()
        panel.delegate = self
        panel.title = L10n.tr("米家局域网桥", "MijiaLAN")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.isExcludedFromWindowsMenu = true
        panel.tabbingMode = .disallowed
        let host = NSHostingView(rootView: PresentedPanel(presentation: presentation) {
            #if DEBUG
            PanelView(model: model, reduceMotionOverride: reduceOverride)
                .background(PanelWindowSizing(anchorsToMenuBarIcon: true, anchorsTopToMenuBarIcon: true))
            #else
            PanelView(model: model).background(PanelWindowSizing(anchorsToMenuBarIcon: true, anchorsTopToMenuBarIcon: true))
            #endif
        })
        // The sizing bridge is the only owner of the frame, including animated
        // height changes. Intrinsic-size window updates would compete with it.
        host.sizingOptions = []
        panel.contentView = host
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityLabel(L10n.tr("米家局域网桥", "MijiaLAN"))
        statusItem.button?.toolTip = "MijiaLAN"
        updateIcon()
        presentation.visibilityChanged = { [weak self] visible in
            guard let self else { return }
            statusItem.button?.highlight(visible)
            model.store.setPanelVisible(visible)
            if visible { installEventMonitors() } else { removeEventMonitors() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activeApplicationChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if ProcessInfo.processInfo.environment["MIJIALAN_PANEL_OPEN_ON_LAUNCH"] == "1" {
            DispatchQueue.main.async { [weak self] in self?.show() }
        }
    }

    @objc private func togglePanel() {
        if let pendingShow { pendingShow.cancel(); self.pendingShow = nil; return }
        if presentation.isPresented { presentation.hide() } else { show() }
    }

    func show() {
        guard !presentation.isPresented, pendingShow == nil else { return }
        guard let icon = positionedIconFrame, icon == settledIconFrame else {
            // The status-item window initially has a placeholder frame, even
            // after launch. Keep the panel hidden until AppKit places its icon.
            pendingShow = Task { @MainActor [weak self] in
                var previous: NSRect?
                var stableSamples = 0
                for _ in 0..<60 {
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                    guard let self else { return }
                    let current = positionedIconFrame
                    stableSamples = current != nil && current == previous ? stableSamples + 1 : 0
                    previous = current
                    if stableSamples >= 3 {
                        settledIconFrame = current
                        pendingShow = nil
                        show()
                        return
                    }
                }
                self?.pendingShow = nil
            }
            return
        }
        // Lay out at alpha zero before ordering onscreen. Initial discovery or
        // an appearance change must not expose an oversized first frame.
        panel.contentView?.layoutSubtreeIfNeeded()
        if let button = statusItem.button, let owner = button.window {
            let icon = owner.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            var frame = panel.frame
            frame.origin.x = min(max(icon.midX - frame.width / 2, visible.minX + 8), max(visible.minX + 8, visible.maxX - 8 - frame.width))
            frame.origin.y = icon.minY - 8 - frame.height
            panel.setFrame(frame, display: false)
        }
        presentation.show()
    }

    private var positionedIconFrame: NSRect? {
        guard let button = statusItem.button, let owner = button.window, let screen = owner.screen else { return nil }
        let icon = owner.convertToScreen(button.convert(button.bounds, to: nil))
        guard owner.isVisible && icon.width > 0 && icon.midY >= screen.frame.maxY - 64 else { return nil }
        return icon
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click on our icon is handled by its mouse-up action. Dismissing on
        // mouse-down would turn that same click into an unintended reopen.
        let clickedStatusItem = positionedIconFrame?.contains(NSEvent.mouseLocation) == true
        // A sheet/pop-up can temporarily take key status. Check after AppKit
        // has established its relationship instead of dismissing its parent.
        DispatchQueue.main.async { [weak self] in
            guard let self, !clickedStatusItem, panel.attachedSheet == nil else { return }
            if let key = NSApp.keyWindow, key.parent == panel || key.level.rawValue >= NSWindow.Level.popUpMenu.rawValue { return }
            presentation.hide()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        presentation.hide()
        return false
    }

    @objc private func activeApplicationChanged() {
        if !NSApp.isActive { presentation.hide() }
    }

    @objc private func applicationWillTerminate() {
        pendingShow?.cancel()
        presentation.stop()
        removeEventMonitors()
        NSStatusBar.system.removeStatusItem(statusItem)
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func updateIcon() {
        withObservationTracking {
            let image = NSImage(systemSymbolName: model.config.devices.isEmpty ? "house" : "homekit", accessibilityDescription: nil)
            image?.isTemplate = true
            statusItem.button?.image = image
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    private func installEventMonitors() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                self?.handleLocalEvent(event) ?? false
            }
            return consumed ? nil : event
        }
        // Mouse clicks only; no keyboard/accessibility permission or event data
        // collection is needed to dismiss when the user clicks another app.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentation.hide() }
        }
    }

    private func handleLocalEvent(_ event: NSEvent) -> Bool {
        guard presentation.isPresented, panel.attachedSheet == nil else { return false }
        if event.type == .keyDown {
            if event.keyCode == 53 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w") {
                presentation.hide()
                return true
            }
        } else if event.window != panel, event.window?.parent != panel,
                  event.window != statusItem.button?.window,
                  (event.window?.level.rawValue ?? 0) < NSWindow.Level.popUpMenu.rawValue {
            presentation.hide()
        }
        return false
    }

    private func removeEventMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }
}

private final class ControlCenterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
