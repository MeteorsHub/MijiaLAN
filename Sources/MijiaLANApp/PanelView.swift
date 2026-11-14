import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MijiaCore
import MijiaHomeKitBridge
import MijiaLAN
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel
    var scrolls = true
    @State private var session: PanelSession
    @State private var panelHeight: CGFloat?
    @State private var generation = 0
    @State private var movesForward = true
    @AppStorage("control_center_appearance") private var appearance = "system"
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.panelPresented) private var panelPresented
    private let reduceMotionOverride: Bool?
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    private var route: ControlCenterRoute { session.route }

    nonisolated static let maxHeight: CGFloat = 660
    nonisolated static let width: CGFloat = 360

    init(model: AppModel, scrolls: Bool = true, initialRoute: ControlCenterRoute = .home,
         reduceMotionOverride: Bool? = nil, session: PanelSession? = nil) {
        self.model = model; self.scrolls = scrolls
        self.reduceMotionOverride = reduceMotionOverride
        let state = session ?? PanelSession(route: initialRoute)
        _session = State(initialValue: state)
        _panelHeight = State(initialValue: state.layouts[state.route]?.totalHeight)
    }

    var body: some View {
        ZStack(alignment: .top) {
            PanelPage(model: model, session: session, route: route, scrolls: scrolls, appearance: $appearance,
                      cachedLayout: session.layouts[route], navigate: navigate, measured: recordLayout)
                .background(ControlCenterPalette(scheme: scheme).panel)
                // Separate identities keep native controls from morphing into
                // controls on the next route while the page layers overlap.
                .id(route)
                .transition(pageTransition)
                .zIndex(Double(generation + 1))
        }
        .frame(width: Self.width, height: scrolls ? panelHeight : nil, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(ControlCenterPalette(scheme: scheme).panel)
        .clipShape(.rect(cornerRadius: 18))
        .containerBackground(ControlCenterPalette(scheme: scheme).panel, for: .window)
        .tint(.blue)
        .environment(\.panelSession, session)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .onAppear { if scrolls { model.store.setPanelVisible(panelPresented) } }
        .onDisappear { if scrolls { model.store.setPanelVisible(false) } }
        .onChange(of: panelPresented) { if scrolls { model.store.setPanelVisible(panelPresented) } }
        .onChange(of: model.config.devices.map(\.did)) {
            let known = Set(model.config.devices.map(\.did))
            session.prune(deviceIDs: known)
        }
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: movesForward ? 20 : -20)),
            removal: .offset(x: movesForward ? -12 : 12)
        )
    }

    private func recordLayout(_ screen: ControlCenterRoute, _ layout: PanelPageLayout) {
        guard scrolls else { return }
        // A disappearing page can still report geometry. Its measurement must
        // never resize the window for a newer destination.
        guard screen == route else { return }
        var immediate = Transaction(animation: nil)
        immediate.disablesAnimations = true
        // The cache is not observable: saving geometry must not invalidate the
        // page stack in the middle of its insertion/removal animation.
        session.layouts[screen] = layout
        let height = layout.totalHeight
        guard panelHeight.map({ abs($0 - height) > 0.5 }) ?? true else { return }
        let animate = panelPresented && panelHeight != nil && !reduceMotion
        PanelTransitionDiagnostics.record("heightTarget", ["route": screen.diagnosticName,
            "generation": generation, "height": height, "animated": animate])
        if animate {
            withAnimation(PanelMotion.animation, completionCriteria: .logicallyComplete) {
                panelHeight = height
            } completion: { PanelTransitionDiagnostics.flushSoon() }
        } else {
            withTransaction(immediate) { panelHeight = height }
            PanelTransitionDiagnostics.flushSoon()
        }
    }

    private func navigate(_ destination: ControlCenterRoute) {
        guard destination != route else { return }
        if route == .settingsImport { model.cancelImport() }
        movesForward = destination.depth >= route.depth
        generation += 1
        let currentGeneration = generation
        PanelTransitionDiagnostics.record("navigationBegin", ["from": route.diagnosticName,
            "to": destination.diagnosticName, "generation": generation,
            "forward": movesForward, "reducedMotion": reduceMotion, "height": panelHeight ?? 0])
        // The cached destination size avoids a temporary default-height page
        // on return. An uncached page measures itself before choosing a height.
        withAnimation(reduceMotion ? nil : PanelMotion.animation,
                      completionCriteria: .logicallyComplete) {
            session.route = destination
            if let known = session.layouts[destination] { panelHeight = known.totalHeight }
        } completion: {
            guard currentGeneration == generation else { return }
            PanelTransitionDiagnostics.record("navigationEnd", ["route": destination.diagnosticName,
                "generation": currentGeneration, "height": panelHeight ?? 0])
            PanelTransitionDiagnostics.flushSoon()
        }
    }
}

