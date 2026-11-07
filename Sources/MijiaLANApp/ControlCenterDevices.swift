import MijiaCore
import MijiaLAN
import SwiftUI

struct ControlCenterDevices: View {
    let model: AppModel
    @Bindable var session: PanelSession
    let openDevice: (String) -> Void
    let openSettings: () -> Void

    var body: some View {
        let online = model.config.devices.filter { model.health[$0.did]?.state == .online }
        let offline = model.config.devices.filter { model.health[$0.did]?.state != .online }
        VStack(alignment: .leading, spacing: 12) {
            if model.config.devices.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "house").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text(L10n.tr("把设备带到控制中心", "Add Your Devices")).font(.headline)
                    Text(L10n.tr("导入米家设备后，即可在这里通过局域网控制。", "Import your Mijia devices to control them here over the LAN."))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(L10n.tr("导入设备", "Import Devices"), action: openSettings).buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else if online.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "wifi.slash").font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("暂时没有在线设备", "No Devices Online")).font(.system(size: 13, weight: .medium))
                        Text(L10n.tr("设备连接后会自动出现在这里", "Devices appear here when they reconnect.")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                    ForEach(online) { device in
                        OnlineDeviceTile(model: model, device: device) { openDevice(device.did) }
                    }
                }
            }
            if !offline.isEmpty {
                HStack(spacing: 4) {
                    Text(offline.allSatisfy { model.health[$0.did]?.state == .unknown } ? L10n.tr("正在检测", "Checking") : L10n.tr("离线设备", "Offline Devices")).fontWeight(.medium)
                    Text("\(offline.count)").foregroundStyle(.tertiary)
                    Spacer()
                    Button(model.retryingDeviceIDs.isEmpty ? L10n.tr("全部重试", "Retry All") : L10n.tr("正在重试…", "Retrying…")) {
                        model.retryDevices(offline.map(\.did))
                    }
                    .buttonStyle(.plain).foregroundStyle(.blue)
                    .disabled(!model.retryingDeviceIDs.isEmpty)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 2)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(offline) { device in
                        OfflineDeviceTile(model: model, device: device, selected: session.selectedOffline == device.did) {
                            session.selectedOffline = session.selectedOffline == device.did ? nil : device.did
                        }
                    }
                }
                if let device = offline.first(where: { $0.did == session.selectedOffline }) {
                    OfflineDeviceCard(model: model, device: device) { openDevice(device.did) }
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 12)
    }
}

private struct OnlineDeviceTile: View {
    let model: AppModel
    let device: LocalDevice
    let open: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var working = false
    @State private var error: String?

    private var snapshot: DeviceSnapshot? { model.devices.snapshots[device.did] }
    private var isOn: Bool { snapshot?.primaryPower.flatMap { snapshot?.value($0.id)?.boolValue } == true }
    private var canToggle: Bool {
        guard let s = snapshot, let power = s.primaryPower else { return false }
        return s.isOnline && power.writable && s.value(power.id)?.boolValue != nil
    }

