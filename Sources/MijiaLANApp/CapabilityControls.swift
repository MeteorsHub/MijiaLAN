import MijiaCore
import MijiaLAN
import SwiftUI

struct CapabilityControls: View {
    let controller: DeviceController
    let snapshot: DeviceSnapshot
    var excluding: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if snapshot.schema.isCooking {
                Text(L10n.tr("先选择下次菜单，再点开始。选择参数不会启动设备。", "Choose the next menu, then press Start. Selecting settings does not start the device."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.controls.filter { !excluding.contains($0.id) }) { capability in
                CapabilityControlRow(controller: controller, snapshot: snapshot, capability: capability)
            }
        }
        .font(.caption).controlSize(.small)
    }
}

private struct CapabilityControlRow: View {
    let controller: DeviceController
    let snapshot: DeviceSnapshot
    let capability: DeviceCapability
    @State private var error: String?
    @State private var working = false

    private var value: JSONValue? { snapshot.controlValue(capability) }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center) {
                Text(capability.prepared && ["mode", "cook-mode"].contains(capability.name) ? L10n.tr("下次菜单", "Next Menu") : capability.displayTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                control
            }
            .disabled(working || (!capability.prepared && !snapshot.isOnline))
            if let error { Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }
    @ViewBuilder private var control: some View {
        switch capability.control {
        case .toggle:
            if let current = value?.boolValue {
                Toggle(capability.displayTitle, isOn: Binding(get: { current }, set: { send(.set(capability.id, .bool($0))) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            } else {
                Text(capability.prepared ? L10n.tr("尚未选择", "Not Selected") : L10n.tr("状态未知", "Unknown State")).foregroundStyle(.secondary)
                Button(L10n.tr("开启", "On")) { send(.set(capability.id, .bool(true))) }
                Button(L10n.tr("关闭", "Off")) { send(.set(capability.id, .bool(false))) }
            }
        case .choice:
            Picker(capability.displayTitle, selection: Binding(get: { value?.intValue ?? Int.min }, set: {
                if $0 != Int.min { send(.set(capability.id, .number(Double($0)))) }
            })) {
                Text(capability.prepared ? L10n.tr("请选择", "Select…") : L10n.tr("状态未知", "Unknown State")).tag(Int.min)
                ForEach(capability.options) { Text($0.title).tag($0.value) }
            }
            .labelsHidden().frame(maxWidth: 180)
        case .number:
            CapabilityNumberInput(capability: capability, value: value, working: working) {
                send(.set(capability.id, .number($0)))
            }
        case .button:
            Button(working ? L10n.tr("执行中…", "Running…") : capability.title) {
                send(capability.kind == .action ? .invoke(capability.id) : .set(capability.id, .bool(true)))
            }
        default: Text(capability.formatted(value))
        }
    }
    private func send(_ command: CapabilityCommand) {
        working = true; error = nil
        Task {
            defer { working = false }
            do {
                try await controller.execute(did: snapshot.id, command, coalesce: capability.control == .number)
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// The device value stays live until the user starts a separate edit draft.
struct CapabilityNumberInput: View {
    let capability: DeviceCapability
    let value: JSONValue?
    var working = false
    let apply: (Double) -> Void
    @State private var draft = ""
    @State private var isEditingDraft = false
    @State private var validationError: String?
    @FocusState private var isFocused: Bool

    private var currentText: String { value?.doubleValue.map(numberText) ?? "" }
    private var text: Binding<String> {
        Binding(get: { draft }, set: {
            draft = $0
            isEditingDraft = Double($0.trimmingCharacters(in: .whitespaces)) != value?.doubleValue
                || (!$0.isEmpty && Double($0.trimmingCharacters(in: .whitespaces)) == nil)
            validationError = nil
        })
    }
    private var hasChanges: Bool {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard let number = Double(draft.trimmingCharacters(in: .whitespaces)) else { return true }
        return number != value?.doubleValue
    }
    private var rangeHint: String {
        guard let min = capability.min, let max = capability.max else { return L10n.tr("输入数值后按回车或点击应用", "Enter a value, then press Return or click Apply.") }
        return L10n.tr("允许 \(numberText(min))–\(numberText(max))\(capability.displayUnit)，步长 \(numberText(capability.step))", "Range: \(numberText(min))–\(numberText(max))\(capability.displayUnit); step: \(numberText(capability.step))")
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 5) {
                TextField(L10n.tr("输入数值", "Enter a value"), text: text)
                    .frame(width: 68).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .accessibilityLabel(capability.displayTitle)
                    .accessibilityHint(rangeHint)
                    .help(rangeHint)
                    .onSubmit(submit)
                if !capability.displayUnit.isEmpty {
                    Text(capability.displayUnit.trimmingCharacters(in: .whitespaces)).foregroundStyle(.secondary)
                }
                Button(working ? L10n.tr("应用中…", "Applying…") : L10n.tr("应用", "Apply"), action: submit)
                    .disabled(working || !hasChanges)
                    .help(hasChanges ? L10n.tr("应用新的\(capability.displayTitle)", "Apply the new \(capability.displayTitle)") : L10n.tr("修改数值后可应用", "Change the value to apply it."))
            }
            .disabled(working)
            if let validationError {
                Text(validationError).foregroundStyle(.orange)
                    .frame(maxWidth: 180, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
        .onChange(of: value, initial: true) {
            if !isEditingDraft || Double(draft) == value?.doubleValue {
                draft = currentText
                isEditingDraft = false
            }
        }
        .onChange(of: working) {
            if !working { draft = currentText; isEditingDraft = false }
        }
    }

    private func submit() {
        guard !working, hasChanges else { return }
        guard let number = Double(draft.trimmingCharacters(in: .whitespaces)), number.isFinite else {
            validationError = L10n.tr("请输入有效数字", "Enter a valid number."); return
        }
        do { _ = try capability.validated(.number(number)) }
        catch { validationError = rangeHint; return }
        validationError = nil
        isEditingDraft = false
        isFocused = false
        apply(number)
    }

    private func numberText(_ number: Double) -> String {
        number.rounded() == number ? String(format: "%.0f", number) : String(number)
    }
}
