import Foundation
import MijiaCore
import MijiaLAN
import SwiftUI

struct CurtainValidationPanel: View {
    let controller: CurtainValidationController
    let device: LocalDevice
    @State private var targetText = ""
    @FocusState private var editingTarget: Bool

    private var selected: Bool { controller.deviceID == device.did }
    private var state: CurtainValidationSession.State? { selected ? controller.state : nil }
    private var target: Int? { Int(targetText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var canMove: Bool {
        guard !controller.isWorking, let state, state.phase == .ready, state.motorStatus == 1,
              let current = state.position, let target, (1...99).contains(target), target != current else { return false }
        return abs(target - current) <= 5
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10n.tr("启用此设备的小幅位置验证", "Enable Small Position Validation for This Device"), isOn: Binding(
                get: { selected }, set: { if $0 { controller.enable(device) } else { controller.disable() } }))
                .toggleStyle(.switch).controlSize(.small)
                .disabled(!selected && controller.isWorking)
            Text(L10n.tr("仅本次运行有效，一次选定一台。启用后先验证读数，后续由你主动操作；请求至少间隔 5 秒。", "Session only, one selected device. Enabling first checks readings; subsequent requests are manual and at least 5 seconds apart."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if selected {
                if controller.isWorking { ProgressView().controlSize(.small) }
                HStack {
                    Text(L10n.tr("已验证位置", "Validated Position"))
                    Spacer()
                    Text(state?.position.map { "\($0)%" } ?? "—")
                }
                if let date = state?.sampledAt { Text(date.formatted()).font(.caption).foregroundStyle(.secondary) }
                if state?.phase == .ready {
                    HStack {
                        TextField(L10n.tr("目标位置 %", "Target Position %"), text: $targetText)
                            .textFieldStyle(.roundedBorder).frame(width: 100).focused($editingTarget)
                        Button(L10n.tr("验证移动", "Validate Move")) { if let target { controller.move(to: target) } }.disabled(!canMove)
                        Button(L10n.tr("更新读数", "Refresh Readings")) { controller.refresh() }.disabled(controller.isWorking)
                    }
                }
                if let state, state.requestedTarget != nil, !state.confirmed, !controller.isWorking {
                    Button(L10n.tr("仅回读确认", "Confirm by Reading Only")) { controller.confirm() }
                    Text(L10n.tr("写入结果未确认，已暂停自动请求；此按钮只读取位置和停止状态，不重发目标。", "Write outcome unconfirmed; automatic requests are paused. This button only reads position and stopped state, without resending the target."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let message = state?.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let error = controller.error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }
            Text(L10n.tr("启用后，本次运行暂停自动发现及卷帘连通性探测。目标限 1–99%，单次变化不超过 5 个百分点。开、关、停止和桥接控制待后续验收。", "Enabling suspends discovery and background curtain connectivity probes until restart. Targets: 1–99%, at most 5 percentage points per move. Open, Close, Stop and bridge control await separate acceptance."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: state?.position) { _, position in
            if !editingTarget, let position { targetText = String(min(99, max(1, position + 5))) }
        }
    }
}
