import MijiaCore

/// Route this model through its single scheduled driver, never a parallel generic polling path.
public enum DeviceLANPolicy {
    public static func allowsPropertyRequests(for model: String) -> Bool {
        model != "dooya.motor.dc1545"
    }

    /// Product capabilities exclude the getter implicated by repeated-read field trials.
    /// Explicit CLI attribute probes use their own whitelist and never this product catalog.
    public static func allowsCapability(model: String, kind: DeviceCapability.Kind, siid: Int, iid: Int, inputs: [Int] = [], outputs: [Int] = []) -> Bool {
        guard model == CurtainValidationSession.model, siid == 2 else { return true }
        return kind == .property ? iid != 5 : !inputs.contains(5) && !outputs.contains(5)
    }

    public static func allowsAutomaticDiscovery(for devices: [LocalDevice]) -> Bool {
        !devices.contains { $0.model == CurtainValidationSession.model }
    }

    public static func restriction(for model: String) -> String? {
        guard !allowsPropertyRequests(for: model) else { return nil }
        return L10n.tr("此设备由统一卷帘调度提供状态和控制，通用属性入口不重复通信", "This device uses the shared curtain driver for readings and controls; generic property paths do not duplicate communication.")
    }

    public static var unverifiedReadingsTitle: String {
        L10n.tr("状态由卷帘控制页更新", "State Updated by Curtain Driver")
    }
}
