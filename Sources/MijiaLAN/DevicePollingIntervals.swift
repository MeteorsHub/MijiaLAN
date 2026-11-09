import Foundation

/// Target start-to-start cadence for ordinary device reads, independent of bridge snapshots.
public struct DevicePollingIntervals: Equatable, Sendable {
    public static let allowedSeconds = 1...3600
    public static let foregroundKey = "devices.polling.foregroundSeconds"
    public static let backgroundKey = "devices.polling.backgroundSeconds"
    public let foregroundSeconds: Int
    public let backgroundSeconds: Int

    public init(foregroundSeconds: Int = 10, backgroundSeconds: Int = 30) {
        self.foregroundSeconds = min(max(foregroundSeconds, Self.allowedSeconds.lowerBound), Self.allowedSeconds.upperBound)
        self.backgroundSeconds = min(max(backgroundSeconds, Self.allowedSeconds.lowerBound), Self.allowedSeconds.upperBound)
    }

    /// Older saves have no provenance: a stored 5 may be an explicit choice. Preserve every valid
    /// stored value; only absent/invalid settings receive the new 10/30 defaults.
    public static func load(from defaults: UserDefaults) -> Self {
        func seconds(_ key: String, fallback: Int) -> Int {
            guard let value = defaults.object(forKey: key) as? Int, allowedSeconds.contains(value) else { return fallback }
            return value
        }
        return Self(foregroundSeconds: seconds(foregroundKey, fallback: 10), backgroundSeconds: seconds(backgroundKey, fallback: 30))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(foregroundSeconds, forKey: Self.foregroundKey)
        defaults.set(backgroundSeconds, forKey: Self.backgroundKey)
    }

    func interval(panelVisible: Bool) -> Duration { .seconds(panelVisible ? foregroundSeconds : backgroundSeconds) }
}
