import Foundation

/// Robot vacuums share MIoT action names but number their status values freely: 2 is Sweeping on a Roborock C1 and
/// Paused on an ijai V19. The value-list descriptions are what the specs have in common, so the status is read
/// through them, as homebridge-miot's robot cleaner does (MIT, `2186f61`).
public enum VacuumStatus {
    /// Actions sent as they are, by service, and only when the spec gives them no input: room, zone and mop-wash
    /// actions take vendor-specific arguments.
    static let actions: [String: Set<String>] = [
        "vacuum": ["start-sweep", "start-only-sweep", "start-sweep-mop", "start-mop", "stop-sweeping", "pause-sweeping", "start-charge"],
        "battery": ["start-charge"],
    ]
    static let startActions: Set<String> = ["start-sweep", "start-only-sweep", "start-sweep-mop", "start-mop"]

    public static func isSupported(_ action: DeviceSchema.Action, service: String) -> Bool {
        action.inputs.isEmpty && actions[service]?.contains(action.name) == true
    }

    /// Sweeping, mopping or both, including the zone, room and edge variants some specs list.
    public static func isCleaning(_ description: String) -> Bool {
        let d = normalized(description)
        return (d.contains("sweep") && !d.contains("summon")) || ["mopping", "cleaning", "remoteclean", "twocleaning"].contains(d)
    }

    /// On the way to the dock, or charging there.
    public static func isDocking(_ description: String) -> Bool {
        let d = normalized(description)
        return (d.contains("charg") || d.contains("dock")) && !["error", "pause", "exit"].contains(where: d.contains)
    }

    /// Neither cleaning nor about to: idle, paused, asleep, updating, off, or stopped by an error.
    static func isResting(_ description: String) -> Bool {
        let d = normalized(description)
        return ["idle", "pause", "sleep", "dormant", "standby", "hibernate", "updat", "upgrad", "error", "fault", "shutdown"].contains(where: d.contains)
            || ["off", "none", "null"].contains(d)
    }

    /// Whether the status read after `action` shows the robot following it. A start also counts when the robot
    /// moved on to a step before cleaning, such as building a map or washing its mop.
    static func confirms(_ action: String, status: String?, before: String?) -> Bool {
        guard let status else { return false }
        if startActions.contains(action) {
            return isCleaning(status) || (status != before && !isResting(status) && !isDocking(status))
        }
        switch action {
        case "start-charge": return isDocking(status)
        case "stop-sweeping", "pause-sweeping", "pause": return !isCleaning(status)
        default: return false
        }
    }

    static func normalized(_ description: String) -> String {
        description.lowercased().filter(\.isLetter)
    }
}
