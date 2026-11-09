import AppKit
import MijiaCore
import MijiaLAN
import SwiftUI
import UniformTypeIdentifiers

/// Local journal only: this screen has no device/API/controller dependency.
struct SettingsDiagnostics: View {
    let journal: CurtainEventLog
    @State private var text = ""
    @State private var importantOnly = true
    @State private var status: String?
    @State private var history: DeviceEventLog.History?
    @State private var exporting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("诊断日志", "Diagnostic Logs")).font(.headline)
            Text(L10n.tr("默认保存在本机，退出或重开后仍可查；完整收发滚动保留最多 64 MiB（4 × 16 MiB），控制和异常另留最多 4 MiB，不上传。实际保留时长随流量变化。C1、C2 等是本地设备代号。查看、刷新和导出不会查询设备。", "Stored locally across restarts: up to 64 MiB of traffic (4 × 16 MiB) plus 4 MiB of control/error history, never uploaded. Retention duration depends on traffic. C1, C2, etc. identify local devices. Viewing, refreshing and exporting never query devices."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let history {
                coverage(L10n.tr("完整收发", "Traffic"), history.traffic)
                coverage(L10n.tr("关键历史", "Important History"), history.important)
            }
            Toggle(L10n.tr("只看控制与异常", "Control and Errors Only"), isOn: $importantOnly).onChange(of: importantOnly) { _, _ in reload() }
            HStack {
                Button(L10n.tr("刷新本地记录", "Refresh Local Records")) { reload() }
                Button(exporting ? L10n.tr("正在导出…", "Exporting…") : L10n.tr("导出全部历史…", "Export All History…")) { export() }.disabled(exporting)
                Button(L10n.tr("复制当前显示", "Copy Displayed")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            if journal.storageFailed { Text(L10n.tr("本地日志保存失败，当前内存记录仍可导出。", "Local persistence failed; current memory records can still be exported.")).foregroundStyle(.orange).font(.caption) }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? L10n.tr("暂无事件", "No Events Yet") : text)
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 220, maxHeight: 440)
            Text(L10n.tr("页面只显示最近 200 条事件。导出在后台分块读取全部现存历史，包含单独保留的关键记录；两类历史重叠处可能重复，可用 run + sequence 去重。关键历史的时间跨度不表示完整收发也覆盖同一时段。", "This page shows the latest 200 events. Export streams all retained history in the background, including the separate important archive. Overlapping events may repeat; deduplicate by run + sequence. The important archive’s time range does not describe traffic coverage."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("记录包括操作来源、同一操作编号、发送尝试/系统已发送/收到数据/校验结果、返回码、耗时、最后有效位置及暂停原因。received 仅代表收到数据，acknowledged 不代表运动完成。日志不含设备标识、地址、凭据、配对资料或报文原文。", "Events link each operation, source, transport attempt/sent/received/validation, codes, timing, last valid sample and pause reason. Received is not validation; acknowledged is not motion complete. No device identifiers, addresses, credentials, pairing data or raw packets."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("收发诊断增加临时 socket 代号、本地源端口、RPC 编号、收发 stamp 与校时年龄；packetChecked 区分校验标志，失败批次仍保留白名单标量和类型。它们用于后续对照，不代表已确定卷帘故障原因。", "Transport diagnostics include ephemeral socket IDs, local source ports, RPC IDs, stamps and clock ages. packetChecked carries validation flags; failed batches retain whitelisted scalars/types. These support comparison, not a confirmed curtain failure diagnosis."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .onAppear { reload() }
    }
    private func coverage(_ title: String, _ range: DeviceEventLog.Coverage) -> some View {
        Text(range.oldest.map { first in
            L10n.tr("\(title)：最早可查 \(first.formatted()) · 最新 \(range.newest?.formatted() ?? "—")", "\(title): earliest \(first.formatted()) · latest \(range.newest?.formatted() ?? "—")")
        } ?? L10n.tr("\(title)：暂无记录", "\(title): no records"))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func reload() {
        text = journal.recentText(importantOnly: importantOnly)
        Task { history = await journal.history() }
    }
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MijiaLAN-diagnostics.jsonl"
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            exporting = true
            Task {
                defer { exporting = false }
                do { try await journal.export(to: url); status = L10n.tr("全部现存历史已导出", "All retained history exported") }
                catch { status = L10n.tr("无法导出到所选位置", "Could not export to that location") }
            }
        }
    }
}
