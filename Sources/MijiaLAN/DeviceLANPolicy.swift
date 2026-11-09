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
        return L10n.tr("通用读写及桥接控制暂停；App 设备详情通过专用校验与调度提供状态和控制", "Generic reads/writes and bridge control are paused. App device details provide readings and controls through the verified curtain scheduler.")
    }

    public static var unverifiedReadingsTitle: String {
        L10n.tr("局域网读数未验证", "LAN Readings Unverified")
    }
}
