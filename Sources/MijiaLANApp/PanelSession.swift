import Observation
import SwiftUI

enum ControlCenterRoute: Hashable {
    case home
    case device(String)
    case settings
    case settingsHomeKit
    case settingsDevices
    case settingsImport
    case settingsManualAdd

    var depth: Int {
        switch self {
        case .home: 0
        case .device, .settings: 1
        default: 2
        }
    }

    var diagnosticName: String {
        switch self {
        case .home: "home"
        case .device: "device"
        case .settings: "settings"
        case .settingsHomeKit: "homekit"
        case .settingsDevices: "devices"
        case .settingsImport: "import"
        case .settingsManualAdd: "manual"
        }
    }
}

/// Only small presentation values survive an idle panel. Never store a view,
/// hosting controller, command writer or closure capturing a view here.
@MainActor @Observable
final class PanelSession {
    var route: ControlCenterRoute
    var selectedOffline: String?
    let manual = PanelManualDraft()
    private var expanded: [String: Set<String>] = [:]
    @ObservationIgnored var layouts: [ControlCenterRoute: PanelPageLayout] = [:]
    // Scroll updates must not invalidate the page or its layout while scrolling.
    @ObservationIgnored var scrollOffsets: [ControlCenterRoute: CGFloat] = [:]
    @ObservationIgnored private var numberDrafts: [String: [String: PanelNumberDraft]] = [:]

    init(route: ControlCenterRoute = .home) { self.route = route }

    func numberDraft(deviceID: String, capabilityID: String) -> PanelNumberDraft {
        if let existing = numberDrafts[deviceID]?[capabilityID] { return existing }
        let draft = PanelNumberDraft()
        numberDrafts[deviceID, default: [:]][capabilityID] = draft
        return draft
    }

    func expansion(deviceID: String, section: String) -> Binding<Bool> {
        Binding(get: { self.expanded[deviceID]?.contains(section) == true }, set: { value in
            if value { self.expanded[deviceID, default: []].insert(section) }
            else { self.expanded[deviceID]?.remove(section) }
        })
    }

    func prune(deviceIDs: Set<String>) {
        let valid: (ControlCenterRoute) -> Bool = {
            if case .device(let id) = $0 { return deviceIDs.contains(id) }
            return true
        }
        layouts = layouts.filter { valid($0.key) }
        scrollOffsets = scrollOffsets.filter { valid($0.key) }
        numberDrafts = numberDrafts.filter { deviceIDs.contains($0.key) }
        expanded = expanded.filter { deviceIDs.contains($0.key) }
        if let selectedOffline, !deviceIDs.contains(selectedOffline) { self.selectedOffline = nil }
        if !valid(route) { route = .home }
    }
}

@MainActor @Observable
final class PanelManualDraft {
    var host = ""
    var token = ""
    var name = ""
    var submitted = false
    var confirmation: String?
}

@MainActor @Observable
final class PanelNumberDraft {
    var text = ""
    var isEditing = false
    var validationError: String?
}

struct PanelPageLayout: Equatable {
    let contentHeight: CGFloat
    let headerHeight: CGFloat
    let footerHeight: CGFloat
    var viewportHeight: CGFloat {
        min(max(contentHeight, 90), max(90, PanelView.maxHeight - headerHeight - footerHeight))
    }
    var totalHeight: CGFloat { headerHeight + viewportHeight + footerHeight }
}

private struct PanelSessionKey: EnvironmentKey {
    static let defaultValue: PanelSession? = nil
}

extension EnvironmentValues {
    var panelSession: PanelSession? {
        get { self[PanelSessionKey.self] }
        set { self[PanelSessionKey.self] = newValue }
    }
}

struct PanelDisclosure<Content: View>: View {
    let title: String
    let deviceID: String
    let section: String
    @ViewBuilder var content: () -> Content
    @State private var localExpanded = false
    @Environment(\.panelSession) private var session

    init(_ title: String, deviceID: String, section: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.deviceID = deviceID; self.section = section; self.content = content
    }

    var body: some View {
        DisclosureGroup(title, isExpanded: session?.expansion(deviceID: deviceID, section: section) ?? $localExpanded,
                        content: content)
    }
}
