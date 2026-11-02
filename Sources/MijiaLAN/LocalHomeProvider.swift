import Foundation
import MijiaCore

/// Builds MenuBarMijia's `MiCloudProvider` on top of the LAN API instead of the cloud client, wrapped in
/// `LANHomeProvider` for the climate controls MijiaCore does not read.
public enum LocalHomeProvider {
    /// `MiCloudProvider` wants a session before it starts polling. This one is never sent anywhere: the API
    /// factory ignores it and answers from the LAN.
    static let placeholderSession = MiSession(userId: "lan", cUserId: "lan", ssecurity: "", serviceToken: "", region: "cn")

    public static var specCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MijiaLAN", isDirectory: true)
    }

    /// LAN polls are cheap, and Apple Home should not lag the device by a minute: 3 s with the panel open, 5 s
    /// otherwise. Offline devices are re-probed every 4th poll.
    public static func make(
        api: LANMiotAPI,
        specSource: any MiotSpecSource = MiotSpecStore(cacheDirectory: specCacheDirectory),
        pollInterval: Duration = .seconds(3),
        closedPollInterval: Duration = .seconds(5)
    ) -> LANHomeProvider {
        let inner = MiCloudProvider(
            sessionLoader: { placeholderSession },
            apiFactory: { _ in api },
            specSource: specSource,
            pollInterval: pollInterval,
            closedPollInterval: closedPollInterval,
            deviceRefreshEveryPolls: 4,
            followUpDelay: .milliseconds(500),
            selectedHomeLoader: { nil }
        )
        return LANHomeProvider(inner: inner, api: api, specSource: specSource)
    }
}