/// Each route owns its scroll view and measures its actual content independently.
/// This keeps outgoing geometry, scroll offsets and controls out of the new page.
private struct PanelPage: View {
    @Bindable var model: AppModel
    let session: PanelSession
    let route: ControlCenterRoute
    let scrolls: Bool
    @Binding var appearance: String
    let navigate: (ControlCenterRoute) -> Void
    let measured: (ControlCenterRoute, PanelPageLayout) -> Void
    @State private var contentHeight: CGFloat?
    @State private var headerHeight: CGFloat?
    @State private var footerHeight: CGFloat?
    @Environment(\.panelPresented) private var panelPresented
    private var headerSideWidth: CGFloat { L10n.isEnglish ? 80 : 62 }

    init(model: AppModel, session: PanelSession, route: ControlCenterRoute, scrolls: Bool, appearance: Binding<String>,
         cachedLayout: PanelPageLayout?, navigate: @escaping (ControlCenterRoute) -> Void,
         measured: @escaping (ControlCenterRoute, PanelPageLayout) -> Void) {
        self.model = model; self.session = session; self.route = route; self.scrolls = scrolls
        self._appearance = appearance; self.navigate = navigate; self.measured = measured
        _contentHeight = State(initialValue: cachedLayout?.contentHeight)
        _headerHeight = State(initialValue: cachedLayout?.headerHeight)
        _footerHeight = State(initialValue: cachedLayout?.footerHeight)
    }

