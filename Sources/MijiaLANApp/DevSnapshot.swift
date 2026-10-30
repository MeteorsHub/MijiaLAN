import AppKit
import SwiftUI

/// Development aid: `MIJIALAN_SNAPSHOT=<file.png>` renders the panel after `MIJIALAN_SNAPSHOT_DELAY` seconds
/// (default 6), writes it as PNG and, unless `MIJIALAN_SNAPSHOT_EXIT=0`, quits. `MIJIALAN_SNAPSHOT_HIDE=<did>` first
/// keeps that device out of Apple Home through the panel's own path.
@MainActor
enum DevSnapshot {
    static func scheduleIfRequested(model: AppModel, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment["MIJIALAN_SNAPSHOT"] else { return }
        let delay = Double(environment["MIJIALAN_SNAPSHOT_DELAY"] ?? "") ?? 6
        let exits = environment["MIJIALAN_SNAPSHOT_EXIT"] != "0"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if let did = environment["MIJIALAN_SNAPSHOT_HIDE"], let device = model.config.devices.first(where: { $0.did == did }) {
                print("BEFORE exposed=\(model.bridge.exposedDeviceCount)")
                model.setInHomeKit(device, false)
                try? await Task.sleep(for: .seconds(1))
            }
            let renderer = ImageRenderer(content: PanelView(model: model, scrolls: false).background(Color.white))
            renderer.scale = 2
            if let image = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            // The menu-bar window takes the scrolling panel's fitting size; it must not collapse.
            let hosting = NSHostingView(rootView: PanelView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            hosting.layoutSubtreeIfNeeded()
            print("PANEL fitting=\(Int(hosting.fittingSize.width))x\(Int(hosting.fittingSize.height))")
            print("SNAPSHOT \(path) bridge=\(model.bridge.status) exposed=\(model.bridge.exposedDeviceCount) code=\(model.bridge.setupCode ?? "-")")
            if exits { exit(0) }
        }
    }
}
