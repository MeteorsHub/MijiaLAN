import Foundation

// MARK: - Mac-state Automation Rules (#59)

/// What wakes an automation rule. Every rule is off until the user creates one, and the settings
/// screen starts empty.
///
/// Sleep/lock/display-sleep signals are grouped into `away`, and unlock/wake/display-wake into
/// `back`, because macOS posts several notifications for one lid close. `AutomationPolicy` then
/// coalesces bursts of the same group.
public enum AutomationTrigger: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Screen locked, lid closed, or the Mac/display went to sleep.
    case away
    /// Screen unlocked, or the Mac/display woke up. No time-of-day condition yet.
    case back
    case externalDisplayConnected
    case externalDisplayDisconnected

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .away:
            return L10n.tr("离开（锁屏 / 合盖 / 睡眠）", "Away (lock, lid, sleep)")
        case .back:
            return L10n.tr("回来（解锁 / 唤醒）", "Back (unlock, wake)")
        case .externalDisplayConnected:
            return L10n.tr("接入外接显示器", "External display connected")
        case .externalDisplayDisconnected:
            return L10n.tr("断开外接显示器", "External display disconnected")
        }
    }

    public var symbolName: String {
        switch self {
        case .away: return "lock.fill"
        case .back: return "lock.open.fill"
        case .externalDisplayConnected: return "display"
        case .externalDisplayDisconnected: return "rectangle.on.rectangle"
        }
    }
}

/// What a rule does. The three kinds mirror the issue: a built-in quick action, a group of devices
/// with one target state, or an existing Home Assistant scene.
public enum AutomationAction: Equatable, Sendable {
    case quickAction(QuickAction)
    case devices(ids: [String], isOn: Bool)
    case scene(sceneId: String)

    /// Intents handed to `HomeStore.runAutomation`. Quick actions are executed through their own
    /// store path because they aggregate devices dynamically.
    public func intents() -> [DeviceIntent] {
        switch self {
        case .quickAction:
            return []
        case .devices(let ids, let isOn):
            return ids.map { DeviceIntent(targetId: $0, operation: .power(isOn)) }
        case .scene(let sceneId):
            return [DeviceIntent(targetId: sceneId, operation: .activateScene)]
        }
    }

    public func summary(devices: [SmartDevice], scenes: [HomeScene]) -> String {
        switch self {
        case .quickAction(let action):
            return L10n.format("快捷动作：%@", "Quick action: %@", action.title)
        case .devices(let ids, let isOn):
            let names = ids.compactMap { id in devices.first(where: { $0.id == id })?.name }
            let verb = isOn ? L10n.tr("打开", "Turn on") : L10n.tr("关闭", "Turn off")
            let list: String
            if names.isEmpty {
                list = L10n.format("%@ 台设备", "%@ device(s)", String(ids.count))
            } else {
                let separator = L10n.tr("、", ", ")
                let shown = names.prefix(3).joined(separator: separator)
                let remainder = names.count - min(names.count, 3)
                // Chinese phrasing counts all devices ("A、B 等 6 台"), English counts the rest.
                let count = L10n.isEnglish ? remainder : names.count
                list = remainder > 0
                    ? L10n.format("%@ 等 %@ 台", "%@ and %@ more", shown, String(count))
                    : shown
            }
            // Whole sentence, so a zh-Hant/other table can reorder verb and list.
            return L10n.format("%@%@", "%@ %@", verb, list)
        case .scene(let sceneId):
            let name = scenes.first(where: { $0.id == sceneId })?.name ?? sceneId
            return L10n.format("场景：%@", "Scene: %@", name)
        }
    }
}

extension AutomationAction: Codable {
    private enum Kind: String, Codable {
        case quickAction, devices, scene
    }

