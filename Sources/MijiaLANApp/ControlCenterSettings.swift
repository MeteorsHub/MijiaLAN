import AppKit
import MijiaCore
import MijiaHomeKitBridge
import MijiaLAN
import SwiftUI

struct ControlCenterSettings: View {
    @Bindable var model: AppModel
    @Bindable var bridge: HomeKitBridgeController
    @Binding var appearance: String
    let navigate: (ControlCenterRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSection(L10n.tr("Apple「家庭」", "Apple Home")) {
                SettingsGroup {
                    SettingsToggleRow(L10n.tr("启用家庭桥接", "Enable Home Bridge"), symbol: "house", isOn: $bridge.isEnabled,
                                      subtitle: HomeKitSettingsStatus(bridge: bridge).text,
                                      statusColor: HomeKitSettingsStatus(bridge: bridge).color)
                    SettingsDivider()
                    SettingsNavigationRow(L10n.tr("管理家庭设备", "Manage Home Devices"), symbol: "gearshape", value: L10n.tr("\(model.selectedHomeKitDeviceCount) 台", "\(model.selectedHomeKitDeviceCount) selected")) {
                        navigate(.settingsHomeKit)
                    }
                }
                SettingsGroup {
                    SettingsToggleRow(L10n.tr("保持 Mac 唤醒", "Keep Mac Awake"), symbol: "moon", isOn: $bridge.keepsMacAwake,
                                      subtitle: L10n.tr("家庭桥接运行时生效", "While the Home bridge is running"))
                }
            }

            Divider()

            SettingsSection(L10n.tr("设备接入", "Device Setup")) {
                SettingsGroup {
                    SettingsNavigationRow(L10n.tr("米家设备", "Mijia Devices"), symbol: "externaldrive", value: L10n.tr("已导入 \(model.config.devices.count) 台", "\(model.config.devices.count) imported")) {
                        navigate(.settingsDevices)
                    }
                    SettingsDivider()
                    HStack(spacing: 10) {
                        SettingsSymbol("server.rack")
                        Text(L10n.tr("服务器", "Server"))
                        Spacer(minLength: 8)
                        Picker(L10n.tr("服务器", "Server"), selection: $model.importRegion) {
                            ForEach(SettingsImportFlow.regions, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .labelsHidden().frame(width: 118).controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    Button {
                        model.startCloudImport()
                        navigate(.settingsImport)
                    } label: {
                        Label(model.config.devices.isEmpty ? L10n.tr("扫码导入设备", "Scan to Import Devices") : L10n.tr("重新扫码导入", "Re-import with QR Code"), systemImage: "viewfinder")
                            .frame(maxWidth: .infinity).padding(.vertical, 3)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    .padding(.horizontal, 10).padding(.bottom, 9)
                    SettingsDivider()
                    SettingsNavigationRow(L10n.tr("手动添加设备", "Add Device Manually"), symbol: "plus.circle") { navigate(.settingsManualAdd) }
                    Text(L10n.tr("扫码读取设备信息，后续控制只走局域网。", "Scan to import. All later control stays on the LAN."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.bottom, 11)
                }
            }

            Divider()

            SettingsSection(L10n.tr("外观", "Appearance")) {
                SettingsGroup {
                    HStack(spacing: 10) {
                        SettingsSymbol("paintpalette")
                        Text(L10n.tr("外观", "Appearance"))
                        Spacer(minLength: 8)
                        Picker(L10n.tr("外观", "Appearance"), selection: $appearance) {
                            Text(L10n.tr("自动", "Auto")).tag("system")
                            Text(L10n.tr("浅色", "Light")).tag("light")
                            Text(L10n.tr("深色", "Dark")).tag("dark")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 166).controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                }
            }

            Divider()
            HStack {
                Label(L10n.tr("仅局域网控制", "LAN Control Only"), systemImage: "lock.fill").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(L10n.tr("退出 MijiaLAN", "Quit MijiaLAN")) { NSApp.terminate(nil) }.controlSize(.small)
            }
            .font(.system(size: 11))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 14)
    }
}

struct SettingsHomeKitManagement: View {
    let model: AppModel
    @Bindable var bridge: HomeKitBridgeController
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(L10n.tr("家庭桥接", "Home Bridge")) {
                SettingsGroup {
                    SettingsToggleRow(L10n.tr("启用家庭桥接", "Enable Home Bridge"), symbol: "house", isOn: $bridge.isEnabled,
                                      subtitle: HomeKitSettingsStatus(bridge: bridge).text,
                                      statusColor: HomeKitSettingsStatus(bridge: bridge).color)
                }
                if case .failed(let message) = bridge.status {
                    Text(message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }

            if case .running = bridge.status, !bridge.isPaired,
               let uri = bridge.setupURI, let code = bridge.setupCode {
                SettingsSection(L10n.tr("添加到「家庭」", "Add to Home")) {
                    SettingsGroup {
                        VStack(spacing: 10) {
                            if let image = QRCode.image(for: uri) {
                                Image(nsImage: image).interpolation(.none).resizable().frame(width: 132, height: 132)
                                    .padding(6).background(.white, in: .rect(cornerRadius: 8))
                            }
                            Text(code).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                            Text(L10n.tr("打开 iPhone「家庭」App，点 + → 添加配件，扫描二维码。", "Open Home on your iPhone, tap + → Add Accessory, then scan this code."))
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Text(L10n.tr("提示「未认证配件」时，选择「仍然添加」。", "If an uncertified accessory warning appears, choose Add Anyway."))
                                .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(14)
                    }
                }
            }

            SettingsSection(L10n.tr("在「家庭」中显示 · \(model.selectedHomeKitDeviceCount) 台", "Shown in Home · \(model.selectedHomeKitDeviceCount)")) {
                if model.config.devices.isEmpty {
                    Text(L10n.tr("请先返回设置导入米家设备。", "Return to Settings to import your Mijia devices first."))
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    SettingsGroup {
                        ForEach(Array(model.config.devices.enumerated()), id: \.element.did) { index, device in
                            if index > 0 { SettingsDivider() }
                            SettingsHomeKitDeviceRow(model: model, device: device)
                        }
                    }
                    Text(L10n.tr("关闭已加入的设备，会同时移除它在「家庭」中的房间、场景和自动化。已原生接入 HomeKit 的设备可关闭，避免重复。", "Turning off an included device also removes its room, scenes, and automations from Home. Turn off devices already connected through native HomeKit to avoid duplicates."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsSection(L10n.tr("连接说明", "Connection Details")) {
                Text(L10n.tr("Mac 和 iPhone 需要连接同一局域网。离家控制和自动化需要家居中枢（HomePod 或 Apple TV）。", "Your Mac and iPhone must be on the same local network. Remote access and automations require a home hub (HomePod or Apple TV)."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if bridge.isPaired {
                Divider()
                Button(L10n.tr("重置 HomeKit 配对…", "Reset HomeKit Pairing…"), role: .destructive) { confirmingReset = true }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 16)
        .alert(L10n.tr("重置 HomeKit 配对？", "Reset HomeKit Pairing?"), isPresented: $confirmingReset) {
            Button(L10n.tr("重置", "Reset"), role: .destructive) { bridge.resetPairing() }
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("「家庭」App 会把这个桥当成新配件：房间、场景和自动化需要重新设置。", "Home will treat this bridge as a new accessory. Rooms, scenes, and automations will need to be set up again."))
        }
    }
}

private struct SettingsHomeKitDeviceRow: View {
    let model: AppModel
    let device: LocalDevice

    private var supported: Bool { model.homeKitSupports(device) }

    var body: some View {
        HStack(spacing: 10) {
            SettingsSymbol(DevicePresentation.symbol(model.devices.snapshots[device.did]))
            VStack(alignment: .leading, spacing: 3) {
                Text(DevicePresentation.name(device)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                if !supported {
                    Text(model.smartDevice(for: device) == nil ? L10n.tr("还没读到设备规格", "Device specifications are not available yet.") : L10n.tr("「家庭」没有对应的配件类型", "No matching accessory type in Home."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let room = device.roomName, !room.isEmpty {
                    Text(room).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Toggle(L10n.tr("在「家庭」中显示\(DevicePresentation.name(device))", "Show \(DevicePresentation.name(device)) in Home"), isOn: Binding(
                get: { supported && model.isInHomeKit(device) },
                set: { model.setInHomeKit(device, $0) }
            ))
            .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!supported)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

struct SettingsDeviceManagement: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(L10n.tr("已导入的设备 · \(model.config.devices.count) 台", "Imported Devices · \(model.config.devices.count)")) {
                Text(L10n.tr("这里包含已导入的在线和离线设备。列入清单不代表所有功能都已适配。", "This list includes imported online and offline devices. Listed devices may have features that are not supported yet."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.config.devices.isEmpty {
                    Text(L10n.tr("暂无设备，返回设置即可扫码或手动添加。", "No devices yet. Return to Settings to scan or add one manually."))
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    SettingsGroup {
                        ForEach(Array(model.config.devices.enumerated()), id: \.element.did) { index, device in
                            if index > 0 { SettingsDivider() }
                            HStack(spacing: 10) {
                                SettingsSymbol(DevicePresentation.symbol(model.devices.snapshots[device.did]))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(DevicePresentation.name(device)).font(.system(size: 13))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text([device.roomName, device.host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer(minLength: 4)
                                Circle().fill(model.health[device.did]?.state == .online ? Color.green : Color.secondary)
                                    .frame(width: 6, height: 6)
                                    .accessibilityLabel(model.health[device.did]?.state == .online ? L10n.tr("在线", "Online") : L10n.tr("未连接", "Disconnected"))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                        }
                    }
                }
            }
            if !model.config.skipped.isEmpty {
                SettingsSection(L10n.tr("未导入的设备 · \(model.config.skipped.count) 台", "Skipped Devices · \(model.config.skipped.count)")) {
                    SettingsGroup {
                        ForEach(Array(model.config.skipped.enumerated()), id: \.element.did) { index, device in
                            if index > 0 { SettingsDivider() }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name).font(.system(size: 13))
                                Text(CapabilityNames.importReason(device.reason)).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                    }
                }
            }
            SettingsSection(L10n.tr("局域网扫描", "LAN Discovery")) {
                HStack {
                    Text(L10n.tr("找回设备的局域网 IP", "Find device IP addresses")).font(.callout)
                    Spacer()
                    Button(model.isRediscovering ? L10n.tr("正在扫描…", "Scanning…") : L10n.tr("重新扫描", "Scan Again")) { model.rediscoverNow() }
                        .controlSize(.small).disabled(model.isRediscovering)
                }
                if let note = model.lastRediscoveryNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.tr("扫描只更新已有设备的地址。添加新设备需要重新扫码导入，或手动填写 IP 和 token。", "Scanning updates addresses for existing devices. To add a new device, re-import with a QR code or enter its IP and token manually."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 16)
    }
}

struct SettingsImportFlow: View {
    let model: AppModel
    let navigate: (ControlCenterRoute) -> Void
    @Environment(\.panelPresented) private var panelPresented

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("使用手机「米家」App 扫码确认", "Scan with the Mijia App"))
                .font(.system(size: 14, weight: .semibold))
            Text(L10n.tr("只读取设备的局域网 token、IP 和房间信息。导入完成后丢弃登录状态，后续控制只走局域网。", "Only the device's LAN token, IP, and room information are read. The login session is discarded after import. All later control stays on the LAN."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingsGroup {
                VStack(spacing: 14) {
                    switch model.importState {
                    case .loadingQR:
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("正在获取登录二维码…", "Getting login QR code…"))
                        cancelButton
                    case .waitingForScan(let ticket, let expiresAt):
                        if let image = QRCode.image(for: ticket.loginURL.absoluteString) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 168, height: 168)
                                .padding(8).background(.white, in: .rect(cornerRadius: 8))
                        }
                        TimelineView(PanelTimelineSchedule(interval: 1, isActive: panelPresented)) { context in
                            Text(L10n.tr("二维码剩余 \(max(0, Int(expiresAt.timeIntervalSince(context.date)))) 秒", "QR code expires in \(max(0, Int(expiresAt.timeIntervalSince(context.date)))) s"))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        cancelButton
                    case .fetching:
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("正在导入设备信息…", "Importing device information…"))
                        cancelButton
                    case .failed(let message):
                        Label(L10n.tr("导入未完成", "Import Unsuccessful"), systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button(L10n.tr("重新获取二维码", "Get a New QR Code")) { model.startCloudImport() }.buttonStyle(.borderedProminent)
                    case .idle:
                        if let summary = model.lastImportSummary {
                            Label(L10n.tr("设备导入完成", "Devices Imported"), systemImage: "checkmark.circle").foregroundStyle(.green)
                            Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button(L10n.tr("查看设备", "View Devices")) { navigate(.settingsDevices) }.buttonStyle(.borderedProminent)
                        } else {
                            Text(L10n.tr("扫码读取米家设备", "Scan to Import Mijia Devices"))
                            Button(L10n.tr("获取二维码", "Get QR Code")) { model.startCloudImport() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                .font(.callout).frame(maxWidth: .infinity).padding(18)
            }
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 16)
    }

    private var cancelButton: some View {
        Button(L10n.tr("取消导入", "Cancel Import")) { navigate(.settings) }.controlSize(.small)
    }

    static let regions: [(String, String)] = [
        ("cn", L10n.tr("中国大陆", "Mainland China")), ("de", L10n.tr("欧洲", "Europe")), ("us", L10n.tr("美国", "United States")), ("sg", L10n.tr("新加坡", "Singapore")), ("ru", L10n.tr("俄罗斯", "Russia")), ("i2", L10n.tr("印度", "India")),
    ]
}

struct SettingsManualDevice: View {
    let model: AppModel
    @Bindable var draft: PanelManualDraft

    private var canAdd: Bool {
        !model.isAddingManually && !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            MiioToken.isValid(draft.token.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("已有设备 token 时，可以直接连接，无需扫码登录。", "If you already have the device token, connect directly without scanning a login code."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingsGroup {
                VStack(alignment: .leading, spacing: 12) {
                    field(L10n.tr("局域网 IP", "Local IP Address")) { TextField(L10n.tr("例如 192.168.1.40", "e.g. 192.168.1.40"), text: $draft.host) }
                    field(L10n.tr("设备 token", "Device Token")) { SecureField(L10n.tr("32 位十六进制 token", "32-character hexadecimal token"), text: $draft.token) }
                    field(L10n.tr("设备名称（选填）", "Device Name (Optional)")) { TextField(L10n.tr("默认使用设备型号", "Defaults to the device model"), text: $draft.name) }
                    Button {
                        addDevice()
                    } label: {
                        Text(model.isAddingManually ? L10n.tr("正在连接…", "Connecting…") : L10n.tr("添加设备", "Add Device")).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).disabled(!canAdd)
                }
                .textFieldStyle(.roundedBorder).controlSize(.regular).padding(14)
                .onSubmit { if canAdd { addDevice() } }
            }
            if draft.submitted, let error = model.manualAddError {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let confirmation = draft.confirmation {
                Label(confirmation, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.tr("设备和 Mac 需要在同一局域网。重新配网可能使旧 token 失效，可重新扫码导入。", "The device and Mac must be on the same LAN. Setting up the device again may invalidate its token; re-import it if needed."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 16)
        .onAppear {
            if draft.submitted, !model.isAddingManually, model.manualAddError == nil { draft.confirmation = model.lastImportSummary }
        }
        .onChange(of: model.isAddingManually) { _, working in
            if draft.submitted, !working, model.manualAddError == nil { draft.confirmation = model.lastImportSummary }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            content().accessibilityLabel(title)
        }
    }

    private func addDevice() {
        draft.submitted = true
        draft.confirmation = nil
        model.addManually(host: draft.host.trimmingCharacters(in: .whitespacesAndNewlines),
                          token: draft.token.trimmingCharacters(in: .whitespacesAndNewlines), name: draft.name)
    }
}

@MainActor
private struct HomeKitSettingsStatus {
    let bridge: HomeKitBridgeController

    var text: String {
        switch bridge.status {
        case .stopped: L10n.tr("已关闭", "Off")
        case .waitingForDevices: L10n.tr("等待设备导入或连接", "Waiting for devices to be imported or connected")
        case .starting: L10n.tr("正在启动…", "Starting…")
        case .running: bridge.isPaired ? L10n.tr("已配对 · \(bridge.exposedDeviceCount) 个配件", "Paired · \(bridge.exposedDeviceCount) \(bridge.exposedDeviceCount == 1 ? "accessory" : "accessories")") : L10n.tr("尚未配对 · 请打开管理家庭设备", "Not paired · Open Manage Home Devices")
        case .failed: L10n.tr("启动失败 · 请打开管理家庭设备", "Could not start · Open Manage Home Devices")
        }
    }

    var color: Color {
        switch bridge.status {
        case .running: .green
        case .failed: .orange
        default: .secondary
        }
    }
}

private extension AppModel {
    var selectedHomeKitDeviceCount: Int {
        config.devices.filter { homeKitSupports($0) && isInHomeKit($0) }.count
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).padding(.leading, 3)
            content
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ControlCenterPalette(scheme: scheme).subtle, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
    }
}

private struct SettingsSymbol: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View {
        Image(systemName: name).font(.system(size: 18)).frame(width: 24).accessibilityHidden(true)
    }
}

private struct SettingsDivider: View {
    var body: some View { Divider().padding(.horizontal, 12) }
}

private struct SettingsToggleRow: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    var subtitle: String?
    var statusColor: Color?

    init(_ title: String, symbol: String, isOn: Binding<Bool>, subtitle: String? = nil, statusColor: Color? = nil) {
        self.title = title; self.symbol = symbol; self._isOn = isOn
        self.subtitle = subtitle; self.statusColor = statusColor
    }

    var body: some View {
        HStack(spacing: 10) {
            SettingsSymbol(symbol)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    HStack(spacing: 5) {
                        if let statusColor { Circle().fill(statusColor).frame(width: 6, height: 6) }
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 4)
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }
}

private struct SettingsNavigationRow: View {
    let title: String
    let symbol: String
    var value: String?
    let action: () -> Void

    init(_ title: String, symbol: String, value: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.value = value; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsSymbol(symbol)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 4)
                if let value { Text(value).font(.system(size: 12)).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(SettingsNavigationButtonStyle())
    }
}

private struct SettingsNavigationButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.07 : hovering ? 0.025 : 0))
                    .padding(.horizontal, 6).padding(.vertical, 3)
            }
            .onHover { hovering = $0 }
    }
}
