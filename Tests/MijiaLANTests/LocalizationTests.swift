import Foundation
import MijiaCore
import Testing
@testable import MijiaLAN

struct LocalizationTests {
    @Test("Language resolution follows the first supported preference and falls back to English")
    func languageResolution() {
        #expect(LANLocalization.language(preferredLanguages: ["en-US", "zh-Hans-CN"]) == .en)
        #expect(LANLocalization.language(preferredLanguages: ["zh-Hans-CN", "en"]) == .zhHans)
        #expect(LANLocalization.language(preferredLanguages: ["zh-TW"]) == .zhHans)
        #expect(LANLocalization.language(preferredLanguages: ["ja-JP", "en-GB", "zh"]) == .en)
        #expect(LANLocalization.language(preferredLanguages: ["fr-FR"]) == .en)
        #expect(LANLocalization.language(preferredLanguages: []) == .en)
    }

    @Test("English device capabilities use English descriptions rather than Chinese vendor comments", arguments: DeviceSchema.bundledModels)
    func englishCapabilities(model: String) throws {
        try L10n.$overrideLanguage.withValue(.en) {
            let schema = try #require(DeviceSchema.bundled(model: model))
            let capabilities = DeviceCapabilityCatalog.capabilities(schema: schema, model: model)
            for capability in capabilities {
                #expect(!hasChinese(capability.title), "\(model) \(capability.id): \(capability.title)")
                #expect(!hasChinese(capability.displayTitle))
                for option in capability.options {
                    #expect(!hasChinese(option.title), "\(model) \(capability.id): \(option.title)")
                }
            }
        }
    }

    @Test("Error descriptions, units and boolean values are translated in both languages")
    func runtimeText() throws {
        try L10n.$overrideLanguage.withValue(.en) {
            #expect(MiioError.invalidToken.errorDescription == "The token must contain 32 hexadecimal characters.")
            #expect(DeviceControlError.offline.errorDescription == "The device is offline. No command was sent.")
            #expect(CapabilityNames.unit("minutes", name: "time") == " min")
            let schema = try #require(DeviceSchema.bundled(model: "yeelink.light.lamp4"))
            let power = try #require(DeviceCapabilityCatalog.capabilities(schema: schema, model: "yeelink.light.lamp4").first { $0.name == "on" && $0.service == "light" })
            #expect(power.formatted(.bool(true)) == "On")
            #expect(power.formatted(nil) == "No Reading")
        }
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(MiioError.invalidToken.errorDescription == "token 应为 32 位十六进制")
            #expect(CapabilityNames.unit("minutes", name: "time") == " 分钟")
        }
    }

    @Test("Persisted reasons are translated only for display and leave saved device data intact")
    func persistedReasons() throws {
        let source: JSONValue = .object(["list": .array([.object([
            "did": .string("blt.example"), "name": .string("用户名称"), "model": .string("test")
        ])])])
        let chinese = L10n.$overrideLanguage.withValue(.zhHans) { CloudTokenImport.parse(source, rooms: [], region: "cn") }
        let english = L10n.$overrideLanguage.withValue(.en) { CloudTokenImport.parse(source, rooms: [], region: "cn") }
        #expect(chinese == english)
        let reason = try #require(english.skipped.first?.reason)
        let config = LocalHomeConfig(skipped: english.skipped)
        L10n.$overrideLanguage.withValue(.en) {
            #expect(CapabilityNames.importReason(reason) == "Bluetooth devices cannot be reached with the LAN protocol.")
            #expect(!hasChinese(CapabilityNames.limitation("规格存在，尚无经过确认的旧 miIO 映射")))
        }
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(CapabilityNames.importReason(reason) == reason)
        }
        #expect(LocalHomeConfig.decode(try #require(config.encoded())) == config)
        #expect(config.skipped.first?.name == "用户名称")
    }

    private func hasChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
