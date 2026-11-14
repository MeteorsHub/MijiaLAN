import Foundation
import Testing
@testable import MijiaCore

/// #59: rule persistence, one-minute trigger coalescing, and rule → intent mapping.
struct AutomationRuleTests {
    private static let studyLight = SmartDevice(
        id: "light_study",
        name: "书房台灯",
        roomId: "study",
        roomName: "书房",
        model: "yeelink.light.lamp4",
        isOnline: true,
        kind: .light(LightSpec(entityId: "light.study", isOn: true))
    )

    private static let homeScene = HomeScene(id: "scene_home", name: "回家模式", entityId: "scene.home")

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "test.automation.rules.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    @Test("Rules survive a save/load round trip, including every action kind")
    func persistenceRoundTrip() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let rules = [
            AutomationRule(trigger: .away, action: .devices(ids: ["light_study"], isOn: false)),
            AutomationRule(
                trigger: .externalDisplayConnected,
                action: .scene(sceneId: "scene_work"),
                isEnabled: false
            ),
            AutomationRule(trigger: .back, action: .quickAction(.softNightLight))
        ]
        AutomationRuleStore(defaults: defaults).save(rules)

        let loaded = AutomationRuleStore(defaults: defaults).load()
        #expect(loaded == rules)
        #expect(loaded.map(\.trigger) == [.away, .externalDisplayConnected, .back])
        #expect(loaded[1].isEnabled == false)

        guard case .quickAction(let action) = loaded[2].action else {
            Issue.record("Expected quick action")
            return
        }
        #expect(action == .softNightLight)
    }

    @Test("An absent key means no automation rules")
    func emptyByDefault() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AutomationRuleStore(defaults: defaults).load().isEmpty)
    }

    @Test("One unreadable rule does not discard the rest of the list")
    func toleratesPartiallyCorruptStorage() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let good = AutomationRule(trigger: .away, action: .quickAction(.lightsOff))
        AutomationRuleStore(defaults: defaults).save([good])
        let encoded = try #require(defaults.data(forKey: AutomationRuleStore.storageKey))
        let decoded = try JSONSerialization.jsonObject(with: encoded)
        var array = try #require(decoded as? [Any])
        let unknown: [String: Any] = [
            "id": UUID().uuidString,
            "isEnabled": true,
            "trigger": "retired-trigger",
            "action": ["kind": "scene", "sceneId": "scene_home"]
        ]
        array.append(unknown)
        defaults.set(
            try JSONSerialization.data(withJSONObject: array),
            forKey: AutomationRuleStore.storageKey
        )

        let loaded = AutomationRuleStore(defaults: defaults).load()
        #expect(loaded == [good])
    }

    @Test("The same trigger runs once per minute; other triggers are independent and state persists")
    func triggerCooldown() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let deduper = AutomationTriggerDeduper(defaults: defaults)
        #expect(deduper.shouldFire(.away, at: start))
        #expect(!deduper.shouldFire(.away, at: start.addingTimeInterval(59)))
        #expect(deduper.shouldFire(.back, at: start.addingTimeInterval(10)))

        // A relaunch reads the same persisted timestamp instead of replaying the rule.
        let relaunched = AutomationTriggerDeduper(defaults: defaults)
        #expect(!relaunched.shouldFire(.away, at: start.addingTimeInterval(59)))
        #expect(relaunched.shouldFire(.away, at: start.addingTimeInterval(AutomationPolicy.triggerCooldown)))

        // A clock that jumps backwards is a fresh start, not a permanent block.
        #expect(relaunched.shouldFire(.away, at: start))
    }

    @Test("Only enabled rules for the matching trigger run")
    func matcherFiltersByTriggerAndEnabled() {
        let away = AutomationRule(trigger: .away, action: .quickAction(.lightsOff))
        let awayDisabled = AutomationRule(trigger: .away, action: .quickAction(.lightsOff), isEnabled: false)
        let back = AutomationRule(trigger: .back, action: .quickAction(.softNightLight))

        let matched = AutomationMatcher.rules(for: .away, in: [away, awayDisabled, back])
        #expect(matched.map(\.id) == [away.id])
        #expect(AutomationMatcher.rules(for: .externalDisplayConnected, in: [away, back]).isEmpty)
    }

    @Test("Actions map to store intents and readable summaries")
    func actionMapping() {
        let scenes = [Self.homeScene]
        let devices = [Self.studyLight]
        let off = AutomationAction.devices(ids: ["light_study"], isOn: false)
        #expect(off.intents() == [
            DeviceIntent(targetId: "light_study", operation: .power(false))
        ])
        #expect(off.summary(devices: devices, scenes: scenes).contains("书房台灯"))

        let scene = AutomationAction.scene(sceneId: "scene_home")
        #expect(scene.intents() == [
            DeviceIntent(targetId: "scene_home", operation: .activateScene)
        ])
        #expect(scene.summary(devices: devices, scenes: scenes).contains("回家模式"))

        // Quick actions aggregate devices in the store, so they carry no fixed intents.
        #expect(AutomationAction.quickAction(.lightsOff).intents().isEmpty)
        // The settings list shows the trigger and the action summary side by side.
        #expect(AutomationTrigger.away.title.isEmpty == false)
    }
}
