import MijiaCore

/// Exact-model restriction based on order-dependent field replies and an unresolved control incident.
/// Connectivity (hello/miIO.info) is independent of property protocol trust.
public enum DeviceLANPolicy {
    public static func allowsPropertyRequests(for model: String) -> Bool {
        model != "dooya.motor.dc1545"
    }

    public static func restriction(for model: String) -> String? {
        guard !allowsPropertyRequests(for: model) else { return nil }
        return L10n.tr("常规局域网读写默认暂停，桥接控制未启用；小幅位置验证需单独选择设备", "Regular LAN reads/writes are paused by default; bridge control is disabled. Small position validation requires selecting a device.")
    }

    public static var unverifiedReadingsTitle: String {
        L10n.tr("局域网读数未验证", "LAN Readings Unverified")
    }
}
