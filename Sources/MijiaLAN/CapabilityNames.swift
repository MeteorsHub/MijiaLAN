import MijiaCore
import Foundation

/// Shared vocabulary; names are keyed by meaning, never by the order returned by a device.
public enum CapabilityNames {
    public static func property(service: String, name: String, fallback: String) -> String {
        let serviceNames = ["indicator-light": L10n.tr("指示灯", "Indicator Light"), "alarm": L10n.tr("提示音", "Sound"), "charging-protection": L10n.tr("充电保护", "Charging Protection"),
            "charge-prt-ext": L10n.tr("扩展充电保护", "Extended Charging Protection"), "max-power-limit": L10n.tr("功率限制", "Power Limit"), "power-limit-ext": L10n.tr("扩展功率限制", "Extended Power Limit"),
            "quick-countdown": L10n.tr("关机倒计时", "Power-off Countdown"), "over-use-ele-alert": L10n.tr("过量用电提醒", "Energy Usage Alert"), "cycle": L10n.tr("循环计划", "Cycle Schedule")]
        if name == "on" { return serviceNames[service] ?? L10n.tr("电源", "Power") }
        if name == "temperature", ["switch", "on-off-count"].contains(service) { return L10n.tr("设备温度", "Device Temperature") }
        if name == "mode", service == "indicator-light" { return L10n.tr("指示灯勿扰模式", "Indicator Do Not Disturb") }
        if ["power", "power-ext", "protect-time", "duration", "start-time", "end-time"].contains(name), let prefix = serviceNames[service] {
            let suffix = ["power": L10n.tr("功率阈值", "Power Threshold"), "power-ext": L10n.tr("功率阈值", "Power Threshold"), "protect-time": L10n.tr("保护时长", "Protection Duration"), "duration": L10n.tr("时长", "Duration"), "start-time": L10n.tr("开始时间", "Start Time"), "end-time": L10n.tr("结束时间", "End Time")][name]!
            return L10n.isEnglish ? prefix + " " + suffix : prefix + suffix
        }
        let names = [
            "fan-level": L10n.tr("风速挡位", "Fan Level"), "speed-level": L10n.tr("风速", "Fan Speed"), "mode": L10n.tr("模式", "Mode"), "cook-mode": L10n.tr("菜单", "Menu"),
            "horizontal-swing": L10n.tr("左右摇头", "Horizontal Oscillation"), "horizontal-angle": L10n.tr("左右摇头角度", "Horizontal Angle"), "vertical-swing": L10n.tr("上下摇头", "Vertical Oscillation"),
            "vertical-angle": L10n.tr("上下摇头角度", "Vertical Angle"), "horizontal-swing-included-angle": L10n.tr("左右摇头角度", "Horizontal Angle"),
            "vertical-swing-included-angle": L10n.tr("上下摇头角度", "Vertical Angle"), "alarm": L10n.tr("提示音", "Sound"), "off-delay-time": L10n.tr("关机定时", "Sleep Timer"), "physical-controls-locked": L10n.tr("童锁", "Child Lock"),
            "temperature": L10n.tr("温度", "Temperature"), "relative-humidity": L10n.tr("湿度", "Humidity"), "swing-all": L10n.tr("循环摇头", "Circulating Oscillation"), "back-to-center": L10n.tr("回正", "Return to Center"),
            "off-to-center": L10n.tr("关机回正", "Center on Power Off"), "brightness": service == "light" ? L10n.tr("亮度", "Brightness") : L10n.tr("屏幕亮度", "Display Brightness"),
            "color-temperature": L10n.tr("色温", "Color Temperature"), "target-temperature": L10n.tr("设定温度", "Target Temperature"), "electric-power": L10n.tr("功率", "Power"),
            "power-consumption": L10n.tr("累计电量", "Energy Used"), "pm2.5-density": "PM2.5", "filter-life-level": L10n.tr("滤芯寿命", "Filter Life"),
            "filter-used-time": L10n.tr("滤芯已用时间", "Filter Usage"), "filter-left-time": L10n.tr("滤芯剩余时间", "Filter Time Remaining"), "favorite-level": L10n.tr("最爱档位", "Favorite Level"),
            "motor-speed": L10n.tr("电机转速", "Motor Speed"), "fault": L10n.tr("故障", "Fault"), "status": L10n.tr("运行状态", "Operating Status"), "target-time": L10n.tr("烹饪时间", "Cooking Time"),
            "left-time": L10n.tr("剩余时间", "Time Remaining"), "auto-keep-warm": L10n.tr("自动保温", "Auto Keep Warm"), "current-keep-warm-time": L10n.tr("已保温时间", "Keep-warm Time Elapsed"),
            "keep-warm-time": L10n.tr("保温时间", "Keep-warm Duration"), "target-cooking-measure": L10n.tr("份量", "Serving Size"), "texture": L10n.tr("口感", "Texture"),
            "reservation-left-time": L10n.tr("预约时间", "Scheduled Delay"), "cooking-weight": L10n.tr("食材重量", "Ingredient Weight"), "turn-pot-config": L10n.tr("翻面提醒", "Turn-over Reminder"),
            "default-power-on-state": L10n.tr("上电状态", "Power-on Behavior"), "countdown": L10n.tr("倒计时", "Countdown"), "countdown-time": L10n.tr("倒计时时长", "Countdown Duration"),
            "countdown-left-time": L10n.tr("倒计时剩余", "Countdown Remaining"), "countdown-on": L10n.tr("倒计时开关", "Countdown Enabled"), "charge-protect": L10n.tr("充电保护", "Charging Protection"),
            "power-limit": L10n.tr("功率限制", "Power Limit"), "power": L10n.tr("功率", "Power"), "time": L10n.tr("时长", "Duration"), "on-off-count": L10n.tr("开关次数", "Power Cycles"),
            "menu-id": L10n.tr("运行菜单编号", "Active Menu ID"), "current-keep-warm": L10n.tr("当前保温状态", "Keep-warm Status"), "total-time": L10n.tr("总时间", "Total Time"), "cook-left-time": L10n.tr("烹饪剩余时间", "Cooking Time Remaining"),
            "pre-left-time": L10n.tr("预约剩余时间", "Scheduled Delay Remaining"), "no-pan": L10n.tr("锅体状态", "Pot Status"), "pot-status": L10n.tr("提壶状态", "Kettle Position"),
        ]
        return names[name] ?? fallback
    }
    public static func action(_ name: String, fallback: String) -> String {
        ["start-cook": L10n.tr("开始烹饪", "Start Cooking"), "cancel-cooking": L10n.tr("停止烹饪", "Stop Cooking"), "pause": L10n.tr("暂停", "Pause"), "resume-cook": L10n.tr("继续", "Resume")][name] ?? fallback
    }
    public static func option(_ text: String) -> String {
        // Some vendor schemas provide only Chinese descriptions, including in
        // the nominally English field. Keep their enum values unchanged.
        let vendorLabels = [
            "官方模式": "Preset Mode", "官方食谱": "Preset Recipe", "自定义食谱": "Custom Recipe",
            "煮茶": "Brew Tea", "果茶": "Fruit Tea", "银耳": "Tremella Soup", "炖汤": "Soup",
            "烧水": "Boil Water", "保温": "Keep Warm", "火力": "Heat Level", "自定义": "Custom",
        ]
        if let english = vendorLabels[text] { return L10n.tr(text, english) }
        let names = ["auto": L10n.tr("自动", "Auto"), "sleep": L10n.tr("睡眠", "Sleep"), "favorite": L10n.tr("最爱", "Favorite"), "manual": L10n.tr("手动", "Manual"), "straightwind": L10n.tr("直吹风", "Direct Airflow"),
            "naturalwind": L10n.tr("自然风", "Natural Breeze"), "smart": L10n.tr("智能风", "Smart Airflow"), "off": L10n.tr("关闭", "Off"), "on": L10n.tr("开启", "On"), "idle": L10n.tr("待机", "Standby"),
            "busy": L10n.tr("运行中", "Running"), "running": L10n.tr("运行中", "Running"), "paused": L10n.tr("已暂停", "Paused"), "delay": L10n.tr("预约中", "Scheduled"), "aptrunning": L10n.tr("预约中", "Scheduled"),
            "keepwarm": L10n.tr("保温中", "Keeping Warm"), "cooking": L10n.tr("烹饪中", "Cooking"), "completed": L10n.tr("已完成", "Completed"), "cookfinish": L10n.tr("烹饪完成", "Cooking Complete"),
            "error": L10n.tr("故障", "Fault"), "fault": L10n.tr("故障", "Fault"), "updating": L10n.tr("升级中", "Updating"), "finecook": L10n.tr("精煮饭", "Fine Rice"), "quickcook": L10n.tr("快煮饭", "Quick Rice"),
            "congee": L10n.tr("煮粥", "Congee"), "custom": L10n.tr("自定义", "Custom"), "soymilk": L10n.tr("豆浆", "Soy Milk"), "ricepaste": L10n.tr("米糊", "Rice Paste"), "juice": L10n.tr("果汁", "Juice"),
            "soup": L10n.tr("煲汤", "Soup"), "milkshake": L10n.tr("奶昔", "Milkshake"), "cornjuice": L10n.tr("玉米汁", "Corn Juice"), "tea": L10n.tr("花茶", "Herbal Tea"), "fruittea": L10n.tr("水果茶", "Fruit Tea"),
            "silverfungus": L10n.tr("银耳", "Tremella Soup"), "water": L10n.tr("烧水", "Boil Water"), "warm": L10n.tr("保温", "Keep Warm"), "fries": L10n.tr("薯条", "Fries"), "wings": L10n.tr("鸡翅", "Wings"),
            "steak": L10n.tr("牛排", "Steak"), "lamb": L10n.tr("羊排", "Lamb Chops"), "pork": L10n.tr("猪肉", "Pork"), "fish": L10n.tr("鱼", "Fish"), "sweetpotato": L10n.tr("红薯", "Sweet Potato"),
            "cake": L10n.tr("蛋糕", "Cake"), "tart": L10n.tr("蛋挞", "Egg Tart"), "defrost": L10n.tr("解冻", "Defrost"), "driedfruit": L10n.tr("果干", "Dried Fruit"), "yogurt": L10n.tr("酸奶", "Yogurt"),
            "cool": L10n.tr("制冷", "Cool"), "heat": L10n.tr("制热", "Heat"), "dry": L10n.tr("除湿", "Dry"), "fan": L10n.tr("送风", "Fan"), "low": L10n.tr("低", "Low"), "medium": L10n.tr("中", "Medium"), "high": L10n.tr("高", "High"),
            "nofaults": L10n.tr("无故障", "No Faults"), "none": L10n.tr("无", "None"), "crispyroast": L10n.tr("脆烤", "Crispy Roast"), "tenderroast": L10n.tr("嫩烤", "Tender Roast"), "degrease": L10n.tr("脱脂", "Degrease")]
        let key = text.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
        return names[key] ?? text
    }
    public static func unit(_ unit: String?, name: String) -> String {
        switch unit {
        case "percentage": return "%"
        case "celsius": return "℃"
        case "kelvin": return " K"
        case "minutes": return L10n.tr(" 分钟", " min")
        case "seconds": return L10n.tr(" 秒", " s")
        case "hours": return L10n.tr(" 小时", " h")
        case "days": return L10n.tr(" 天", " d")
        case "watt": return " W"
        case "arcdegrees": return "°"
        case "micrograms-per-cubic-meter": return " µg/m³"
        case "grams": return " g"
        case "none", nil: return ""
        default: return " " + (unit ?? "")
        }
    }

