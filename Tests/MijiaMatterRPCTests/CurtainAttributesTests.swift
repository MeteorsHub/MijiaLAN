import Testing
import MijiaLAN
@testable import mijia_lan

struct CurtainAttributesTests {
    let base = ["--properties","2.10,2.5","--packet-layout","single","--phase","probe","--slot","1","--rounds","48","--interval","30"]
    @Test("Property plans preserve exact order, reject illegal/duplicate addresses and cannot arm implicitly")
    func parse() throws {
        let options = try CurtainAttributes.parse(base)
        #expect(!options.execute && options.plan.properties == [10,5] && options.plan.layout == .single)
        for properties in ["", "2.1", "2.3,2.3", "3.2", "2.9,", "02.3", "2.03", "2.3,2.11"] {
            var args = base; args[1] = properties
            #expect(throws: (any Error).self) { try CurtainAttributes.parse(args) }
        }
        for extra in [["--execute"], ["--execute","--baseline-normal"], ["--socket","fresh"], ["--token","not-accepted"], ["--properties","2.3"]] {
            #expect(throws: (any Error).self) { try CurtainAttributes.parse(base + extra) }
        }
        #expect(try CurtainAttributes.parse(base + ["--execute","--baseline-normal","--log-directory","/tmp/new-attribute-test"]).execute)
    }
    @Test("Baseline phases are separate explicit full one-round plans; subsets never imply a baseline")
    func baselines() throws {
        for phase in ["baseline-before", "baseline-after"] {
            var args = base; args[5] = phase
            #expect(throws: (any Error).self) { try CurtainAttributes.parse(args) }
            args[1] = "2.2,2.3,2.4,2.5,2.9,2.10"; args[3] = "batch"; args[9] = "1"
            let options = try CurtainAttributes.parse(args)
            #expect(options.plan.properties == CurtainAttributePlan.whitelist && options.plan.rounds == 1)
        }
    }
    @Test("Plan execution does not read stdin or open a socket even with invalid port and no device config")
    func inertRun() async throws { try await CurtainAttributes.run(base, port: 0) }
}
