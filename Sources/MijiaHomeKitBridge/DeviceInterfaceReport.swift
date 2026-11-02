import Foundation
import MijiaCore
import MijiaLAN

public enum DeviceInterfaceReport {
    /// Generated from the same catalog and Home plan used at runtime; contains no device credentials.
    @MainActor public static func markdown() -> String {
        let devices = DeviceSchema.bundledModels.enumerated().map { index, model in
            LocalDevice(did: String(index + 100), name: model, model: model, host: "", token: "")
        }
        let config = LocalHomeConfig(devices: devices)
        let api = LANMiotAPI(config: { config })
        let controller = DeviceController(api: api, config: { config })
        let home = controller.synthesizedHome()
        var lines = ["# 设备接口矩阵", "", "由 `mijia-lan matrix` 根据运行时能力目录生成。10 个型号；cuco.plug.v3 的两台设备复用同一适配。", "",
            "规格和协议测试不能证明固件已支持局域网接口。下列实机状态统一保持待验证；本机读取证据另见验收报告。待确认字段不发送猜测命令。", "",
            "MIoT 编号以服务和属性／动作定位；数值是设备原始单位。动作参数严格依规格 in 顺序，out 定义保留。Home 无适合控件的读数留在 Mac。", ""]
        for device in devices {
            guard let s = controller.snapshots[device.did] else { continue }
            var ids: [String: UInt64] = [:]
            let plan = CapabilityHomeKitMapper.plan(snapshot: s, legacyDevice: home.devices.first { $0.id == s.id }, names: [:], identifiers: &ids)
            lines += ["## \(device.model)", "", "规格：`\(s.schema.type)`。Home 服务 \(plan.services.count) 个。", "",
                "| 接口 | 类型／权限／范围 | 实际协议与参数 | 状态反馈 | Mac | Home | 验证状态 |",
                "|---|---|---|---|---|---|---|"]
            for c in s.capabilities {
                let bounds = c.range.map { $0.map { String($0) }.joined(separator: " / ") } ?? ""
                let options = c.options.map { "\($0.value)=\($0.title)" }.joined(separator: "、")
                let access = (c.readable ? "R" : "") + (c.writable ? "W" : "") + (c.prepared ? " 待应用" : "")
                let protocolText: String
                if c.kind == .action {
                    protocolText = "action \(c.siid).\(c.iid), in=\(c.inputs), out=\(c.outputs)"
                } else if let legacy = LegacyMiioProfile.forModel(device.model) {
                    if let property = legacy.property(siid: c.siid, piid: c.iid) {
                        let argument: String = switch property.format {
                        case .onOff: "on/off 字符串"
                        case .number: "数字"
                        case .values(let table): table.sorted { $0.value < $1.value }.map { "\($0.value)→\($0.key)" }.joined(separator: ",")
                        }
                        protocolText = "get_prop [\(property.name)]; " + (property.setter.map { "\($0) [\(argument)\(property.setterSuffix.isEmpty ? "" : ", " + property.setterSuffix.map(\.compactJSONString).joined(separator: ", "))]" } ?? "只读")
                    } else { protocolText = "旧 miIO 映射待确认" }
                } else if c.prepared && !c.writable && !c.readable {
                    protocolText = "仅作为 action in 参数 \(c.siid).\(c.iid)，不读写属性"
                } else {
                    protocolText = ([c.readable ? "get_properties" : nil, c.writable ? "set_properties" : nil].compactMap { $0 }.joined(separator: " / ")) + " \(c.siid).\(c.iid)"
                }
                let homeMapped = plan.bindings.values.contains { binding in
                    switch binding {
                    case .property(let id, _), .option(let id, _), .adjust(let id, _), .action(let id): return id == c.id
                    case .legacy: return device.model == "lumi.acpartner.mcn02" && [2, 3].contains(c.siid)
                    default: return false
                    }
                }
                let feedback = c.prepared ? "待选值独立保存；运行后读实际状态" : c.readable ? "逐属性返回码＋回读＋时间" : c.kind == .action ? "动作返回码＋运行状态确认" : "接受回执；完成状态待确认"
                let mac = [DeviceCapability.Control.toggle: "开关", .number: "精确输入", .choice: "选项", .button: "动作按钮", .reading: "实际读数", .unsupported: "待确认清单"][c.control] ?? ""
                let home = homeMapped ? (c.control == .number ? "原生数值或预设＋增减" : c.control == .choice ? "具名选项开关" : c.kind == .action || c.control == .button ? "回弹按钮" : "原生服务／具名开关") : "Mac 保留"
                let evidence = c.limitation ?? (c.control == .unsupported ? "规格保留；未启用" : "规格已核对；自动化协议测试；实机待验证")
                lines.append("| \(c.id) \(clean(c.displayTitle)) | \(c.format) \(access) \(bounds) \(clean(options)) \(c.displayUnit) | \(clean(protocolText)) | \(feedback) | \(mac) | \(home) | \(clean(evidence)) |")
            }
            lines += ["", "不纳入日常控制：设备信息、恢复出厂、工程自检、固件／日志维护、未解析复合计划。原始规格完整保存在 `Sources/MijiaLAN/Resources/Specs/\(device.model).json`。", ""]
        }
        lines += ["## 兼容与证据边界", "", "- 空调 Home 当前温度来自目标温度占位，不属于实测室温。", "- Fan 速度读取 8.1；四挡预设写 2.2；0% 只关闭电源。", "- 配件标识和服务名称独立持久化；离线不会删除控件。", "- cuco 电量原始值的说明为 0.01 kWh；普通与扩展字段分别保留。未声明单位的厂商数值仍显示原始值。", "- 接受回执和状态确认分开记录。非幂等动作不会自动重发。", ""]
        return lines.joined(separator: "\n")
    }
    private static func clean(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "／").replacingOccurrences(of: "\n", with: " ") }
}
