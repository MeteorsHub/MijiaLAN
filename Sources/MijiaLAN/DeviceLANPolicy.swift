import MijiaCore

/// Exact-model restriction based on order-dependent field replies and an unresolved control incident.
/// Connectivity (hello/miIO.info) is independent of property protocol trust.
public enum DeviceLANPolicy {
    public static func allowsPropertyRequests(for model: String) -> Bool {
        model != "dooya.motor.dc1545"
    }

    public static func restriction(for model: String) -> String? {
        guard !allowsPropertyRequests(for: model) else { return nil }
        return L10n.tr("通用读写及桥接控制暂停；可在此设备详情中启用独立调度的日常控制", "Generic reads/writes and bridge control are paused. Daily App control can be enabled in this device’s details.")
    }

    public static var unverifiedReadingsTitle: String {
        L10n.tr("局域网读数未验证", "LAN Readings Unverified")
    }
}