    private var layout: PanelPageLayout? {
        guard let contentHeight, let headerHeight else { return nil }
        if route == .home, footerHeight == nil { return nil }
        return PanelPageLayout(contentHeight: contentHeight, headerHeight: headerHeight,
                               footerHeight: route == .home ? (footerHeight ?? 0) : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            header.onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { headerHeight = $0 }
            if scrolls {
                ScrollView {
                    page.frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { contentHeight = $0 }
                        .background(PanelScrollState(session: session, route: route, isPresented: panelPresented))
                }
                .frame(height: layout?.viewportHeight ?? 360)
                .scrollIndicators(.automatic)
            } else { page }
            if route == .home {
                footer.onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { footerHeight = $0 }
            }
        }
        .frame(width: PanelView.width)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: layout, initial: true) { _, value in
            if let value { measured(route, value) }
        }
    }

    @ViewBuilder private var header: some View {
        switch route {
        case .home:
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("米家局域网桥", "MijiaLAN")).font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 6) {
                        Circle().fill(model.onlineCount > 0 ? Color.green : .secondary).frame(width: 7, height: 7)
                        Text(model.isRediscovering ? L10n.tr("正在扫描局域网…", "Scanning the LAN…") : L10n.tr("\(model.onlineCount) 台在线 · 共 \(model.config.devices.count) 台", "\(model.onlineCount) online · \(model.config.devices.count) total"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    if model.isRediscovering { ProgressView().controlSize(.small).frame(width: 30, height: 30) }
                    else { ControlCenterIconButton(title: L10n.tr("重新扫描局域网", "Scan the LAN Again"), symbol: "arrow.clockwise") { model.rediscoverNow() } }
                    ControlCenterIconButton(title: L10n.tr("设置", "Settings"), symbol: "gearshape") { navigate(.settings) }
                }
            }
            .padding(.leading, 16).padding(.trailing, 12).padding(.top, 14).padding(.bottom, 12)
        case .device(let did):
            detailHeader(title: model.config.devices.first(where: { $0.did == did }).map(DevicePresentation.name) ?? L10n.tr("设备", "Devices")) {
                if let snapshot = model.devices.snapshots[did] { ControlCenterPower(controller: model.devices, snapshot: snapshot) }
            }
        case .settings:
            detailHeader(title: L10n.tr("设置", "Settings")) { EmptyView() }
        case .settingsMatter:
            detailHeader(title: L10n.tr("Matter 桥接", "Matter Bridge"), backTitle: L10n.tr("设置", "Settings"), backRoute: .settings) { EmptyView() }
        case .settingsHomeKit:
            detailHeader(title: L10n.tr("管理家庭设备", "Manage Home Devices"), backTitle: L10n.tr("设置", "Settings"), backRoute: .settings) { EmptyView() }
        case .settingsDevices:
            detailHeader(title: L10n.tr("米家设备", "Mijia Devices"), backTitle: L10n.tr("设置", "Settings"), backRoute: .settings) { EmptyView() }
        case .settingsImport:
            detailHeader(title: L10n.tr("扫码导入", "QR Import"), backTitle: L10n.tr("设置", "Settings"), backRoute: .settings) { EmptyView() }
        case .settingsDiagnostics:
            detailHeader(title: L10n.tr("诊断日志", "Diagnostic Logs"), backTitle: L10n.tr("设置", "Settings"), backRoute: .settings) { EmptyView() }
        case .settingsManualAdd:
            detailHeader(title: L10n.tr("手动添加设备", "Add Device Manually"), backTitle: L10n.tr("设置", "Settings"), backRoute: .settings) { EmptyView() }
        }
    }

    private func detailHeader<Trailing: View>(title: String, backTitle: String = L10n.tr("设备", "Devices"), backRoute: ControlCenterRoute = .home,
                                             @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 4) {
            Button { navigate(backRoute) } label: {
                Label(backTitle, systemImage: "chevron.left").font(.system(size: 13)).foregroundStyle(.blue)
                    .lineLimit(1).padding(.vertical, 8)
            }
            .buttonStyle(.plain).frame(width: headerSideWidth, alignment: .leading).keyboardShortcut(.leftArrow, modifiers: .command)
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1).help(title)
                .frame(maxWidth: .infinity)
            ZStack { trailing() }.frame(width: headerSideWidth, height: 30, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
    }

    @ViewBuilder private var page: some View {
        switch route {
        case .home:
            VStack(spacing: 0) {
                if model.vaultUnavailable {
                    Label(L10n.tr("钥匙串暂时无法访问，请重新打开 App 并允许访问。", "Keychain access is unavailable. Reopen the app and allow access."), systemImage: "key.slash")
                        .font(.caption).foregroundStyle(.orange).padding(12)
                }
                ControlCenterDevices(model: model, session: session, openDevice: { navigate(.device($0)) }, openSettings: { navigate(.settings) })
            }
        case .device(let did):
            if let device = model.config.devices.first(where: { $0.did == did }) {
                ControlCenterDeviceDetail(model: model, device: device).id(did)
            }
        case .settings:
            ControlCenterSettings(model: model, bridge: model.bridge, appearance: $appearance, navigate: navigate)
        case .settingsMatter:
            SettingsMatterManagement(model: model, bridge: model.matter, openSettings: { navigate(.settings) })
        case .settingsHomeKit:
            SettingsHomeKitManagement(model: model, bridge: model.bridge)
        case .settingsDevices:
            SettingsDeviceManagement(model: model)
        case .settingsImport:
            SettingsImportFlow(model: model, navigate: navigate)
        case .settingsDiagnostics:
            SettingsDiagnostics(journal: model.curtains.events, cachedHomeKitSummary: {
                let snapshots = Array(model.devices.snapshots.values)
                let aliases = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, model.curtains.events.alias(for: $0.id)) })
                return CachedHomeKitDiagnostics.data(snapshots: snapshots, failures: model.bridge.readFailures, aliases: aliases)
            })
        case .settingsManualAdd:
            SettingsManualDevice(model: model, draft: session.manual)
        }
    }

    private var footer: some View {
        HStack {
            Label(L10n.tr("控制只走局域网", "LAN Control Only"), systemImage: "lock").font(.system(size: 11))
            Spacer()
            TimelineView(PanelTimelineSchedule(interval: 30, isActive: panelPresented)) { context in
                Text(model.lastRediscoveryAt.map { context.date.timeIntervalSince($0) < 60 ? L10n.tr("上次扫描 刚刚", "Scanned just now") : L10n.tr("扫描 ", "Scanned ") + $0.formatted(.relative(presentation: .named)) } ?? L10n.tr("尚未扫描", "Not Scanned Yet"))
                    .font(.system(size: 11))
            }
        }
        .foregroundStyle(.secondary).padding(.vertical, 9).padding(.horizontal, 16)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
    }

}

/// Retains TimelineView's content identity while removing all future display ticks when the panel is hidden.
struct PanelTimelineSchedule: TimelineSchedule {
    var interval: TimeInterval
    var isActive: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard isActive else { return AnySequence([startDate]) }
        return AnySequence(PeriodicTimelineSchedule(from: startDate, by: interval).entries(from: startDate, mode: mode))
    }
}

enum QRCode {
    static func image(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
