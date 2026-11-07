import Foundation
import MijiaCore
import MijiaLAN
import SwiftUI

struct CurtainControlPanel: View {
    let controller: CurtainControlController
    let device: LocalDevice
    @State private var draft = 0.0
    @State private var targetText = ""
    @State private var dragging = false
    @FocusState private var typing: Bool
    private var state: CurtainControlSession.State? { controller.states[device.did] }
    private var enabled: Bool { controller.includes(device.did) }
    private var busy: Bool { controller.isWorking(device.did) }
    private var canMove: Bool { enabled && !busy && state?.phase == .ready && state?.position != nil }
    private var target: Int? { Int(targetText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private func commit(_ value: Int) {
        guard canMove, (0...100).contains(value) else { return }
        controller.send(device.did, .position(value))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L10n.tr("启用此卷帘的日常控制", "Enable Daily Control for This Curtain"), isOn: Binding(
                get: { enabled }, set: { controller.setEnabled(device, $0) }))
                .toggleStyle(.switch).controlSize(.small)
            if enabled {
                HStack {
                    Text(L10n.tr("实际位置", "Actual Position"))
                    Spacer()
                    Text(state?.position.map { "\($0)%" } ?? "—").monospacedDigit()
                    if busy { ProgressView().controlSize(.small) }
                }
                if let status = state?.motorStatus {
                    Text(status == 1 ? L10n.tr("已停止", "Stopped") : L10n.tr("运动中", "Moving"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let date = state?.sampledAt { Text(date.formatted()).font(.caption).foregroundStyle(.secondary) }
                Slider(value: Binding(get: { draft }, set: { draft = $0; targetText = String(Int($0.rounded())) }), in: 0...100, step: 1,
                       onEditingChanged: { editing in
                    dragging = editing
                    if !editing { commit(Int(draft.rounded())) }
                })
                .disabled(!canMove)
                .accessibilityLabel(L10n.tr("卷帘目标位置，松手发送", "Curtain target position; release to send"))
                HStack {
                    TextField(L10n.tr("目标位置 %", "Target Position %"), text: $targetText)
                        .textFieldStyle(.roundedBorder).frame(width: 100).focused($typing)
                    Button(L10n.tr("确认位置", "Set Position")) { if let target { commit(target) } }
                        .disabled(!canMove || target == nil || !(0...100).contains(target ?? -1))
                }
                HStack {
                    Button(L10n.tr("全开", "Open")) { controller.send(device.did, .open) }.disabled(!canMove)
                    Button(L10n.tr("全关", "Close")) { controller.send(device.did, .close) }.disabled(!canMove)
                    Button(L10n.tr("停止", "Stop")) { controller.send(device.did, .stop) }
                        .disabled(state?.canStop != true || controller.stopping.contains(device.did))
                        .keyboardShortcut(".", modifiers: [.command])
                    Spacer()
                }
                if let command = state?.command, !((state?.confirmed) ?? false), let goal = command.target {
                    Text(L10n.tr("目标 \(goal)% · 等待实际位置确认", "Target \(goal)% · Awaiting actual position"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L10n.tr("仅回读确认", "Read to Confirm")) { controller.read(device.did) }
                        .disabled(busy || state?.canStop != true)
                    Button(L10n.tr("重新连接", "Reconnect")) { controller.reconnect(device) }
                        .disabled(busy)
                }
                if let message = state?.message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let error = controller.errors[device.did] { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
            Text(L10n.tr("选择会保存，重启后自动读取状态。0% 全遮住，100% 全拉开。拖动只预览，松手或确认后发送一次；停止优先发送。HomeKit/Matter 卷帘控制尚未开放。", "Your selection is saved; startup reads state only. 0% closed, 100% open. Drag to preview, release or confirm to send once; Stop has priority. HomeKit/Matter curtain control is not enabled."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: state?.position, initial: true) { _, position in
            if !dragging, !typing, let position { draft = Double(position); targetText = String(position) }
        }
    }
}
