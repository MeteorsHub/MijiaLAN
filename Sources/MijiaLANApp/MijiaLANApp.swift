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
        let test: ReadOnlyAppTest?
        do { test = try ReadOnlyAppTest.prepare(ProcessInfo.processInfo.environment) }
        catch {
            FileHandle.standardError.write(Data("Read-only App test rejected before initialization. Check explicit flags, private single-device seed and new log directory.\n".utf8))
            exit(2)
        }
        let model = AppModel(readOnlyAppTest: test)
        _model = State(initialValue: model)
        delegate.model = model
        if test == nil { DevSnapshot.scheduleIfRequested(model: model) }
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
        if let model {
            menuBar = MenuBarPanelController(model: model)
            if model.isReadOnlyAppTest { model.startReadOnlyAppTest { NSApp.terminate(nil) } }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model?.devices.shutdown()
        model?.curtains.shutdown()
        model?.matter.shutdown()
        lifetime.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model?.isReadOnlyAppTest != true { menuBar?.show() }
        return false
    }
}
