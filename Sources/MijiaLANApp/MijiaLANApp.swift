import SwiftUI

@main
@MainActor
struct MijiaLANApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        DevSnapshot.scheduleIfRequested(model: model)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: model.config.devices.isEmpty ? "house" : "homekit")
        }
        .menuBarExtraStyle(.window)
    }
}
