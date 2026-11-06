import MijiaCore

/// Exact-model restriction based on order-dependent field replies and an unresolved control incident.
/// Connectivity (hello/miIO.info) is independent of property protocol trust.
public enum DeviceLANPolicy {
    public static func allowsPropertyRequests(for model: String) -> Bool {
        model != "dooya.motor.dc1545"
    }

    public static func restriction(for model: String) -> String? {
        guard !allowsPropertyRequests(for: model) else { return nil }
        return L10n.tr("局域网读数未验证；已暂停属性读取、写入和桥接控制", "LAN readings are unverified. Property reads, writes and bridge control are paused.")
    }

    public static var unverifiedReadingsTitle: String {
        L10n.tr("局域网读数未验证", "LAN Readings Unverified")
    }
}
