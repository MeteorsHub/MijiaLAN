import Foundation
import Testing
@testable import MijiaCore

/// #20: keys from CodexBar / environment variables are only used after an explicit import,
/// and the first request to a cloud AI service waits for the user's OK.
struct AssistantConsentTests {
    private static func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "test.assistant.consent.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("Ambient keys are not used until imported; import records its source and can be undone")
    func ambientKeyNeedsExplicitImport() throws {
        let (defaults, suite) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try #"{"providers":[{"id":"openrouter","apiKey":"sk-or-from-codexbar"}]}"#
            .write(to: tempURL, atomically: true, encoding: .utf8)

        let openRouter = "https://openrouter.ai/api/v1"
        defaults.set(openRouter, forKey: "assistant_base_url")
        // A fresh install never picks the key up on its own.
        #expect(AssistantConfig.load(from: defaults).apiKey == "")
        #expect(AssistantConfig.importedKeySource(forBaseURL: openRouter, defaults: defaults) == nil)

        // Clicking "导入" copies it into this app's own storage.
        #expect(AssistantConfig.importAmbientAPIKey(forBaseURL: openRouter, defaults: defaults, configURL: tempURL) == "CodexBar")
        #expect(AssistantConfig.load(from: defaults).apiKey == "sk-or-from-codexbar")
        #expect(AssistantConfig.importedKeySource(forBaseURL: openRouter, defaults: defaults) == "CodexBar")

        // Saving the same key keeps the label; typing a different one drops it.
        AssistantConfig(baseURL: openRouter, model: "~typesafe/jev-latest", apiKey: "sk-or-from-codexbar").save(to: defaults)
        #expect(AssistantConfig.importedKeySource(forBaseURL: openRouter, defaults: defaults) == "CodexBar")
        AssistantConfig(baseURL: openRouter, model: "~typesafe/jev-latest", apiKey: "sk-or-typed").save(to: defaults)
        #expect(AssistantConfig.importedKeySource(forBaseURL: openRouter, defaults: defaults) == nil)

        // "撤销" forgets the key.
        #expect(AssistantConfig.importAmbientAPIKey(forBaseURL: openRouter, defaults: defaults, configURL: tempURL) == "CodexBar")
        AssistantConfig.removeStoredAPIKey(forBaseURL: openRouter, defaults: defaults)
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: openRouter, defaults: defaults) == "")
        #expect(AssistantConfig.importedKeySource(forBaseURL: openRouter, defaults: defaults) == nil)
    }

    @Test("Nothing to import for custom, look-alike or plain-http endpoints")
    func importRefusesUnsafeTargets() throws {
        let (defaults, suite) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-refuse-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try #"{"providers":[{"id":"openrouter","apiKey":"sk-or"},{"id":"openai","apiKey":"sk-openai"}]}"#
            .write(to: tempURL, atomically: true, encoding: .utf8)

        #expect(AssistantProviderPreset.custom.supportsKeyImport == false)
        for url in ["https://my-proxy.example.com/v1", "https://openrouter.ai.evil.com/api/v1", "http://openrouter.ai/api/v1"] {
            #expect(AssistantConfig.importAmbientAPIKey(forBaseURL: url, defaults: defaults, configURL: tempURL) == nil, "\(url)")
        }
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: "https://openrouter.ai/api/v1", defaults: defaults) == "")
    }

    @MainActor
    private func makeStore(suite: String, baseURL: String) async throws -> (HomeStore, CallLog) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        AssistantConfig(baseURL: baseURL, model: "deepseek-chat", apiKey: "sk-deepseek").save(to: defaults)
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: AssistantTests.devices, scenes: AssistantTests.scenes))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let log = CallLog()
        store.assistantTransportOverride = { request in
            await log.record()
            let content = #"{"actions":[{"device":"d1","op":"power","value":true}],"reply":"已打开书房灯"}"#
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return (store, log)
    }

    @Test("The first cloud request waits for consent; allowing runs it and is remembered")
    @MainActor
    func cloudConsentAllow() async throws {
        let suite = "test.assistant.consent.allow.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (store, log) = try await makeStore(suite: suite, baseURL: "https://api.deepseek.com/v1")

        #expect(await store.runAssistantCommand("我要睡觉了") == nil)
        #expect(store.pendingCloudConsent == PendingCloudConsent(utterance: "我要睡觉了", endpoint: "api.deepseek.com", providerTitle: "DeepSeek"))
        #expect(await log.count == 0)

        let plan = try #require(await store.allowPendingCloudRequest())
        #expect(plan.source == .model)
        #expect(store.pendingCloudConsent == nil)
        #expect(store.consentedCloudEndpoints == ["api.deepseek.com"])
        let afterAllow = await log.count
        #expect(afterAllow >= 1)

        // Already allowed: no second prompt.
        _ = await store.runAssistantCommand("我要睡觉了")
        #expect(store.pendingCloudConsent == nil)
        #expect(await log.count > afterAllow)

        // Revoking asks again next time.
        store.revokeCloudConsent()
        #expect(await store.runAssistantCommand("我要睡觉了") == nil)
        #expect(store.pendingCloudConsent?.endpoint == "api.deepseek.com")
    }

    @Test("Declining sends nothing; local commands and local endpoints never ask")
    @MainActor
    func cloudConsentDeclineAndLocal() async throws {
        let suite = "test.assistant.consent.decline.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (store, log) = try await makeStore(suite: suite, baseURL: "https://api.deepseek.com/v1")

        _ = await store.runAssistantCommand("我要睡觉了")
        store.declinePendingCloudRequest()
        #expect(store.pendingCloudConsent == nil)
        guard case .failed(let message) = store.assistantState else {
            Issue.record("expected a 'not sent' message"); return
        }
        #expect(message.hasPrefix("没有发送"))
        #expect(await log.count == 0)
        #expect(store.consentedCloudEndpoints.isEmpty)

        // A command the local parser understands never needs the cloud.
        _ = await store.runAssistantCommand("打开书房吸顶灯")
        #expect(store.pendingCloudConsent == nil)
        #expect(await log.count == 0)

        let localSuite = "test.assistant.consent.local.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: localSuite)?.removePersistentDomain(forName: localSuite) }
        let (localStore, localLog) = try await makeStore(suite: localSuite, baseURL: "http://127.0.0.1:8080/v1")
        _ = await localStore.runAssistantCommand("我要睡觉了")
        #expect(localStore.pendingCloudConsent == nil)
        #expect(await localLog.count >= 1)
    }
}

private actor CallLog {
    private(set) var count = 0
    func record() { count += 1 }
}
