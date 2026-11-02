import Foundation
import OSLog

/// A hidden panel still has a status item and a HomeKit server to service.
/// SwiftUI's Settings-only scene must not make that process auto-terminable.
@MainActor
final class BackgroundApplicationLifetime {
    private let reason = "MijiaLAN menu-bar service and HomeKit bridge"
    private let logger = Logger(subsystem: "com.mijialan.MijiaLAN", category: "ApplicationLifetime")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        // The counter API only takes effect after support is registered. Our
        // bundle has no NSSupportsAutomaticTermination Info.plist opt-in.
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = true
        ProcessInfo.processInfo.disableAutomaticTermination(reason)
        // A live bridge needs a normal shutdown rather than a quiet fast kill.
        ProcessInfo.processInfo.disableSuddenTermination()
        logger.notice("Background service started; automatic and sudden termination disabled")
    }

    func stop() {
        guard started else { return }
        started = false
        logger.notice("Application termination requested; ending background service lifetime")
        ProcessInfo.processInfo.enableAutomaticTermination(reason)
        ProcessInfo.processInfo.enableSuddenTermination()
    }
}
