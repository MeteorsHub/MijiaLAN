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
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("诊断日志", "Diagnostic Logs")).font(.headline)
            Text(L10n.tr("默认保存在本机，退出或重开后仍可查；全部收发滚动保留最多 16 MiB，控制和异常另留最多 4 MiB，不上传。C1、C2 等是本地设备代号。查看、刷新和导出不会查询设备。", "Stored locally across restarts, up to 16 MiB of recent traffic plus 4 MiB of control/error history, never uploaded. C1, C2, etc. identify local devices. Viewing, refreshing and exporting never query devices."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.tr("只看控制与异常", "Control and Errors Only"), isOn: $importantOnly).onChange(of: importantOnly) { _, _ in reload() }
            HStack {
                Button(L10n.tr("刷新本地记录", "Refresh Local Records")) { reload() }
                Button(L10n.tr("导出日志…", "Export Logs…")) { export() }
                Button(L10n.tr("复制", "Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(journal.exportText(), forType: .string)
                }
            }
            if journal.storageFailed { Text(L10n.tr("本地日志保存失败，当前内存记录仍可导出。", "Local persistence failed; current memory records can still be exported.")).foregroundStyle(.orange).font(.caption) }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? L10n.tr("暂无事件", "No Events Yet") : text)
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 220, maxHeight: 440)
            Text(L10n.tr("记录包括操作来源、同一操作编号、发送尝试/系统已发送/收到数据/校验结果、返回码、耗时、最后有效位置及暂停原因。received 仅代表收到数据，acknowledged 不代表运动完成。日志不含设备标识、地址、凭据、配对资料或报文原文。", "Events link each operation, source, transport attempt/sent/received/validation, codes, timing, last valid sample and pause reason. Received is not validation; acknowledged is not motion complete. No device identifiers, addresses, credentials, pairing data or raw packets."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .onAppear { reload() }
    }
    private func reload() { text = journal.recentText(importantOnly: importantOnly) }
    private func export() {
        let data = journal.exportData()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MijiaLAN-diagnostics.jsonl"
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic); status = L10n.tr("日志已导出", "Logs exported") }
            catch { status = L10n.tr("无法导出到所选位置", "Could not export to that location") }
        }
    }
}