    /// These reasons are persisted with imported devices; translate at display
    /// time so changing the app language never rewrites the saved device list.
    public static func importReason(_ reason: String) -> String {
        switch reason {
        case "蓝牙设备，局域网协议够不到":
            L10n.tr("蓝牙设备，局域网协议够不到", "Bluetooth devices cannot be reached with the LAN protocol.")
        case "云端灯组":
            L10n.tr("云端灯组", "Cloud-based light group.")
        case "网关子设备（Zigbee / 蓝牙 Mesh）":
            L10n.tr("网关子设备（Zigbee / 蓝牙 Mesh）", "Gateway subdevice (Zigbee or Bluetooth Mesh).")
        case "云端没有给出局域网 token":
            L10n.tr("云端没有给出局域网 token", "The cloud did not provide a LAN token.")
        case "云端没有局域网 IP（设备可能离线）":
            L10n.tr("云端没有局域网 IP（设备可能离线）", "No LAN IP was provided. The device may be offline.")
        default: reason
        }
    }

    /// Capability limitations are stable internal identifiers shared by the
    /// controller, compatibility UI and developer reports.
    public static func limitation(_ reason: String) -> String {
        switch reason {
        case "规格存在，尚无经过确认的旧 miIO 映射":
            L10n.tr("规格存在，尚无经过确认的旧 miIO 映射", "The specification exists, but its legacy miIO mapping has not been verified.")
        case "缺少可验证的参数定义，暂不写入":
            L10n.tr("缺少可验证的参数定义，暂不写入", "Writes are disabled because the parameter definition has not been verified.")
        case "厂商参数或停止语义尚未确认，暂不写入":
            L10n.tr("厂商参数或停止语义尚未确认，暂不写入", "Writes are disabled until the vendor parameters or stop behavior are verified.")
        case "复合循环计划尚未确认，暂不启用或修改":
            L10n.tr("复合循环计划尚未确认，暂不启用或修改", "Complex cycle schedules have not been verified and cannot be enabled or changed yet.")
        case "维护操作或厂商复合参数，不作为日常控制":
            L10n.tr("维护操作或厂商复合参数，不作为日常控制", "Maintenance operations and vendor-specific compound parameters are not exposed as daily controls.")
        default: reason
        }
    }
}
