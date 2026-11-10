import Foundation

/// What the user is doing right now. Mi cloud polls slower or stops based on it (#26).
public struct PollingContext: Equatable, Sendable, CustomStringConvertible {
    /// The control center panel is on screen.
    public var panelVisible: Bool
    /// False while the Mac or its display sleeps, the screen is locked, or another user is logged in.
    public var systemActive: Bool
    /// macOS Low Power Mode is on.
    public var lowPower: Bool

    public init(panelVisible: Bool = false, systemActive: Bool = true, lowPower: Bool = false) {
        self.panelVisible = panelVisible
        self.systemActive = systemActive
        self.lowPower = lowPower
    }

    public var description: String {
        if !systemActive { return "paused (asleep or locked)" }
        return (panelVisible ? "panel open" : "panel closed") + (lowPower ? ", low power" : "")
    }
}

/// How often to poll for device state (#26).
///
/// | Situation | Interval |
/// | --- | --- |
/// | Panel open | 6 s |
/// | Panel closed (menu bar text, reminders) | 60 s |
/// | Panel closed in Low Power Mode | 180 s |
/// | Asleep, display asleep, locked | no polling; polls once right after |
public enum PollingPolicy {
    public static let panelOpenInterval: Duration = .seconds(6)
    public static let panelClosedInterval: Duration = .seconds(60)
    /// Low Power Mode stretches the panel-closed interval by this factor. An open panel keeps 6 s:
    /// someone is looking, and it is open only briefly.
    public static let lowPowerFactor = 3

    /// - Returns: the wait between polls, or nil to stop polling until the context changes.
    public static func interval(
        for context: PollingContext,
        panelOpen: Duration = panelOpenInterval,
        panelClosed: Duration = panelClosedInterval
    ) -> Duration? {
        guard context.systemActive else { return nil }
        if context.panelVisible { return panelOpen }
        return context.lowPower ? panelClosed * lowPowerFactor : panelClosed
    }
}
