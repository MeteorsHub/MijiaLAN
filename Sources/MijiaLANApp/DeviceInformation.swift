import MijiaCore
import MijiaLAN
import SwiftUI

struct DeviceInformation: View {
    let snapshot: DeviceSnapshot
    var curtainState: CurtainControlSession.State? = nil
    var usesCurtainControl = false

    var body: some View {
        PanelDisclosure(L10n.tr("设备信息", "Device Information"), deviceID: snapshot.id, section: "information") {
            VStack(alignment: .leading, spacing: 10) {
                infoRow(L10n.tr("名称", "Name"), value: snapshot.device.name)
                if let room = snapshot.device.roomName { infoRow(L10n.tr("房间", "Room"), value: room) }
                infoRow(L10n.tr("IP 地址", "IP Address"), value: snapshot.device.host)
                infoRow(L10n.tr("型号", "Model"), value: snapshot.device.model)
                infoRow(L10n.tr("连通性", "Connectivity"), value: snapshot.isOnline
                    ? L10n.tr("在线（设备信息可达）", "Online (device info reachable)") : ConnectionIssue(health: snapshot.health).title)
                if snapshot.lanReadingsRestriction != nil {
                    if !usesCurtainControl {
                        infoRow(L10n.tr("局域网读数", "LAN Readings"), value: DeviceLANPolicy.unverifiedReadingsTitle)
                    }
                    infoRow(L10n.tr("最近信息响应", "Last Info Response"), value: snapshot.health.lastSeen?.formatted() ?? L10n.tr("尚未确认", "Not Confirmed"))
                }
                Divider()
                Text(L10n.tr("当前读数", "Current Readings")).fontWeight(.medium)
                if usesCurtainControl {
                    infoRow(L10n.tr("实际位置", "Actual Position"), value: curtainState?.position.map { "\($0)%" } ?? L10n.tr("尚未确认", "Not Confirmed"))
                    infoRow(L10n.tr("工作状态", "Motor State"), value: curtainState?.motorStatus.map {
                        $0 == 1 ? L10n.tr("已停止", "Stopped") : L10n.tr("运动中", "Moving")
                    } ?? L10n.tr("尚未确认", "Not Confirmed"))
                } else {
                    ForEach(snapshot.capabilities.filter(\.readable)) { capability in
                        infoRow(capability.title, value: snapshot.lanReadingsRestriction ?? snapshot.readings[capability.id]?.error ?? capability.formatted(snapshot.value(capability.id)))
                            .help("\(capability.siid).\(capability.iid) · \(capability.service) · \(snapshot.readings[capability.id]?.updatedAt?.formatted() ?? L10n.tr("尚未读取", "Not Read Yet"))")
                    }
                }
                let limited = snapshot.capabilities.filter { $0.limitation != nil }
                if !usesCurtainControl && !limited.isEmpty {
                    Divider()
                    PanelDisclosure(L10n.tr("兼容性说明", "Compatibility"), deviceID: snapshot.id, section: "compatibility") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.tr("以下为当前版本的功能支持情况，无需手动确认。", "Feature support in this version is listed below. No manual confirmation is needed."))
                                .foregroundStyle(.secondary)
                            ForEach(limited) { capability in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(title(for: capability))
                                    Text(explanation(for: capability)).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help("\(capability.id) · \(capability.title)\n\(CapabilityNames.limitation(capability.limitation ?? ""))")
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                    }
                }
            }
            .font(.caption).padding(.top, 8)
        }
        .font(.system(size: 12))
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(for capability: DeviceCapability) -> String {
        switch capability.name {
        case "toggle": return L10n.tr("切换开关状态", "Toggle Power")
        case "brightness-delta": return L10n.tr("增减亮度", "Adjust Brightness")
        case "ct-delta": return L10n.tr("增减色温", "Adjust Color Temperature")
        case "ct-adjust-alexa": return L10n.tr("Alexa 色温调节", "Alexa Color Temperature")
        case "mode" where capability.service == "light": return L10n.tr("灯光场景", "Light Scene")
        default: return capability.title
        }
    }