    private enum CodingKeys: String, CodingKey {
        case kind, quickAction, deviceIds, isOn, sceneId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .quickAction:
            let raw = try container.decode(String.self, forKey: .quickAction)
            guard let action = QuickAction(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .quickAction,
                    in: container,
                    debugDescription: "Unknown quick action \(raw)"
                )
            }
            self = .quickAction(action)
        case .devices:
            self = .devices(
                ids: try container.decode([String].self, forKey: .deviceIds),
                isOn: try container.decode(Bool.self, forKey: .isOn)
            )
        case .scene:
            self = .scene(sceneId: try container.decode(String.self, forKey: .sceneId))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .quickAction(let action):
            try container.encode(Kind.quickAction, forKey: .kind)
            try container.encode(action.rawValue, forKey: .quickAction)
        case .devices(let ids, let isOn):
            try container.encode(Kind.devices, forKey: .kind)
            try container.encode(ids, forKey: .deviceIds)
            try container.encode(isOn, forKey: .isOn)
        case .scene(let sceneId):
            try container.encode(Kind.scene, forKey: .kind)
            try container.encode(sceneId, forKey: .sceneId)
        }
    }
}

public struct AutomationRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var isEnabled: Bool
    public var trigger: AutomationTrigger
    public var action: AutomationAction

    public init(
        id: UUID = UUID(),
        trigger: AutomationTrigger,
        action: AutomationAction,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.trigger = trigger
        self.action = action
        self.isEnabled = isEnabled
    }
}

/// Persists the rule list in `UserDefaults`; an absent key means “no automation”, which is the
/// default and also how the settings screen renders its empty state.
public struct AutomationRuleStore {
    public static let storageKey = "automation_rules_v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [AutomationRule] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        if let rules = try? JSONDecoder().decode([AutomationRule].self, from: data) {
            return rules
        }
        // A single unreadable entry (older/renamed trigger, corrupted write) must not silently drop
        // every other rule; decode element by element and keep what still parses.
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let raw = object as? [Any] else { return [] }
        let decoder = JSONDecoder()
        return raw.compactMap { element in
            guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? decoder.decode(AutomationRule.self, from: elementData)
        }
    }

    public func save(_ rules: [AutomationRule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// One-minute coalescing for trigger bursts (lock often arrives together with display sleep).
/// Timestamps are persisted so relaunching the app right after unlocking cannot replay a rule.
public struct AutomationTriggerDeduper {
    public static let storageKey = "automation_trigger_last_fired_v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func lastFireDate(for trigger: AutomationTrigger) -> Date? {
        guard let stamps = defaults.dictionary(forKey: Self.storageKey),
              let stored = stamps[trigger.rawValue] else {
            return nil
        }
        let seconds = (stored as? Double) ?? (stored as? NSNumber)?.doubleValue
        guard let seconds else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Returns true and records `now` when this trigger may run. A backwards clock jump is treated
    /// as a fresh start instead of blocking the rule until the clock catches up.
    public func shouldFire(_ trigger: AutomationTrigger, at now: Date = Date()) -> Bool {
        if let last = lastFireDate(for: trigger) {
            let elapsed = now.timeIntervalSince(last)
            if elapsed >= 0, elapsed < AutomationPolicy.triggerCooldown {
                return false
            }
        }
        var stamps = defaults.dictionary(forKey: Self.storageKey) ?? [:]
        stamps[trigger.rawValue] = now.timeIntervalSince1970
        defaults.set(stamps, forKey: Self.storageKey)
        return true
    }
}

public enum AutomationMatcher {
    /// All enabled rules for this trigger. The deduper runs once per trigger, so several rules can
    /// share one wake event (for example lock → lights off and lock → sleep climate off).
    public static func rules(for trigger: AutomationTrigger, in rules: [AutomationRule]) -> [AutomationRule] {
        rules.filter { $0.isEnabled && $0.trigger == trigger }
    }
}

public enum AutomationPolicy {
    public static let triggerCooldown: TimeInterval = 60
    /// Automation usually fires while the panel is closed; keep the undo banner long enough to be
    /// found after unlocking instead of expiring unseen in ten seconds.
    public static let undoWindow: TimeInterval = 5 * 60
}
