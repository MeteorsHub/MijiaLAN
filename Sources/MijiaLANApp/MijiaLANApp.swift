import AppKit
import Logging
import MijiaLAN
import SwiftUI

@main
@MainActor
struct MijiaLANApp: App {
    @NSApplicationDelegateAdaptor(MijiaLANApplicationDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        LANLocalization.configure()
        // Before anything creates a hap-swift logger.
        LoggingSystem.bootstrap(UnifiedLogHandler.init)
        let model = AppModel()
        _model = State(initialValue: model)
        delegate.model = model
        DevSnapshot.scheduleIfRequested(model: model)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands { CommandGroup(replacing: .appSettings) { EmptyView() } }
    }
}

@MainActor
final class MijiaLANApplicationDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var menuBar: MenuBarPanelController?
    private let lifetime = BackgroundApplicationLifetime()

    func applicationWillFinishLaunching(_ notification: Notification) {
        lifetime.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        lifetime.start()
        if let model { menuBar = MenuBarPanelController(model: model) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model?.curtainValidation.disable()
        model?.matter.shutdown()
        lifetime.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.show()
        return false
    }
}
