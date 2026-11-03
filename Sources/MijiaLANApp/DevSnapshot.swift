import AppKit
import SwiftUI
import MijiaLAN
import MijiaCore

/// Development aid: `MIJIALAN_SNAPSHOT=<file.png>` renders the panel after `MIJIALAN_SNAPSHOT_DELAY` seconds
/// (default 6), writes it as PNG and, unless `MIJIALAN_SNAPSHOT_EXIT=0`, quits. `MIJIALAN_SNAPSHOT_HIDE=<did>` first
/// keeps that device out of Apple Home through the panel's own path. `MIJIALAN_SNAPSHOT_WINDOW=<seconds>` also shows
/// the expanded panel in a real window for that long and prints its window number, for `screencapture -l`:
/// `ImageRenderer` draws no AppKit controls.
@MainActor
enum DevSnapshot {
    private static let diagnosticWriter = DiagnosticFileWriter()
    static func scheduleIfRequested(model: AppModel, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let path = environment["MIJIALAN_DIAGNOSTICS_OUTPUT"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(12))
                await model.devices.refreshNow()
                // Explicit allow-list: never serialize LocalDevice, tokens, pairing keys or setup codes.
                let rows: [[String: Any]] = model.devices.snapshots.values.sorted { $0.id < $1.id }.map { s in
                    var row: [String: Any] = ["did": s.id, "model": s.device.model, "name": s.device.name, "health": String(describing: s.health.state),
                     "homeIncluded": model.isInHomeKit(s.device),
                     "readings": s.capabilities.filter(\.readable).map { c -> [String: Any] in
                         var entry: [String: Any] = ["id": c.id, "name": c.title]
                         if let reading = s.readings[c.id] {
                             entry["value"] = reading.value?.compactJSONString
                             entry["code"] = reading.code
                             entry["error"] = reading.error
                             entry["updatedAt"] = reading.updatedAt?.ISO8601Format()
                         }
                         return entry
                     }]
                    if let retry = model.devices.retryStates[s.id] {
                        row["retryFailures"] = retry.consecutiveFailures
                        row["nextRetryAt"] = retry.nextRetryAt?.ISO8601Format()
                        row["isProbing"] = retry.isProbing
                    }
                    return row
                }
                let output: [String: Any] = ["recordedAt": Date().ISO8601Format(), "bridge": String(describing: model.bridge.status),
                    "accessories": model.bridge.exposedDeviceCount, "paired": model.bridge.isPaired,
                    "keepsMacAwake": model.bridge.keepsMacAwake,
                    "structureRevision": model.devices.structureRevision, "valuesRevision": model.devices.valuesRevision,
                    "devices": rows]
                if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
                    diagnosticWriter.submit(data, to: URL(fileURLWithPath: path))
                }
            }
        }
        guard let path = environment["MIJIALAN_SNAPSHOT"] else { return }
        let delay = Double(environment["MIJIALAN_SNAPSHOT_DELAY"] ?? "") ?? 6
        let exits = environment["MIJIALAN_SNAPSHOT_EXIT"] != "0"
        let route: ControlCenterRoute = environment["MIJIALAN_UI_PAGE"].map {
            switch $0 {
            case "settings": .settings
            case "settings-homekit": .settingsHomeKit
            case "settings-devices": .settingsDevices
            case "settings-import": .settingsImport
            case "settings-manual": .settingsManualAdd
            default: .device($0)
            }
        } ?? .home
        if let theme = environment["MIJIALAN_UI_THEME"] {
            UserDefaults.standard.set(theme, forKey: "control_center_appearance")
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if let did = environment["MIJIALAN_SNAPSHOT_HIDE"], let device = model.config.devices.first(where: { $0.did == did }) {
                print("BEFORE exposed=\(model.bridge.exposedDeviceCount)")
                model.setInHomeKit(device, false)
                try? await Task.sleep(for: .seconds(1))
            }
            let renderer = ImageRenderer(content: PanelView(model: model, scrolls: false, initialRoute: route))
            renderer.scale = 2
            if let image = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            // The menu-bar window takes the scrolling panel's fitting size; it must not collapse.
            let hosting = NSHostingView(rootView: PanelView(model: model).background(PanelWindowSizing()))
            // Start oversized, like the reported production failure; the shared
            // sizing bridge must shrink both this host and the real MenuBarExtra.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: PanelView.width, height: PanelView.maxHeight), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            hosting.layoutSubtreeIfNeeded()
            print("PANEL fitting=\(Int(hosting.fittingSize.width))x\(Int(hosting.fittingSize.height))")
            print("HOST content=\(Int(hosting.bounds.width))x\(Int(hosting.bounds.height))")
            print("SNAPSHOT \(path) bridge=\(model.bridge.status) exposed=\(model.bridge.exposedDeviceCount)")
            if let seconds = Double(environment["MIJIALAN_SNAPSHOT_WINDOW"] ?? "") {
                let visible = NSWindow(contentRect: NSRect(x: 80, y: 80, width: PanelView.width, height: PanelView.maxHeight),
                                       styleMask: [.titled, .closable], backing: .buffered, defer: false)
                let shown = NSHostingView(rootView: PanelView(model: model, initialRoute: route,
                    reduceMotionOverride: environment["MIJIALAN_UI_REDUCE_MOTION"].map { $0 == "1" })
                    .environment(\.appearsActive, true)
                    .background(PanelWindowSizing()))
                visible.title = L10n.tr("MijiaLAN · 原生预览", "MijiaLAN · Native Preview")
                visible.isReleasedWhenClosed = false
                visible.contentView = shown
                visible.makeKeyAndOrderFront(nil)
                NSApp.activate()
                try? await Task.sleep(for: .milliseconds(300))
                print("WINDOW \(visible.windowNumber)")
                if let path = environment["MIJIALAN_NATIVE_SNAPSHOT"],
                   let bitmap = shown.bitmapImageRepForCachingDisplay(in: shown.bounds) {
                    shown.cacheDisplay(in: shown.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                fflush(stdout)
                try? await Task.sleep(for: .seconds(seconds))
            }
            if exits { exit(0) }
        }
    }
}
