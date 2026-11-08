import MijiaCore
import MijiaLAN
import SwiftUI

/// Presentation only: shortening a title never renames a device or its Home accessory.
enum DevicePresentation {
    static func name(_ device: LocalDevice) -> String {
        var name = device.name
        if let room = device.roomName, name.hasPrefix(room + "-") { name.removeFirst(room.count + 1) }
        for prefix in ["米家智能", "米家"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? device.name : trimmed
    }

    /// Compact labels for known factory names only. User-given names are retained.
    static func tileName(_ device: LocalDevice) -> String {
        let title = name(device)
        let compact = title.filter { !$0.isWhitespace }
        let factoryNames: [String: (original: String, title: String)] = [
            "zhimi.airpurifier.rma1": ("空气净化器4Lite", L10n.tr("净化器 4 Lite", "Purifier 4 Lite")),
            "chunmi.health_pot.a1": ("多功能养生壶", L10n.tr("养生壶", "Health Kettle")),
            "careli.fryer.maf07c": ("空气炸锅5.5L可视版", L10n.tr("空气炸锅", "Air Fryer")),
            "chunmi.cooker.cmwy3": ("微压IH电饭煲3L", L10n.tr("电饭煲 3L", "Rice Cooker 3L")),
            "dmaker.fan.p28": ("直流变频循环扇落地式", L10n.tr("循环扇", "Circulation Fan"))
        ]
        guard let factory = factoryNames[device.model], compact == factory.original else { return title }
        return factory.title
    }

    static func symbol(_ snapshot: DeviceSnapshot?) -> String {
        switch snapshot?.schema.category {
        case "light": "lamp.desk"
        case "air-conditioner": "air.conditioner.horizontal"
        case "fan": "fan"
        case "air-purifier": "air.purifier"
        case "outlet", "switch": "powerplug"
        case "cooker": "cooktop"
        case "health-pot": "mug"
        case "juicer": "carrot"
        case "air-fryer": "oven"
        default: "square.grid.2x2"
        }
    }

    static func summary(_ snapshot: DeviceSnapshot?) -> String {
        guard let s = snapshot else { return L10n.tr("等待设备信息", "Waiting for Device Information") }
        guard s.isOnline else { return ConnectionIssue(health: s.health, manualOnly: s.device.model == CurtainValidationSession.model).title }
        if s.lanReadingsRestriction != nil { return DeviceLANPolicy.unverifiedReadingsTitle }
        let on = s.primaryPower.flatMap { s.value($0.id)?.boolValue }
        if on == false {
            return L10n.tr("已关闭", "Off")
        }
        if on == true {
            switch s.schema.category {
            case "light":
                return s.value("light", "brightness")?.doubleValue.map { L10n.tr("亮度 \(number($0))%", "Brightness \(number($0))%") } ?? L10n.tr("已开启", "On")
            case "air-conditioner":
                let mode = s.capability("air-conditioner", "mode").map { $0.formatted(s.value($0.id)) } ?? L10n.tr("已开启", "On")
                return [mode, s.value("air-conditioner", "target-temperature")?.doubleValue.map { "\(number($0))°" }].compactMap { $0 }.joined(separator: " ")
            case "fan": return s.value("p:8:1")?.doubleValue.map { L10n.tr("风速 \(number($0)) 级", "Fan speed \(number($0))") } ?? L10n.tr("已开启", "On")
            default: return L10n.tr("已开启", "On")
            }
        }
        if let status = s.capability(s.schema.category, "status") { return status.formatted(s.value(status.id)) }
        return L10n.tr("状态未知", "Unknown State")
    }

    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}

struct ConnectionIssue {
    let title: String
    let message: String
    let needsAttention: Bool

