import Foundation
import MijiaCore
import MijiaLAN
import SwiftUI

struct AmbientColorPalette: View {
    let controller: DeviceController
    let snapshot: DeviceSnapshot
    let capability: DeviceCapability

    @State private var draft: Int?
    @State private var applying = false
    @State private var result: String?
    @State private var failed = false

    private var confirmed: Int? {
        guard let value = snapshot.value(capability.id)?.doubleValue,
              (1...16_777_215).contains(value) else { return nil }
        return Int(exactly: value)
    }

    private var canWrite: Bool {
        snapshot.isOnline && snapshot.controlUnavailableReason(capability) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.tr("副灯颜色", "Ambient Color"))
                Spacer()
                swatch(confirmed)
                Text(confirmed.map { String(format: "#%06X", $0) } ?? L10n.tr("未读取", "Unknown"))
                    .monospacedDigit()
                if draft == nil {
                    Button(L10n.tr("调色", "Edit Color")) {
                        draft = confirmed ?? 0xffffff
                        result = nil
                    }
                    .disabled(!canWrite)
                }
            }

            if let draft {
                HStack(spacing: 10) {
                    preset(0xff0000, L10n.tr("红", "Red"))
                    preset(0xffff00, L10n.tr("黄", "Yellow"))
                    preset(0x00ff00, L10n.tr("绿", "Green"))
                    preset(0x00ffff, L10n.tr("青", "Cyan"))
                    preset(0x0000ff, L10n.tr("蓝", "Blue"))
                    preset(0xff00ff, L10n.tr("紫", "Magenta"))
                    preset(0xffffff, L10n.tr("白", "White"))
                }
                channel(16, L10n.tr("红", "Red"), tint: .red)
                channel(8, L10n.tr("绿", "Green"), tint: .green)
                channel(0, L10n.tr("蓝", "Blue"), tint: .blue)
                HStack {
                    swatch(draft).accessibilityLabel(L10n.tr("待应用颜色", "Draft Color"))
                    Text(String(format: "#%06X", draft)).monospacedDigit()
                    Spacer()
                    Button(L10n.tr("取消", "Cancel")) {
                        self.draft = nil
                        result = nil
                    }
                    .disabled(applying)
                    Button(L10n.tr("应用", "Apply")) { apply(draft) }
                        .disabled(!canWrite || applying || draft == 0 || draft == confirmed)
                }
                if draft == 0 {
                    Text(L10n.tr("要熄灭副灯，请使用开关。", "Use the power switch to turn off the ambient light."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if applying {
                Text(L10n.tr("正在写入并回读颜色…", "Writing and reading back color…"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let result {
                Text(result).font(.caption).foregroundStyle(failed ? Color.orange : Color.secondary)
            } else if let reason = snapshot.controlUnavailableReason(capability) {
                Text(reason).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func swatch(_ rgb: Int?) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(rgb.map { value in
                Color(.sRGB, red: Double((value >> 16) & 255) / 255,
                      green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
            } ?? Color.secondary.opacity(0.15))
            .frame(width: 24, height: 18)
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4)) }
    }

    private func preset(_ rgb: Int, _ label: String) -> some View {
        Button {
            draft = rgb
        } label: {
            swatch(rgb)
        }
        .buttonStyle(.plain).accessibilityLabel(label).help(label)
        .disabled(applying)
    }

    private func channel(_ shift: Int, _ label: String, tint: Color) -> some View {
        Slider(value: Binding(
            get: { Double(((draft ?? 0) >> shift) & 255) },
            set: { amount in
                draft = ((draft ?? 0) & ~(255 << shift)) | (Int(amount.rounded()) << shift)
            }
        ), in: 0...255, step: 1) {
            Text(label)
        }
        .tint(tint)
        .disabled(applying)
    }

    private func apply(_ rgb: Int) {
        applying = true
        result = nil
        Task { @MainActor in
            defer { applying = false }
            do {
                try await controller.execute(did: snapshot.id, .set(capability.id, .number(Double(rgb))))
                draft = nil
                failed = false
                result = L10n.tr("颜色已回读确认", "Color Read Back")
            } catch {
                failed = true
                result = error.localizedDescription
            }
        }
    }
}
