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
    private let session = PanelSession()
    private let contentLifetime = PanelContentLifetime()
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
        contentLifetime.load = { [weak self] in self?.loadContent() }
        contentLifetime.unload = { [weak self] in self?.unloadContent() }
        presentation.didClose = { [weak self] in self?.contentLifetime.didHide() }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
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

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let secondaryClick = event?.type == .rightMouseUp || event?.type == .rightMouseDown ||
            (event?.modifierFlags.contains(.control) == true &&
             (event?.type == .leftMouseUp || event?.type == .leftMouseDown))
        PanelTransitionDiagnostics.record("statusItemAction", ["presentedBefore": presentation.isPresented,
            "pendingShow": pendingShow != nil, "secondaryClick": secondaryClick])
        if secondaryClick { showContextMenu(); return }
        if let pendingShow { pendingShow.cancel(); self.pendingShow = nil; return }
        if presentation.isPresented { presentation.hide() } else { show() }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        pendingShow?.cancel()
        pendingShow = nil
        presentation.hide()
        let menu = NSMenu()
        let quit = NSMenuItem(title: L10n.tr("退出 MijiaLAN", "Quit MijiaLAN"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = NSApp
        menu.addItem(quit)
        button.highlight(true)
        defer { button.highlight(presentation.isPresented) }
        PanelTransitionDiagnostics.record("statusMenuOpened", ["items": menu.items.count])
        PanelTransitionDiagnostics.flushSoon()
        let y = button.isFlipped ? button.bounds.maxY : button.bounds.minY
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: y), in: button)
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
                // The icon never got a place: a full menu bar hides it behind the notch, or the menu bar is
                // hidden. Opening the app must still show something, so the panel opens at the menu bar's right end.
                PanelTransitionDiagnostics.record("iconUnplaced", [:])
                self?.pendingShow = nil
                self?.present(below: nil)
            }
            return
        }
        present(below: icon)
    }

    /// Opens the panel under the icon, or under the right end of the main screen's menu bar without one.
    private func present(below icon: NSRect?) {
        guard !presentation.isPresented else { return }
        let started = ProcessInfo.processInfo.systemUptime
        let wasUnloaded = contentLifetime.prepare()
        // Lay out at alpha zero before ordering onscreen. Initial discovery or
        // an appearance change must not expose an oversized first frame.
        panel.contentView?.layoutSubtreeIfNeeded()
        let screen = icon == nil ? NSScreen.main : statusItem.button?.window?.screen
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var frame = panel.frame
        let midX = icon?.midX ?? visible.maxX
        frame.origin.x = min(max(midX - frame.width / 2, visible.minX + 8), max(visible.minX + 8, visible.maxX - 8 - frame.width))
        frame.origin.y = (icon?.minY ?? visible.maxY) - 8 - frame.height
        panel.setFrame(frame, display: false)
        PanelTransitionDiagnostics.record("contentPrepared", ["cold": wasUnloaded,
            "durationMS": (ProcessInfo.processInfo.systemUptime - started) * 1000])
        presentation.show()
    }

    private func loadContent() {
        session.prune(deviceIDs: Set(model.config.devices.map(\.did)))
        let model = model, session = session, presentation = presentation
        let host = NSHostingView(rootView: PresentedPanel(presentation: presentation) {
            #if DEBUG
            PanelView(model: model, reduceMotionOverride: ProcessInfo.processInfo.environment["MIJIALAN_UI_REDUCE_MOTION"].map { $0 == "1" }, session: session)
                .background(PanelWindowSizing(anchorsToMenuBarIcon: true, anchorsTopToMenuBarIcon: true))
            #else
            PanelView(model: model, session: session)
                .background(PanelWindowSizing(anchorsToMenuBarIcon: true, anchorsTopToMenuBarIcon: true))
            #endif
        })
        // Only the sizing bridge owns the frame, including page animations.
        host.sizingOptions = []
        panel.contentView = host
        PanelTransitionDiagnostics.record("contentLoaded", ["route": session.route.diagnosticName,
            "scrollOffset": session.scrollOffsets[session.route] ?? 0])
    }

    private func unloadContent() {
        // Resign the native field editor as well as detaching the SwiftUI tree.
        // The session holds values only; device polling and HAP live in AppModel.
        panel.makeFirstResponder(nil)
        panel.contentView = nil
        PanelTransitionDiagnostics.record("contentUnloaded", ["route": session.route.diagnosticName,
            "scrollOffset": session.scrollOffsets[session.route] ?? 0])
        PanelTransitionDiagnostics.flushSoon()
    }

    private var positionedIconFrame: NSRect? {
        guard let button = statusItem.button, let owner = button.window, let screen = owner.screen else { return nil }
        let icon = owner.convertToScreen(button.convert(button.bounds, to: nil))
        // A full menu bar parks the icons that do not fit off screen; such an icon has no place to open under.
        guard owner.isVisible && icon.width > 0 && icon.midY >= screen.frame.maxY - 64,
              NSScreen.screens.contains(where: { $0.frame.intersects(icon) }) else { return nil }
        return icon
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click on our icon is handled by its mouse-up action. Dismissing on
        // mouse-down would turn that same click into an unintended reopen.
        let clickedStatusItem = (positionedIconFrame ?? settledIconFrame)?.contains(NSEvent.mouseLocation) == true
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
        contentLifetime.stop()
        removeEventMonitors()
        NSStatusBar.system.removeStatusItem(statusItem)
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func updateIcon() {
        session.prune(deviceIDs: Set(model.config.devices.map(\.did)))
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
        // AppKit documents no thread for global events, so hop to the main actor rather than assert it.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.presentation.hideForOutsideMouseDown(at: location,
                    statusItemFrame: self.positionedIconFrame ?? self.settledIconFrame)
            }
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
            presentation.hideForOutsideMouseDown(at: NSEvent.mouseLocation,
                statusItemFrame: positionedIconFrame ?? settledIconFrame)
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
