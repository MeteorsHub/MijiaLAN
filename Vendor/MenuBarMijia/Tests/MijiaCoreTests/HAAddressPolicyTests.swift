import Foundation
import Testing
@testable import MijiaCore

/// #18: after a disconnect the app never moves the Home Assistant token to a new address by itself.
struct HAAddressPolicyTests {
    static let home = HADiscoveredInstance(
        baseURL: "http://192.168.1.20:8123", locationName: "我的家", uuid: "abc-123", source: "mdns"
    )
    static let impostor = HADiscoveredInstance(
        baseURL: "http://192.168.1.66:8123", locationName: "Home Assistant", uuid: "evil-999", source: "arp"
    )

    @Test("Only a different, not dismissed address with the same instance id can be offered")
    func offerRules() {
        let current = "http://homeassistant.local:8123"
        #expect(HAAddressPolicy.canOffer(Self.home, currentURL: current, rememberedUUID: "abc-123"))
        #expect(HAAddressPolicy.canOffer(Self.home, currentURL: current, rememberedUUID: "ABC-123"))
        #expect(!HAAddressPolicy.canOffer(Self.impostor, currentURL: current, rememberedUUID: "abc-123"))
        let noId = HADiscoveredInstance(baseURL: "http://192.168.1.67:8123", locationName: "x", source: "arp")
        #expect(!HAAddressPolicy.canOffer(noId, currentURL: current, rememberedUUID: "abc-123"))
        // Nothing remembered yet: it may be offered, but switching still needs the user's tap.
        #expect(HAAddressPolicy.canOffer(Self.impostor, currentURL: current, rememberedUUID: nil))
        #expect(!HAAddressPolicy.canOffer(Self.home, currentURL: "http://192.168.1.20:8123/", rememberedUUID: nil))
        #expect(!HAAddressPolicy.canOffer(Self.home, currentURL: current, rememberedUUID: nil, dismissedURLs: ["http://192.168.1.20:8123"]))
    }

    @Test("Scanning pins the instance id of the HA the app is already connected to (#18)")
    func pinsUUIDForCurrentAddress() {
        // Nothing remembered and the current address matches a discovered instance: pin its uuid.
        #expect(HAAddressPolicy.uuidToPin(
            discovered: [Self.home], currentURL: "http://192.168.1.20:8123/", rememberedUUID: nil
        ) == "abc-123")
        // Already remembered: never overwrite.
        #expect(HAAddressPolicy.uuidToPin(
            discovered: [Self.home], currentURL: "http://192.168.1.20:8123", rememberedUUID: "abc-123"
        ) == nil)
        // The current address is not the discovered one: nothing to pin.
        #expect(HAAddressPolicy.uuidToPin(
            discovered: [Self.impostor], currentURL: "http://192.168.1.20:8123", rememberedUUID: nil
        ) == nil)
        // A discovered instance without an mDNS uuid cannot be pinned.
        let noId = HADiscoveredInstance(baseURL: "http://192.168.1.20:8123", locationName: "x", source: "mdns")
        #expect(HAAddressPolicy.uuidToPin(discovered: [noId], currentURL: "http://192.168.1.20:8123", rememberedUUID: nil) == nil)
    }

    @Test("A found address is only a question; a look-alike is ignored; the saved address stays until 切换")
    @MainActor
    func storeAsksFirst() async throws {
        let mock = MockHomeProvider(snapshot: SynthesizedHome())
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.ha.address.\(UUID().uuidString)")
        store.serverURLString = "http://homeassistant.local:8123"
        store.userDefaults.set("abc-123", forKey: HAAddressPolicy.rememberedUUIDKey)

        store.offerHAAddress(Self.impostor)
        #expect(store.pendingHAAddressSuggestion == nil)

        store.offerHAAddress(Self.home)
        #expect(store.pendingHAAddressSuggestion == Self.home)
        #expect(store.serverURLString == "http://homeassistant.local:8123")
        #expect(store.userDefaults.string(forKey: "ha_server_url") == "http://homeassistant.local:8123")

        store.dismissHAAddressSuggestion()
        #expect(store.pendingHAAddressSuggestion == nil)
        store.offerHAAddress(Self.home)
        #expect(store.pendingHAAddressSuggestion == nil)
    }

    @Test("切换 applies the address and remembers its instance id")
    @MainActor
    func acceptSwitches() async throws {
        let mock = MockHomeProvider(snapshot: SynthesizedHome())
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.ha.accept.\(UUID().uuidString)")
        store.serverURLString = "http://homeassistant.local:8123"
        store.offerHAAddress(Self.home)
        store.acceptHAAddressSuggestion()
        #expect(store.serverURLString == "http://192.168.1.20:8123")
        #expect(store.userDefaults.string(forKey: HAAddressPolicy.rememberedUUIDKey) == "abc-123")
    }

    @Test("The provider reports another address after repeated failures but keeps its own")
    func providerNeverSwitches() async throws {
        let reported = ReportedInstances()
        let provider = HAWebSocketProvider(
            baseURLString: "http://127.0.0.1:9",
            token: "test-token",
            onAddressSuggestion: { instance in Task { await reported.add(instance) } },
            rediscover: { _ in [Self.impostor] }
        )
        let events = provider.events()
        let watcher = Task { for await _ in events {} }
        defer { watcher.cancel() }
        for _ in 0..<100 where await reported.count == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await reported.count == 1)
        #expect(await provider.currentBaseURLString == "http://127.0.0.1:9")
        await provider.shutdown()
    }
}

actor ReportedInstances {
    private(set) var items: [HADiscoveredInstance] = []
    var count: Int { items.count }
    func add(_ item: HADiscoveredInstance) { items.append(item) }
}
