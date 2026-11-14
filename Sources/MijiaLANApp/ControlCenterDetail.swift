import MijiaCore
import MijiaLAN
import SwiftUI

struct ControlCenterDeviceDetail: View {
    let model: AppModel
    let device: LocalDevice
    @State private var working = false
    @State private var error: String?
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if device.model != CurtainValidationSession.model, let reason = DeviceLANPolicy.restriction(for: device.model) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(DeviceLANPolicy.unverifiedReadingsTitle, systemImage: "pause.circle")
                        .font(.callout.weight(.medium))
                    Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if device.model == CurtainValidationSession.model {
                CurtainControlPanel(controller: model.curtains, device: device)
            }
            if let snapshot = model.devices.snapshots[device.did] {
                if !snapshot.isOnline { OfflineDeviceCard(model: model, device: device) }
                if DeviceLANPolicy.allowsPropertyRequests(for: device.model) {
                    if snapshot.schema.category == "air-conditioner" {
                        AirConditionerControl(snapshot: snapshot, working: working, perform: run)
                        Text(L10n.tr("家庭中的当前温度使用设定温度占位，此设备没有实测室温读数。", "Home uses the target temperature as a placeholder for the current temperature. This device does not report measured room temperature."))
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        additionalControls(snapshot, excluding: ["p:2:1", "p:2:2", "p:2:3", "p:3:1", "p:3:2"])
                    } else if snapshot.schema.category == "light", let brightness = snapshot.capability("light", "brightness") {
                        LampControl(controller: model.devices, snapshot: snapshot, brightness: brightness)
                        if let temperature = snapshot.capability("light", "color-temperature"), temperature.control == .number {
                            LampColorTemperatureControl(controller: model.devices, snapshot: snapshot, capability: temperature)
                        }
                        additionalControls(snapshot, excluding: [brightness.id, snapshot.primaryPower?.id ?? "", snapshot.capability("light", "color-temperature")?.id ?? ""])
                    } else {
                        CapabilityControls(controller: model.devices, snapshot: snapshot, excluding: [snapshot.primaryPower?.id ?? ""])
                    }
                    // Lamp values already show the result. A transient feedback row resizes
                    // the menu-bar window on every streamed write and confirmation.
                    if snapshot.schema.category != "light" {
                        DeviceCommandFeedback(snapshot: snapshot)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                DeviceInformation(snapshot: snapshot, curtainState: model.curtains.states[device.did], usesCurtainControl: device.model == CurtainValidationSession.model)
            } else {
                Text(L10n.tr("尚未获取到设备接口。请重试或在设置中重新导入设备。", "Device controls are not available yet. Retry or re-import the device in Settings."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            PanelDisclosure(L10n.tr("设备管理", "Device Management"), deviceID: device.did, section: "management") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(L10n.tr("在「家庭」中显示", "Show in Home"), isOn: Binding(get: { model.isInHomeKit(device) }, set: { model.setInHomeKit(device, $0) }))
                        .toggleStyle(.switch).controlSize(.mini).disabled(!model.homeKitSupports(device))
                    Button(L10n.tr("从清单移除", "Remove from List"), role: .destructive) { confirmingRemoval = true }
                        .buttonStyle(.borderless)
                }
                .padding(.top, 6)
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 16)
        .alert(L10n.tr("从设备清单移除？", "Remove from Device List?"), isPresented: $confirmingRemoval) {
            Button(L10n.tr("移除", "Remove"), role: .destructive) { model.remove(device) }
            Button(L10n.tr("取消", "Cancel"), role: .cancel) {}
        } message: { Text(L10n.tr("\(device.name)也会从此桥的家庭配件中移除。之后可重新导入。", "\(device.name) will also be removed from this bridge in Home. You can re-import it later.")) }
    }

    @ViewBuilder private func additionalControls(_ snapshot: DeviceSnapshot, excluding: Set<String>) -> some View {
        if snapshot.controls.contains(where: { !excluding.contains($0.id) }) {
            PanelDisclosure(L10n.tr("更多控制", "More Controls"), deviceID: device.did, section: "controls") {
                CapabilityControls(controller: model.devices, snapshot: snapshot, excluding: excluding).padding(.top, 8)
            }
            .font(.system(size: 12))
        }
    }

    private func run(_ command: CapabilityCommand) {
        working = true; error = nil
        Task {
            defer { working = false }
            do { try await model.devices.execute(did: device.did, command, coalesce: true) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct AirConditionerControl: View {
    let snapshot: DeviceSnapshot
    let working: Bool
    let perform: (CapabilityCommand) -> Void
    @Environment(\.colorScheme) private var scheme

    private var target: DeviceCapability? { snapshot.capability("air-conditioner", "target-temperature") }
    private var temperature: Double? { target.flatMap { snapshot.value($0.id)?.doubleValue } }
    private var on: Bool? { snapshot.primaryPower.flatMap { snapshot.value($0.id)?.boolValue } }
    private var unavailable: Bool { !snapshot.isOnline || working }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                temperatureButton(-1)
                Spacer(minLength: 2)
                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 1) {
                        Text(temperature.map(DevicePresentation.number) ?? "—")
                            .font(.system(size: 52, weight: .ultraLight)).monospacedDigit()
                        Text("°C").font(.system(size: 20, weight: .light)).foregroundStyle(.secondary).padding(.top, 7)
                    }
                    Text(on == false ? L10n.tr("已关闭 · 设定温度", "Off · Target Temperature") : on == true ? DevicePresentation.summary(snapshot) : L10n.tr("等待设备状态", "Waiting for Device State"))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                temperatureButton(1)
            }
            .padding(.horizontal, 8).padding(.top, 6)
            if let mode = snapshot.capability("air-conditioner", "mode") {
                HStack(spacing: 6) {
                    ForEach(mode.options) { option in
                        let selected = snapshot.value(mode.id)?.intValue == option.value
                        Button { perform(.set(mode.id, .number(Double(option.value)))) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: Self.symbol(option.value)).font(.system(size: 17))
                                Text(option.title).font(.system(size: 12))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .foregroundStyle(selected ? Color.white : .secondary)
                        }
                        .buttonStyle(ControlCenterButtonStyle())
                        .background(selected ? Color.blue : ControlCenterPalette(scheme: scheme).subtle, in: .rect(cornerRadius: 10))
                        .accessibilityLabel(L10n.tr("\(option.title)模式", "\(option.title) mode")).accessibilityValue(selected ? L10n.tr("已选择", "Selected") : L10n.tr("未选择", "Not Selected"))
                    }
                }
                .disabled(unavailable)
            }
            if let fan = snapshot.capability("fan-control", "fan-level") {
                HStack(spacing: 12) {
                    Text(L10n.tr("风速", "Fan Speed")).foregroundStyle(.secondary)
                    Picker(L10n.tr("风速", "Fan Speed"), selection: Binding(get: { snapshot.value(fan.id)?.intValue ?? -1 }, set: { perform(.set(fan.id, .number(Double($0)))) })) {
                        if snapshot.value(fan.id) == nil { Text(L10n.tr("未知", "Unknown")).tag(-1) }
                        ForEach(fan.options) { Text($0.title).tag($0.value) }
                    }
                    .pickerStyle(.segmented).labelsHidden().disabled(unavailable)
                }
                .font(.system(size: 12))
            }
            if let swing = snapshot.capability("fan-control", "vertical-swing") {
                HStack {
                    Text(L10n.tr("扫风", "Swing")).foregroundStyle(.secondary)
                    Spacer()
                    if let actual = snapshot.value(swing.id)?.boolValue {
                        Toggle(L10n.tr("扫风", "Swing"), isOn: Binding(get: { actual }, set: { perform(.set(swing.id, .bool($0))) }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(.blue).disabled(unavailable)
                    } else { Text(L10n.tr("状态未知", "Unknown State")).foregroundStyle(.tertiary) }
                }
                .font(.system(size: 12))
            }
            if let power = snapshot.value("power-consumption", "electric-power")?.doubleValue {
                Text(L10n.tr("当前功率 \(DevicePresentation.number(power)) W", "Current power: \(DevicePresentation.number(power)) W")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private func temperatureButton(_ direction: Double) -> some View {
        Button {
            if let target { perform(.adjust(target.id, direction)) }
        } label: {
            Image(systemName: direction < 0 ? "minus" : "plus").font(.system(size: 17))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(ControlCenterButtonStyle(radius: 20))
        .background(ControlCenterPalette(scheme: scheme).tile, in: .circle)
        .disabled(unavailable || temperature == nil || (direction < 0 ? (temperature ?? 0) <= (target?.min ?? 16) : (temperature ?? 0) >= (target?.max ?? 30)))
        .accessibilityLabel(direction < 0 ? L10n.tr("降低设定温度", "Decrease target temperature") : L10n.tr("升高设定温度", "Increase target temperature"))
    }
    private static func symbol(_ mode: Int) -> String {
        switch mode { case 0: "sparkles"; case 1: "snowflake"; case 2: "drop"; case 3: "sun.max"; default: "wind" }
    }
}

private struct LampControl: View {
    let snapshot: DeviceSnapshot
    let brightness: DeviceCapability
    @State private var writer: ContinuousValueWriter
    @Environment(\.panelPresented) private var panelPresented

    init(controller: DeviceController, snapshot: DeviceSnapshot, brightness: DeviceCapability) {
        self.snapshot = snapshot; self.brightness = brightness
        let did = snapshot.id
        // This view owns edit intent for one device; the detail's identity is the device ID.
        _writer = State(initialValue: ContinuousValueWriter { value in
            try await controller.execute(did: did, .setLightBrightness(value))
        })
    }

    var body: some View {
        VStack(spacing: 12) {
            BrightnessBar(value: writer.pendingValue ?? snapshot.value(brightness.id)?.doubleValue,
                          range: (brightness.min ?? 1)...(brightness.max ?? 100), step: brightness.step, commit: writer.submit)
            .disabled(!snapshot.isOnline)
            Text(hint)
                .font(.system(size: 12))
                .foregroundStyle(writer.error == nil ? Color.secondary : Color.orange)
                .lineLimit(1).frame(maxWidth: .infinity).frame(height: 16)
                .help(hint)
        }
        .onDisappear { writer.cancelPending() }
        .onChange(of: panelPresented) { if !panelPresented { writer.cancelPending() } }
    }

    private var hint: String {
        writer.error ?? (snapshot.primaryPower.flatMap { snapshot.value($0.id)?.boolValue } == false
                        ? L10n.tr("已关闭 · 拖动滑块即可开灯", "Off · Drag the slider to turn on") : L10n.tr("拖动调节亮度", "Drag to adjust brightness"))
    }
}

private struct LampColorTemperatureControl: View {
    let snapshot: DeviceSnapshot
    let capability: DeviceCapability
    @State private var writer: ContinuousValueWriter
    @State private var draft: Double?
    @State private var isEditing = false
    @Environment(\.panelPresented) private var panelPresented
    @Environment(\.panelSession) private var session

    init(controller: DeviceController, snapshot: DeviceSnapshot, capability: DeviceCapability) {
        self.snapshot = snapshot; self.capability = capability
        let did = snapshot.id, id = capability.id
        _writer = State(initialValue: ContinuousValueWriter { value in
            try await controller.execute(did: did, .set(id, .number(value)))
        })
    }

    private var actual: Double? { snapshot.value(capability.id)?.doubleValue }
    private var displayed: Double? { draft ?? writer.pendingValue ?? actual }
    private var range: ClosedRange<Double> { (capability.min ?? 2600)...(capability.max ?? 5000) }

    var body: some View {
        VStack(spacing: 8) {
            temperatureHeader
            temperatureSlider
            HStack {
                Text(L10n.tr("暖光", "Warm"))
                Spacer()
                Text(L10n.tr("冷光", "Cool"))
            }
            .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            if let error = writer.error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!snapshot.isOnline)
        .onChange(of: writer.isSending) { if !writer.isSending, !isEditing { draft = nil } }
        .onDisappear { writer.cancelPending() }
        .onChange(of: panelPresented) {
            if !panelPresented { writer.cancelPending(); draft = nil; isEditing = false }
        }
    }

    private var temperatureHeader: some View {
        HStack {
            Text(L10n.tr("色温", "Color Temperature")).font(.system(size: 12, weight: .medium))
            Spacer()
            CapabilityNumberInput(capability: capability,
                                  value: displayed.map(JSONValue.number), working: writer.isSending,
                                  persistedDraft: session?.numberDraft(deviceID: snapshot.id, capabilityID: capability.id)) {
                writer.submit($0)
                draft = nil
            }
            .font(.caption)
        }
    }

    private var temperatureSlider: some View {
        // Keep the native slider continuous: a 1 K step produces thousands of marks on macOS 27.
        // Quantization and submission remain in their original edit callbacks.
        Slider(value: sliderValue, in: range, onEditingChanged: { editing in editingChanged(editing) }) {
            Text(L10n.tr("色温", "Color Temperature"))
        }
        .labelsHidden()
        .accessibilityValue(sliderAccessibilityValue)
        .accessibilityHint(L10n.tr("向左调暖，向右调冷", "Move left for warmer light and right for cooler light."))
        .accessibilityAdjustableAction { adjust($0 == .increment ? 1 : -1) }
        .onKeyPress(.leftArrow) { adjust(-1); return .handled }
        .onKeyPress(.rightArrow) { adjust(1); return .handled }
    }

    private var sliderValue: Binding<Double> {
        Binding(get: { displayed ?? range.lowerBound }, set: { raw in updateDraft(raw) })
    }
    private var sliderAccessibilityValue: String {
        if let target = draft ?? writer.pendingValue {
            return L10n.tr("目标 \(DevicePresentation.number(target)) K", "Target: \(DevicePresentation.number(target)) K")
        }
        if let actual { return "\(DevicePresentation.number(actual)) K" }
        return L10n.tr("尚无读数", "No Reading")
    }
    private func updateDraft(_ raw: Double) {
        draft = min(range.upperBound, max(range.lowerBound,
            range.lowerBound + ((raw - range.lowerBound) / capability.step).rounded() * capability.step))
    }
    private func editingChanged(_ editing: Bool) {
        isEditing = editing
        guard !editing, let draft else { return }
        guard draft != (writer.pendingValue ?? actual) else { self.draft = nil; return }
        writer.submit(draft)
    }

    private func adjust(_ direction: Double) {
        guard snapshot.isOnline else { return }
        let value = displayed ?? range.lowerBound
        let next = min(range.upperBound, max(range.lowerBound, value + direction * capability.step))
        guard next != value else { return }
        draft = next
        writer.submit(next)
    }
}

/// A filled slider matching the supplied design, with keyboard and VoiceOver adjustment as well as dragging.
private struct BrightnessBar: View {
    let value: Double?
    let range: ClosedRange<Double>
    let step: Double
    let commit: (Double) -> Void
    @State private var draft: Double?
    @State private var isDragging = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme

    private var current: Double { draft ?? value ?? range.lowerBound }
    private var fraction: Double { min(1, max(0, (current - range.lowerBound) / max(1, range.upperBound - range.lowerBound))) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12).fill(ControlCenterPalette(scheme: scheme).tile)
                Rectangle().fill(scheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.78))
                    .frame(width: geometry.size.width * (value == nil && draft == nil ? 0 : fraction))
                HStack {
                    Image(systemName: "sun.max").font(.system(size: 18))
                    Spacer()
                    Text(value == nil && draft == nil ? L10n.tr("尚无读数", "No Reading") : "\(DevicePresentation.number(current))%")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                .padding(.horizontal, 14).foregroundStyle(.white).blendMode(.difference)
            }
            .compositingGroup().clipShape(.rect(cornerRadius: 12)).contentShape(.rect(cornerRadius: 12))
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                guard enabled else { return }
                isDragging = true
                let next = quantized(range.lowerBound + min(1, max(0, gesture.location.x / geometry.size.width)) * (range.upperBound - range.lowerBound))
                if draft != next { draft = next; commit(next) }
            }.onEnded { _ in
                guard enabled, let draft else { return }
                commit(draft); self.draft = nil; isDragging = false
            })
        }
        .frame(height: 48).opacity(enabled ? 1 : 0.5)
        .focusable(enabled)
        .onKeyPress(.leftArrow) { adjust(-1); return .handled }
        .onKeyPress(.rightArrow) { adjust(1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("亮度", "Brightness"))
        .accessibilityValue(value == nil && draft == nil ? L10n.tr("状态未知", "Unknown State") : "\(DevicePresentation.number(current))%")
        .accessibilityAdjustableAction { direction in adjust(direction == .increment ? 1 : -1) }
        .onChange(of: value) { if !isDragging { draft = nil } }
        .onChange(of: enabled) { if !enabled { draft = nil; isDragging = false } }
    }
    private func quantized(_ raw: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, range.lowerBound + ((raw - range.lowerBound) / step).rounded() * step))
    }
    private func adjust(_ delta: Double) {
        guard enabled else { return }
        let next = quantized(current + delta * step)
        draft = next
        commit(next)
    }
}
