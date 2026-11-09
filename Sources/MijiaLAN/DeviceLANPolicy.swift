import MijiaCore

/// Exact-model restriction based on order-dependent field replies and an unresolved control incident.
/// Connectivity (hello/miIO.info) is independent of property protocol trust.
public enum DeviceLANPolicy {
    public static func allowsPropertyRequests(for model: String) -> Bool {
        model != "dooya.motor.dc1545"
    }

    public static func allowsAutomaticDiscovery(for devices: [LocalDevice]) -> Bool {
        !devices.contains { $0.model == CurtainValidationSession.model }
    }

    public static func restriction(for model: String) -> String? {
        guard !allowsPropertyRequests(for: model) else { return nil }
        return L10n.tr("通用读写及桥接控制暂停；App 使用专用校验与调度读取状态，可在设备详情启用日常控制", "Generic reads/writes and bridge control are paused. The App reads through its verified curtain scheduler; daily controls can be enabled in device details.")
    }

    public static var unverifiedReadingsTitle: String {
        L10n.tr("局域网读数未验证", "LAN Readings Unverified")
    }
}
