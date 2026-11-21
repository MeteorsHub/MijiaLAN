import MijiaCore
import MijiaLAN
import SwiftUI

/// Both emitters share the normal controller/cache but own separate stable slider and draft state.
struct Ceiling20LightControls: View {
    let controller: DeviceController
    let snapshot: DeviceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach([2, 200], id: \.self) { siid in
                if snapshot.capabilities.contains(where: { $0.siid == siid && $0.name == "on" }) {
                    LightChannelControls(controller: controller, snapshot: snapshot, siid: siid)
                }
            }
        }
    }
}

private struct LightChannelControls: View {
    let controller: DeviceController
    let snapshot: DeviceSnapshot
    let siid: Int
    private var capabilities: [DeviceCapability] { snapshot.capabilities.filter { $0.siid == siid } }
    private var brightness: DeviceCapability? { capabilities.first { $0.name == "brightness" && $0.control == .number } }
    private var temperature: DeviceCapability? {
        siid == 2 ? capabilities.first { $0.name == "color-temperature" && $0.control == .number } : nil
    }
    private var rgb: DeviceCapability? {
        siid == 200 ? capabilities.first { $0.iid == 204 && $0.name == "color" && $0.unit == "rgb" && $0.writable } : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(siid == 2 ? L10n.tr("主灯", "Main Light") : L10n.tr("副灯", "Ambient Light"))
                .font(.callout.weight(.semibold))
            if let power = capabilities.first(where: { $0.name == "on" }) {
                CapabilityControls(controller: controller, snapshot: snapshot,
                    excluding: Set(snapshot.controls.map(\.id)).subtracting([power.id]))
            }
            if let brightness {
                LampControl(controller: controller, snapshot: snapshot, brightness: brightness, siid: siid)
            }
            if let temperature {
                LampColorTemperatureControl(controller: controller, snapshot: snapshot, capability: temperature)
            }
            if let rgb {
                AmbientColorPalette(controller: controller, snapshot: snapshot, capability: rgb)
                    .id(snapshot.id)
            }
            let primary = Set([brightness?.id, temperature?.id, rgb?.id, capabilities.first { $0.name == "on" }?.id].compactMap { $0 })
            let remaining = Set(capabilities.filter { siid != 200 || $0.name != "color-temperature" }.map(\.id)).subtracting(primary)
            CapabilityControls(controller: controller, snapshot: snapshot,
                excluding: Set(snapshot.controls.map(\.id)).subtracting(remaining))
            if siid == 2 {
                Text(L10n.tr("日光和夜灯是主灯的两种模式；副灯独立控制。", "Day and moonlight are modes of the main light; the ambient light is independent."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