    private func explanation(for capability: DeviceCapability) -> String {
        switch capability.name {
        case "toggle" where snapshot.primaryPower?.writable == true:
            return L10n.tr("请使用顶部的电源开关", "Use the power switch at the top.")
        case "brightness-delta" where snapshot.capability("light", "brightness")?.writable == true:
            return L10n.tr("请使用亮度滑条", "Use the brightness slider.")
        case "ct-delta" where snapshot.capability("light", "color-temperature")?.writable == true,
             "ct-adjust-alexa" where snapshot.capability("light", "color-temperature")?.writable == true:
            return L10n.tr("请使用色温滑条或数值输入", "Use the color temperature slider or numeric input.")
        default:
            switch capability.limitation {
            case "规格存在，尚无经过确认的旧 miIO 映射": return L10n.tr("当前版本暂未适配局域网控制", "LAN control is not supported in this version yet.")
            case "维护操作或厂商复合参数，不作为日常控制": return L10n.tr("此操作未在 App 中开放", "This operation is not available in the app.")
            case "复合循环计划尚未确认，暂不启用或修改": return L10n.tr("当前版本暂不支持设置循环计划", "Cycle schedules are not supported in this version yet.")
            case "厂商参数或停止语义尚未确认，暂不写入": return L10n.tr("当前版本暂不支持设置此功能", "This setting is not supported in this version yet.")
            case "缺少可验证的参数定义，暂不写入": return L10n.tr("暂不支持设置，设备未提供完整的参数说明", "This setting is unavailable because the device does not provide a complete parameter definition.")
            default: return L10n.tr("当前版本暂不支持此功能", "This feature is not supported in this version yet.")
            }
        }
    }
}

struct DeviceCommandFeedback: View {
    let snapshot: DeviceSnapshot
    @State private var showsConfirmation = false

    var body: some View {
        Group {
            if snapshot.lastCommand == "已选择下次参数，尚未启动" {
                Text(L10n.tr("已选择下次菜单参数，尚未开始烹饪", "Next menu settings selected. Cooking has not started."))
            } else if let receipt = snapshot.commandReceipt, receipt.error == nil {
                if receipt.confirmedAt != nil {
                    if showsConfirmation {
                        Label(confirmation(for: receipt), systemImage: "checkmark.circle")
                    }
                } else if receipt.acceptedAt == nil {
                    Text(L10n.tr("正在发送…", "Sending…"))
                } else if snapshot.capabilities.first(where: { $0.id == receipt.capabilityID }).map({ $0.kind == .property && !$0.readable }) == true {
                    Text(L10n.tr("指令已接受，设备未提供完成状态", "Command accepted. The device does not report completion."))
                } else {
                    Text(L10n.tr("设备已接受指令，正在确认状态…", "Command accepted. Confirming device state…"))
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .task(id: snapshot.commandReceipt) {
            showsConfirmation = false
            guard let confirmedAt = snapshot.commandReceipt?.confirmedAt else { return }
            let remaining = 5 - Date.now.timeIntervalSince(confirmedAt)
            guard remaining > 0 else { return }
            showsConfirmation = true
            do { try await Task.sleep(for: .seconds(remaining)) }
            catch { return }
            showsConfirmation = false
        }
    }

    private func confirmation(for receipt: DeviceCommandReceipt) -> String {
        guard let capability = snapshot.capabilities.first(where: { $0.id == receipt.capabilityID }) else { return L10n.tr("操作已完成", "Completed") }
        if capability.name == "on", let on = snapshot.value(capability.id)?.boolValue {
            return on ? L10n.tr("已开启", "On") : L10n.tr("已关闭", "Off")
        }
        if capability.kind == .action { return L10n.tr("设备状态已确认", "Device State Confirmed") }
        return L10n.tr("\(capability.title)已设为 \(capability.formatted(snapshot.value(capability.id)))", "\(capability.title) set to \(capability.formatted(snapshot.value(capability.id)))")
    }
}