    var body: some View {
        let palette = ControlCenterPalette(scheme: scheme)
        Button(action: activate) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Circle().fill(isOn ? Color.blue : palette.icon)
                    if working { ProgressView().controlSize(.small) }
                    else { Image(systemName: DevicePresentation.symbol(snapshot)).font(.system(size: 17)) }
                }
                .foregroundStyle(isOn ? .white : .primary).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(DevicePresentation.tileName(device)).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text([device.roomName, model.deviceSummary(device)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        }
        .buttonStyle(ControlCenterButtonStyle(radius: 14))
        .background(palette.tile, in: .rect(cornerRadius: 14))
        .disabled(working)
        .accessibilityLabel("\(DevicePresentation.name(device))，\(model.deviceSummary(device))")
        .accessibilityHint(canToggle ? L10n.tr("按下切换电源", "Press to toggle power.") : L10n.tr("按下查看设备控制", "Press to open device controls."))
        .overlay(alignment: .topTrailing) {
            ControlCenterIconButton(title: L10n.tr("\(DevicePresentation.name(device))详细设置", "\(DevicePresentation.name(device)) details"), symbol: "chevron.right", action: open).padding(5)
        }
        .contextMenu { DeviceContextMenu(model: model, device: device) }
        .alert(L10n.tr("控制未完成", "Control Unsuccessful"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.tr("好", "OK"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func activate() {
        // Cooking devices without a plain power property always open their controls; a tile never starts cooking.
        guard canToggle, let s = snapshot, let power = s.primaryPower, let on = s.value(power.id)?.boolValue else { open(); return }
        working = true
        Task {
            defer { working = false }
            do { try await model.devices.execute(did: device.did, .set(power.id, .bool(!on))) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct OfflineDeviceTile: View {
    let model: AppModel
    let device: LocalDevice
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let issue = ConnectionIssue(health: model.health[device.did] ?? LANDeviceHealth())
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                if model.retryingDeviceIDs.contains(device.did) { ProgressView().controlSize(.mini).frame(width: 18, height: 18) }
                else { Image(systemName: DevicePresentation.symbol(model.devices.snapshots[device.did])).font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 18, height: 18) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(DevicePresentation.tileName(device)).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary).lineLimit(1)
                    Text(device.roomName.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.tr("未分配房间", "No Room Assigned"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .buttonStyle(ControlCenterButtonStyle())
        .background(ControlCenterPalette(scheme: scheme).subtle, in: .rect(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.blue : .clear, lineWidth: 1.5).allowsHitTesting(false) }
        .overlay(alignment: .topTrailing) {
            if issue.needsAttention { Circle().fill(.orange).frame(width: 6, height: 6).padding(9).allowsHitTesting(false) }
        }
        .help([device.name, device.roomName, issue.title].compactMap { $0 }.joined(separator: " · "))
        .accessibilityLabel([DevicePresentation.name(device), device.roomName, issue.title].compactMap { $0 }.joined(separator: "，"))
        .accessibilityHint(selected ? L10n.tr("收起连接详情", "Hide connection details") : L10n.tr("展开连接详情", "Show connection details"))
        .contextMenu { DeviceContextMenu(model: model, device: device) }
    }
}

struct OfflineDeviceCard: View {
    let model: AppModel
    let device: LocalDevice
    var open: (() -> Void)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let health = model.health[device.did] ?? LANDeviceHealth()
        let issue = ConnectionIssue(health: health)
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(DevicePresentation.name(device)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(2)
                Spacer(minLength: 4)
                Text(issue.title).font(.system(size: 11)).fixedSize()
                    .foregroundStyle(issue.needsAttention ? Color.orange : .secondary)
            }
            Text(issue.message).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow { Text(L10n.tr("房间", "Room")); Text(device.roomName ?? L10n.tr("未分配", "Unassigned")) }
                GridRow { Text("IP"); Text(device.host).monospaced().textSelection(.enabled) }
                if let retry = model.devices.retryStates[device.did] {
                    GridRow {
                        Text(L10n.tr("下次自动重试", "Next Automatic Retry"))
                        if retry.isProbing {
                            Text(L10n.tr("正在连接…", "Connecting…"))
                        } else if let deadline = retry.nextRetryAt {
                            Text(deadline, format: .dateTime.month().day().hour().minute().second())
                                .monospacedDigit()
                        } else {
                            Text(L10n.tr("即将重试", "Retrying Shortly"))
                        }
                    }
                }
            }
            if let raw = health.lastError {
                PanelDisclosure(L10n.tr("原始错误", "Original Error"), deviceID: device.did, section: "connectionError") {
                    Text(raw).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(model.retryingDeviceIDs.contains(device.did) ? L10n.tr("连接中…", "Connecting…") : L10n.tr("重试", "Retry"), systemImage: "arrow.clockwise") {
                    model.retryDevices([device.did])
                }
                .disabled(model.retryingDeviceIDs.contains(device.did)).controlSize(.small)
                Spacer()
                if let open { Button(L10n.tr("查看设备", "View Device"), action: open).buttonStyle(.plain).foregroundStyle(.blue) }
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .padding(12).background(ControlCenterPalette(scheme: scheme).subtle, in: .rect(cornerRadius: 10))
    }
}

struct DeviceContextMenu: View {
    let model: AppModel
    let device: LocalDevice
    var body: some View {
        let included = model.isInHomeKit(device)
        Button(included ? L10n.tr("不放进「家庭」", "Remove from Home") : L10n.tr("放进「家庭」", "Show in Home")) { model.setInHomeKit(device, !included) }
            .disabled(!model.homeKitSupports(device))
        Button(L10n.tr("重新连接", "Reconnect"), systemImage: "arrow.clockwise") { model.retryDevices([device.did]) }
    }
}
