import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MijiaCore
import MijiaHomeKitBridge
import MijiaLAN
import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel
    /// False for the development snapshot, which renders the whole panel at once.
    var scrolls = true
    @State private var contentHeight: CGFloat = 480

    static let maxHeight: CGFloat = 680

    var body: some View {
        if scrolls {
            // A ScrollView has no height of its own, so the menu-bar window would collapse to nothing; size it to
            // the content and scroll only past `maxHeight`.
            ScrollView {
                content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(width: 400, height: min(max(contentHeight, 1), Self.maxHeight))
            .onAppear { model.store.setPanelVisible(true) }
            .onDisappear { model.store.setPanelVisible(false) }
        } else {
            content.frame(width: 400)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.vaultUnavailable {
                Label("读不到钥匙串，设备清单和配对信息暂时无法保存。重新打开 App 并在弹窗里点「始终允许」。", systemImage: "key.slash")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            DevicesSection(model: model)
            Divider()
            HomeKitSection(model: model, bridge: model.bridge, startsExpanded: !scrolls)
            Divider()
            ImportSection(model: model)
            Divider()
            footer
        }
        .padding(16)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("米家局域网桥").font(.headline)
            Text(model.config.devices.isEmpty
                 ? "还没有设备：先在下方导入"
                 : "\(model.config.devices.count) 台设备 · \(model.onlineCount) 台在线 · 控制只走局域网")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button(model.isRediscovering ? "正在扫描…" : "重新扫描局域网") { model.rediscoverNow() }
                .disabled(model.isRediscovering)
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

// MARK: - Devices

private struct DevicesSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("设备").font(.subheadline.weight(.semibold))
            if model.config.devices.isEmpty {
                Text("导入后，这里会列出可以直接走局域网控制的米家 Wi-Fi 设备。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.config.devices) { device in
                DeviceRow(model: model, device: device)
            }
            if !model.config.skipped.isEmpty {
                DisclosureGroup("\(model.config.skipped.count) 台设备不能走局域网") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.config.skipped) { skipped in
                            Text("\(skipped.name)（\(skipped.model)）：\(skipped.reason)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            if let note = model.lastRediscoveryNote {
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct DeviceRow: View {
    let model: AppModel
    let device: LocalDevice

    var body: some View {
        let health = model.health[device.did] ?? LANDeviceHealth()
        let smart = model.smartDevice(for: device)
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Self.color(for: health.state))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.callout)
                Text([device.roomName, device.host, smart.map(Self.summary)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if health.state != .online, let error = health.lastError {
                    Text(error).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if smart == nil, health.state == .online {
                    Text("这个型号的 MIoT 规格还没读到，或暂不支持").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let smart, smart.isPrimaryToggleable {
                Toggle("", isOn: Binding(get: { smart.isActiveOn }, set: { _ in model.togglePower(device) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(!smart.isOnline)
            }
        }
        .contextMenu {
            let included = model.isInHomeKit(device)
            Button(included ? "不放进「家庭」" : "放进「家庭」") { model.setInHomeKit(device, !included) }
                .disabled(!model.homeKitSupports(device))
            Button("从清单移除") { model.remove(device) }
        }
    }

    static func color(for state: LANDeviceHealth.State) -> Color {
        switch state {
        case .online: return .green
        case .offline: return .gray
        case .tokenRejected: return .orange
        case .unsupported: return .yellow
        case .unknown: return .secondary.opacity(0.4)
        }
    }

    static func summary(_ device: SmartDevice) -> String {
        guard device.isOnline else { return "离线" }
        switch device.kind {
        case .light(let s):
            guard s.isOn else { return "关" }
            return s.brightnessPercent.map { "开 \($0)%" } ?? "开"
        case .plug(let s):
            guard s.isOn else { return "关" }
            return s.powerWatts.map { String(format: "开 %.0f W", $0) } ?? "开"
        case .fan(let s):
            return s.isOn ? "开" : "关"
        case .climate(let s):
            guard s.isOn, s.hvacMode != "off" else { return "关" }
            return "\(s.hvacMode) \(String(format: "%.0f", s.targetTemperature))°"
        case .sensor(let s):
            return [s.temperature.map { String(format: "%.1f°", $0) }, s.humidity.map { String(format: "%.0f%%", $0) }]
                .compactMap { $0 }.joined(separator: " ")
        default:
            return device.isActiveOn ? "开" : ""
        }
    }
}

// MARK: - HomeKit

private struct HomeKitSection: View {
    let model: AppModel
    @Bindable var bridge: HomeKitBridgeController
    var startsExpanded = false
    @State private var confirmingReset = false
    @State private var showingDevices: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("HomeKit").font(.subheadline.weight(.semibold))
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(statusColor)
            }
            Toggle("在 Apple「家庭」里显示这些设备", isOn: $bridge.isEnabled)
                .font(.callout)
            Toggle("桥运行时保持 Mac 不休眠", isOn: $bridge.keepsMacAwake)
                .font(.callout)
            if bridge.isEnabled, !model.config.devices.isEmpty {
                deviceChoices
            }

            if case .running = bridge.status {
                if bridge.isPaired {
                    HStack {
                        Label("已配对，共 \(bridge.exposedDeviceCount) 个配件", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                        Spacer()
                        Button("重置配对") { confirmingReset = true }
                            .controlSize(.small)
                    }
                } else if let uri = bridge.setupURI, let code = bridge.setupCode {
                    pairing(uri: uri, code: code)
                }
            }
            Text("Mac 和 iPhone 要在同一个 Wi-Fi；不在家时远程控制和自动化需要一台家居中枢（HomePod / Apple TV）。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert("重置 HomeKit 配对？", isPresented: $confirmingReset) {
            Button("重置", role: .destructive) { bridge.resetPairing() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("「家庭」App 会把这个桥当成新配件：房间、场景和自动化需要重新设置。")
        }
    }

    private var deviceChoices: some View {
        let included = model.config.devices.filter { model.homeKitSupports($0) && model.isInHomeKit($0) }.count
        let isExpanded = Binding(get: { showingDevices ?? startsExpanded }, set: { showingDevices = $0 })
        return DisclosureGroup("放进「家庭」的设备：\(included) 台", isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.config.devices) { device in
                    HomeKitDeviceToggle(model: model, device: device)
                }
                Text("关掉的设备不会出现在「家庭」里；已经添加过的会被移除，它的房间、场景和自动化也一起删掉。本身已接入 HomeKit 的设备（比如台灯 1S）关掉即可，免得出现两次。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }

    private func pairing(uri: String, code: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let image = QRCode.image(for: uri) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 120, height: 120)
                    .padding(6)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(code)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Text("iPhone「家庭」App → 右上角 + → 添加配件 → 扫这个码。提示「未认证配件」时选「仍然添加」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String {
        switch bridge.status {
        case .stopped: return "已关闭"
        case .waitingForDevices: return model.config.devices.isEmpty ? "等待导入设备" : "等待设备列表…"
        case .starting: return "启动中…"
        case .running(let port): return "运行中 · 端口 \(port)"
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        switch bridge.status {
        case .running: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}

private struct HomeKitDeviceToggle: View {
    let model: AppModel
    let device: LocalDevice

    var body: some View {
        let supported = model.homeKitSupports(device)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.callout)
                if !supported {
                    Text(model.smartDevice(for: device) == nil ? "还没读到设备规格" : "「家庭」没有对应的配件类型")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { supported && model.isInHomeKit(device) }, set: { model.setInHomeKit(device, $0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!supported)
        }
    }
}

// MARK: - Import

private struct ImportSection: View {
    @Bindable var model: AppModel
    @State private var host = ""
    @State private var token = ""
    @State private var name = ""
    @State private var showingManual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("导入设备").font(.subheadline.weight(.semibold))
            Text("米家 Wi-Fi 设备的局域网 token 只能从米家云读出。扫码登录一次，读完 token 和 IP 立刻丢弃登录状态，之后的控制完全走局域网。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch model.importState {
            case .idle, .failed:
                HStack {
                    Picker("服务器", selection: $model.importRegion) {
                        ForEach(Self.regions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Spacer()
                    Button(model.config.devices.isEmpty ? "扫码导入设备" : "重新扫码导入") { model.startCloudImport() }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
                if case .failed(let message) = model.importState {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            case .loadingQR:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在获取小米登录二维码…").font(.caption)
                    Spacer()
                    Button("取消") { model.cancelImport() }.controlSize(.small)
                }
            case .waitingForScan(let ticket, let expiresAt):
                HStack(alignment: .center, spacing: 12) {
                    if let image = QRCode.image(for: ticket.loginURL.absoluteString) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 120, height: 120)
                            .padding(6)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("用手机「米家」App 扫码确认").font(.callout)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("剩余 \(max(0, Int(expiresAt.timeIntervalSince(context.date))))s")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Button("取消") { model.cancelImport() }.controlSize(.small)
                    }
                }
            case .fetching:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在读取设备 token 和局域网 IP…").font(.caption)
                }
            }

            if let summary = model.lastImportSummary {
                Text(summary).font(.caption).foregroundStyle(.green)
            }

            DisclosureGroup("已有 token？手动添加（IP + token）", isExpanded: $showingManual) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("设备 IP，例如 192.168.1.40", text: $host)
                    TextField("32 位 token", text: $token)
                        .font(.system(.body, design: .monospaced))
                    TextField("名称（可空，默认用型号）", text: $name)
                    HStack {
                        if let error = model.manualAddError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                        Spacer()
                        Button(model.isAddingManually ? "正在连接…" : "添加") {
                            model.addManually(host: host, token: token, name: name)
                        }
                        .disabled(model.isAddingManually || host.isEmpty || !MiioToken.isValid(token))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    static let regions: [(String, String)] = [
        ("cn", "中国大陆"), ("de", "欧洲"), ("us", "美国"), ("sg", "新加坡"), ("ru", "俄罗斯"), ("i2", "印度"),
    ]
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
