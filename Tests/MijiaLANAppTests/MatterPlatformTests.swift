import Foundation
import Testing
@testable import MijiaLANApp

@MainActor
struct MatterPlatformTests {
    @Test("Matter enabled and device selection persist without altering HomeKit settings")
    func independentPlatforms() throws {
        let suite = "matter-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "homekit_bridge_enabled")
        let matter = MatterBridgeController(defaults: defaults)
        #expect(!matter.isEnabled)
        matter.isEnabled = true
        matter.include("123", false)
        #expect(defaults.bool(forKey: "homekit_bridge_enabled"))
        let restored = MatterBridgeController(defaults: defaults)
        #expect(restored.isEnabled)
        #expect(!restored.includes("123"))
        matter.isEnabled = false
        #expect(defaults.bool(forKey: "homekit_bridge_enabled"))
        matter.shutdown(); restored.shutdown()
    }
}
