import MijiaCore

/// MIoT per-property status codes. These describe the requested property, not device reachability.
public enum MiotPropertyStatus {
    public static func description(_ code: Int?) -> String {
        switch code {
        case -4001: L10n.tr("属性不可读（-4001）", "Property is not readable (-4001).")
        case -4002: L10n.tr("属性不可写（-4002）", "Property is not writable (-4002).")
        case -4003: L10n.tr("属性、方法或事件不存在（-4003）", "Property, action or event does not exist (-4003).")
        case -4004: L10n.tr("设备内部错误（-4004）", "Device internal error (-4004).")
        case -4005: L10n.tr("属性值错误（-4005）", "Invalid property value (-4005).")
        case -4006: L10n.tr("方法输入参数错误（-4006）", "Invalid action input parameters (-4006).")
        case -4007: L10n.tr("设备 DID 错误（-4007）", "Invalid device DID (-4007).")
        case .some(let code): L10n.tr("设备返回错误（\(code)）", "Device error (\(code)).")
        case nil: L10n.tr("设备响应缺少返回码或读数", "The response is missing a result code or reading.")
        }
    }
}
