import Foundation
import MijiaCore
import MijiaLAN
import SwiftUI

struct CurtainControlPanel: View {
    let controller: CurtainControlController
    let device: LocalDevice
    @State private var draft = CurtainPositionDraft()
    @FocusState private var typing: Bool
    private var state: CurtainControlSession.State? { controller.states[device.did] }
    private var enabled: Bool { controller.includes(device.did) }
    private var busy: Bool { controller.isWorking(device.did) }
    private var canMove: Bool { enabled && !busy && (state == nil || state?.phase == .ready) }
    private var target: Int? { draft.target }
    private var stageTitle: String {
        if busy, state == nil || state?.stage == .idle { return L10n.tr("准备读取或控制", "Preparing Read or Control") }
        return switch state?.stage {
        case .requested, .waiting: L10n.tr("准备发送", "Preparing request")
        case .hello: L10n.tr("阶段：握手", "Stage: Handshake")
        case .info: L10n.tr("阶段：身份与固件检查", "Stage: Identity and firmware")
        case .preflight: L10n.tr("阶段：读取 / 写前检查", "Stage: Reading / preflight")
        case .write: L10n.tr("阶段：单次写入", "Stage: Single write")
        case .confirmation: L10n.tr("阶段：操作后有限回读", "Stage: Bounded post-write readback")
        case .finished: L10n.tr("本次请求结束；随统一轮询更新", "Request finished; follows device polling")
        default: L10n.tr("等待统一轮询或手动操作", "Awaiting device polling or a manual action")
        }
    }
    private func commit(_ value: Int) {
        guard canMove, (0...100).contains(value) else { return }
        draft.submitted()
        controller.send(device.did, .position(value))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L10n.tr("启用此卷帘的日常控制", "Enable Daily Control for This Curtain"), isOn: Binding(
                get: { enabled }, set: { controller.setEnabled(device, $0) }))
                .toggleStyle(.switch).controlSize(.small)
            Group {
                HStack {
                    Text(L10n.tr("上次读取位置", "Last Read Position"))
                    Text("C\(controller.events.alias(for: device.did))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(state?.position.map { "\($0)%" } ?? "—").monospacedDigit()
                    if busy { ProgressView().controlSize(.small) }
                }
                Text(stageTitle).font(.caption).foregroundStyle(.secondary)
                if state?.position == nil, let old = state?.lastKnownPosition {
                    Text(L10n.tr("上次有效位置 \(old)%（已过期，不作为当前状态）", "Last valid position \(old)% (stale, not current state)"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let status = state?.motorStatus {
                    Text(status == 1 ? L10n.tr("已停止", "Stopped") : L10n.tr("运动中", "Moving"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let date = state?.sampledAt { Text(date.formatted()).font(.caption).foregroundStyle(.secondary) }
                Slider(value: Binding(get: { draft.slider }, set: { draft.drag($0) }), in: 0...100, step: 1,
                       onEditingChanged: { editing in
                    let value = Int(draft.slider.rounded())
                    draft.setDragging(editing)
                    if !editing { commit(value) }
                })
                .disabled(!canMove)
                .accessibilityLabel(L10n.tr("卷帘目标位置，松手发送", "Curtain target position; release to send"))
                HStack {
                    TextField(L10n.tr("目标位置 %", "Target Position %"), text: Binding(get: { draft.text }, set: { draft.editText($0) }))
                        .textFieldStyle(.roundedBorder).frame(width: 100).focused($typing)
                    Button(L10n.tr("确认位置", "Set Position")) { if let target { commit(target) } }
                        .disabled(!canMove || target == nil || !(0...100).contains(target ?? -1))
                }
                HStack {
                    Button(L10n.tr("全开", "Open")) { draft.discard(); controller.send(device.did, .open) }.disabled(!canMove)
                    Button(L10n.tr("全关", "Close")) { draft.discard(); controller.send(device.did, .close) }.disabled(!canMove)
                    Button(L10n.tr("停止", "Stop")) { draft.discard(); controller.send(device.did, .stop) }
                        .disabled(!enabled || controller.stopping.contains(device.did) || (busy && state?.canStop != true))
                        .keyboardShortcut(".", modifiers: [.command])
                    Spacer()
                }
                if let command = state?.command, !((state?.confirmed) ?? false), let goal = command.target {
                    Text(busy ? L10n.tr("目标 \(goal)% · 本次请求正在确认", "Target \(goal)% · Confirming this request") : L10n.tr("上次目标 \(goal)% · 结果未确认，无自动请求", "Previous target \(goal)% · Unconfirmed; no automatic requests"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(controller.pausedPolling[device.did] == nil ? L10n.tr("手动读取一次", "Read Once") : L10n.tr("手动读取并恢复自动刷新", "Read and Resume Auto Refresh")) { controller.read(device.did) }
                        .disabled(busy)
                }
                if let reason = controller.pollingPauseDescription(device.did) {
                    Text(L10n.tr("自动读取已暂停（\(reason)，重启后仍暂停）；请手动读取通过校验后恢复。", "Auto reads paused (\(reason)), including across restarts. A successful validated manual read resumes polling.")).font(.caption).foregroundStyle(.orange)
                }
                if let message = state?.message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let error = controller.errors[device.did] { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
            Text(L10n.tr("状态默认随前台/后台统一轮询，无需启用控制。每轮只读并校验身份、白名单属性；异常会暂停该台自动读取，需手动恢复。控制需单独启用，写入仅一次并有限回读。0% 全遮住，100% 全拉开。HomeKit/Matter 卷帘控制未开放。", "State follows foreground/background device polling by default, even with controls off. Each turn only reads and validates identity and whitelisted properties. Errors pause that curtain until manual recovery. Controls require opt-in, write once and read back within limits. 0% closed, 100% open. HomeKit/Matter curtain control is disabled."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: typing) { _, value in draft.focus(value) }
        .onChange(of: device.did) { _, _ in
            typing = false
            draft = CurtainPositionDraft()
            draft.receive(state?.position)
        }
        .onChange(of: state?.position, initial: true) { _, position in
            draft.receive(position)
        }
    }
}