    init(health: LANDeviceHealth, manualOnly: Bool = false) {
        if manualOnly, health.state == .unknown {
            needsAttention = false
            title = L10n.tr("尚未读取", "Not Read Yet")
            message = L10n.tr("卷帘在启动和空闲时保持静默。请打开详情，启用控制偏好后点击手动读取。", "Curtains stay silent during startup and idle. Open details, enable the control preference and read manually.")
            return
        }
        needsAttention = [.tokenRejected, .unsupported].contains(health.state)
        switch health.state {
        case .tokenRejected:
            title = L10n.tr("需要重新导入", "Re-import Required")
            message = L10n.tr("设备有回应，但保存的访问凭据无法通过验证。可在设置中重新导入设备。", "The device responds, but its saved credentials could not be verified. Re-import it in Settings.")
        case .unsupported:
            title = L10n.tr("接口待适配", "Not Supported Yet")
            message = L10n.tr("设备已连接，当前接口还不能通过局域网控制。", "The device is reachable, but this interface cannot be controlled over the LAN yet.")
        case .unknown:
            title = L10n.tr("检测中", "Checking")
            message = L10n.tr("正在检查设备连接，状态会自动更新。", "Checking the connection. Status will update automatically.")
        default:
            if health.lastError?.localizedCaseInsensitiveContains("No route to host") == true ||
                health.lastError?.contains("这个 IP 上没有设备") == true || health.lastError?.contains("No device at this IP") == true {
                title = L10n.tr("无法连接", "Cannot Connect")
                message = L10n.tr("当前网络无法到达这台设备。请检查设备供电、Wi-Fi 和路由器连接。", "This device cannot be reached from the current network. Check its power, Wi-Fi, and router connection.")
            } else {
                title = L10n.tr("无响应", "No Response")
                message = L10n.tr("设备没有回应，可能已离线或 IP 地址改变。可以重试，或重新扫描局域网。", "The device did not respond. It may be offline or have a new IP address. Retry or scan the LAN again.")
            }
        }
    }
}

struct ControlCenterPalette {
    let scheme: ColorScheme
    var panel: Color { scheme == .dark ? Color(red: 0.157, green: 0.157, blue: 0.173) : Color(red: 0.98, green: 0.98, blue: 0.988) }
    var tile: Color { Color.primary.opacity(scheme == .dark ? 0.09 : 0.065) }
    var subtle: Color { Color.primary.opacity(scheme == .dark ? 0.05 : 0.035) }
    var icon: Color { Color.primary.opacity(scheme == .dark ? 0.16 : 0.12) }
}

struct ControlCenterButtonStyle: ButtonStyle {
    var radius: CGFloat = 10
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect(cornerRadius: radius))
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.055 : 0), in: .rect(cornerRadius: radius))
            .onHover { hovered = $0 }
    }
}

struct ControlCenterIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 30, height: 30)
        }
        .buttonStyle(ControlCenterButtonStyle(radius: 7))
        .accessibilityLabel(title).help(title)
    }
}

struct ControlCenterPower: View {
    let controller: DeviceController
    let snapshot: DeviceSnapshot
    @State private var working = false
    @State private var error: String?

    var body: some View {
        if let power = snapshot.primaryPower, power.writable, let actual = snapshot.value(power.id)?.boolValue {
            Toggle(L10n.tr("\(DevicePresentation.name(snapshot.device))电源", "\(DevicePresentation.name(snapshot.device)) power"), isOn: Binding(
                get: { actual },
                set: { value in
                    working = true
                    Task {
                        defer { working = false }
                        do { try await controller.execute(did: snapshot.id, .set(power.id, .bool(value))) }
                        catch { self.error = error.localizedDescription }
                    }
                }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(.blue)
                .disabled(working || !snapshot.isOnline || snapshot.value(power.id)?.boolValue == nil)
                .help(snapshot.value(power.id) == nil ? L10n.tr("电源状态未知", "Power state unknown") : L10n.tr("电源", "Power"))
                .alert(L10n.tr("控制未完成", "Control Unsuccessful"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button(L10n.tr("好", "OK"), role: .cancel) { error = nil }
                } message: { Text(error ?? "") }
        } else if snapshot.primaryPower != nil {
            Text(L10n.tr("未知", "Unknown")).font(.system(size: 11)).foregroundStyle(.secondary).help(L10n.tr("尚未读到电源状态", "Power state is not available yet."))
        }
    }
}
