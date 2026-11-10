import Foundation
import MijiaCore
import MijiaLAN
import SwiftUI

struct CurtainControlPanel: View {
    let controller: CurtainControlController
    let device: LocalDevice
    @State private var draft = CurtainPositionDraft()
    @State private var editorID = UUID()
    @FocusState private var typing: Bool
    private var state: CurtainControlSession.State? { controller.states[device.did] }
    private var busy: Bool { controller.isWorking(device.did) }
    // A poll (including its failure) must never disable a native slider halfway through its gesture.
    private var canMove: Bool { draft.dragging || !busy }
    private var target: Int? { draft.target }
    private var stageTitle: String {
        if controller.submissions[device.did]?.phase == .waiting { return L10n.tr("已提交，等待当前读取完成", "Submitted; waiting for the current read") }
        if !busy {
            if controller.readFailures[device.did] != nil { return L10n.tr("读取失败，将自动重试", "Read failed; will retry automatically") }
            if controller.submissions[device.did]?.phase == .succeeded { return L10n.tr("上次用户请求已完成", "Last user request completed") }
            return L10n.tr("状态自动刷新", "State updates automatically")
        }
        if busy, state == nil || state?.stage == .idle { return L10n.tr("准备读取或控制", "Preparing Read or Control") }
        return switch state?.stage {
        case .requested, .waiting: L10n.tr("准备发送", "Preparing request")
        case .hello: L10n.tr("正在连接", "Connecting")
        case .info: L10n.tr("正在检查设备", "Checking device")
        case .preflight: L10n.tr("正在读取状态", "Reading state")
        case .write: L10n.tr("正在发送指令", "Sending command")
        case .confirmation: L10n.tr("正在确认结果", "Confirming result")
        case .finished: L10n.tr("本次请求结束；随统一轮询更新", "Request finished; follows device polling")
        default: L10n.tr("等待统一轮询或手动操作", "Awaiting device polling or a manual action")
        }
    }
    private func commit(_ value: Int) {
        if controller.send(device.did, .position(value)) { draft.submitted(value) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    let wasDragging = draft.dragging
                    draft.setDragging(editing)
                    if !editing, wasDragging { commit(value) }
                    controller.setEditing(device.did, editor: editorID, active: editing)
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
                    Button(L10n.tr("全开", "Open")) { if controller.send(device.did, .open) { draft.discard() } }.disabled(!canMove)
                    Button(L10n.tr("全关", "Close")) { if controller.send(device.did, .close) { draft.discard() } }.disabled(!canMove)
                    Button(L10n.tr("停止", "Stop")) { if controller.send(device.did, .stop) { draft.discard() } }
                        .disabled(controller.stopping.contains(device.did) || (busy && state?.canStop != true))
                        .keyboardShortcut(".", modifiers: [.command])
                    Spacer()
                }
                if busy, let goal = controller.submissions[device.did]?.command?.target {
                    Text(L10n.tr("已提交目标 \(goal)%", "Submitted target \(goal)%"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if let command = state?.command, !((state?.confirmed) ?? false), let goal = command.target {
                    Text(busy ? L10n.tr("目标 \(goal)% · 本次请求正在确认", "Target \(goal)% · Confirming this request") : L10n.tr("上次目标 \(goal)% · 结果未确认", "Previous target \(goal)% · Unconfirmed"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L10n.tr("刷新", "Refresh")) { controller.read(device.did) }
                        .disabled(busy)
                }
                if let message = state?.message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let error = controller.errors[device.did] { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
            Text(L10n.tr("状态随统一刷新更新，普通读取不会打断编辑。松开滑块或确认后提交一次；若已有读取在途，将等待它结束。写入不会自动重发，并通过实际位置和电机状态确认结果。读取失败会显示原因并退避重试。0% 全遮住，100% 全拉开。", "State follows the shared refresh schedule without interrupting editing. Releasing the slider or confirming submits once, waiting for any in-flight read. Writes are never automatically retried; actual position and motor state confirm results. Read failures are shown and retried after backoff. 0% closed, 100% open."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: typing) { _, value in
            draft.focus(value)
        }
        .onDisappear { controller.setEditing(device.did, editor: editorID, active: false) }
        .onChange(of: device.did) { old, _ in
            controller.setEditing(old, editor: editorID, active: false)
            typing = false
            draft = CurtainPositionDraft()
            draft.receive(state?.position)
        }
        .onChange(of: state?.position, initial: true) { _, position in
            draft.receive(position)
        }
        .onChange(of: controller.submissions[device.did], initial: true) { _, submission in
            if submission?.phase == .succeeded { draft.finishedSubmission(succeeded: true) }
            else if submission?.phase == .failed { draft.finishedSubmission(succeeded: false) }
        }
    }
}
